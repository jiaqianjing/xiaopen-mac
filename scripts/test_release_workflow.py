#!/usr/bin/env python3
"""Exercise release safety gates without certificates, uploads, or Apple services."""

import json
import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
_xcode_spec = importlib.util.spec_from_file_location("xcode_notarize", PROJECT / "scripts/xcode_notarize.py")
xcode_notarize = importlib.util.module_from_spec(_xcode_spec)
_xcode_spec.loader.exec_module(xcode_notarize)
IDENTITY = "Developer ID Application: Release Test (TESTTEAM01)"
FINGERPRINT = "A" * 40
UUID = "12345678-1234-1234-1234-123456789abc"


class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xiaopen-release-test-")
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.evidence = self.root / "evidence"
        self.evidence.mkdir()
        self.trace = self.root / "trace.jsonl"
        self.env = dict(os.environ)
        self.env.update(
            PATH=str(self.bin) + os.pathsep + self.env["PATH"],
            TEST_TRACE=str(self.trace),
            TEST_IDENTITY_LIST=f'  1) {FINGERPRINT} "{IDENTITY}"\n  1 valid identities found',
            TEST_STATUS="Accepted",
            TEST_UUID=UUID,
            TEST_IDENTITY=IDENTITY,
            TEST_SIGNATURE=f"Authority={IDENTITY}\nTeamIdentifier=TESTTEAM01\nTimestamp=Oct 30, 2026\nCodeDirectory v=20500 flags=0x10000(runtime)\n",
        )
        # These shims are only visible to child processes spawned by this test.
        self.shim("security", 'print(os.environ["TEST_IDENTITY_LIST"])')
        self.shim("git", '''
if os.environ.get("TEST_GIT_FAIL"):
    sys.exit(1)
if "status" in sys.argv:
    print(os.environ.get("TEST_DIRTY_SOURCE", ""), end="")
elif "rev-parse" in sys.argv:
    print("a" * 40)
''')
        self.shim("codesign", '''
if "--display" in sys.argv and "--entitlements" in sys.argv:
    if "--xml" in sys.argv:
        print('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>')
    else:
        print('[Dict] com.apple.security.device.audio-input = true')
elif "--display" in sys.argv:
    print(os.environ["TEST_SIGNATURE"], file=sys.stderr)
if os.environ.get("TEST_CODESIGN_FAIL"):
    sys.exit(1)
''')
        self.shim("file", '''
print("Mach-O 64-bit executable arm64" if Path(sys.argv[-1]).name in ("XiaoPen", "XiaoPenSpeechWorker", "nested.dylib") else "data")
''')
        self.shim("spctl", '''
print(os.environ.get("TEST_GATEKEEPER_STATUS", "assessments enabled"))
if os.environ.get("TEST_GATEKEEPER_FAIL"):
    sys.exit(1)
''')
        self.shim("xcrun", '''
args = sys.argv[1:]
if args[0] == "--find":
    print("/mock/" + args[1])
elif args[0] == "notarytool":
    action = args[1]
    if action == "submit":
        print(json.dumps({"id": os.environ["TEST_UUID"], "message": "Uploaded"}))
    elif action in ("wait", "info"):
        print(json.dumps({"id": os.environ["TEST_UUID"], "status": os.environ["TEST_STATUS"]}))
    elif action == "log":
        Path(args[-1]).write_text(json.dumps({"status": os.environ["TEST_STATUS"]}))
    elif action == "history":
        print('{"history": []}')
    if os.environ.get("TEST_NOTARY_FAIL") == action:
        sys.exit(1)
elif args[0] == "stapler":
    if os.environ.get("TEST_STAPLER_FAIL") == args[1]:
        sys.exit(1)
''')

    def tearDown(self):
        self.temp.cleanup()

    def shim(self, name, body):
        path = self.bin / name
        path.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\nfrom pathlib import Path\n"
            f"with open(os.environ['TEST_TRACE'], 'a') as f: f.write(json.dumps([{name!r}] + sys.argv[1:]) + '\\n')\n"
            + body + "\n"
        )
        path.chmod(0o755)

    def run_shell(self, body, **overrides):
        env = dict(self.env, **overrides)
        setup = f'''
set -euo pipefail
fail() {{ printf 'Error: %s\\n' "$*" >&2; exit 1; }}
source {shlex.quote(str(PROJECT / "scripts/release_support.sh"))}
PROJECT_DIR={shlex.quote(str(PROJECT))}
BUILD_DIR={shlex.quote(str(self.root / "build"))}
EVIDENCE_DIR={shlex.quote(str(self.evidence))}
VERSION=1.1.1
BUILD_NUMBER=12
SIGN_IDENTITY=""
RELEASE_IDENTITY_LABEL={shlex.quote(IDENTITY)}
RELEASE_TEAM_ID=TESTTEAM01
NOTARY_PROFILE="test profile"
NOTARY_KEYCHAIN=""
NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
MAKE_DMG=true
INSTALL_DIR=""
'''
        return subprocess.run(["/bin/bash", "-c", setup + body], env=env, text=True, capture_output=True)

    def calls(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []

    def test_selects_unique_developer_id_and_pins_fingerprint(self):
        result = self.run_shell('select_release_signing_identity; printf "%s" "$SIGN_IDENTITY"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.endswith(FINGERPRINT))

    def test_rejects_missing_developer_id(self):
        result = self.run_shell("select_release_signing_identity", TEST_IDENTITY_LIST="0 valid identities found")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exactly one valid Developer ID", result.stderr)

    def test_rejects_ambiguous_developer_id(self):
        result = self.run_shell("select_release_signing_identity", TEST_IDENTITY_LIST=self.env["TEST_IDENTITY_LIST"] + f'\n  2) {"B" * 40} "Developer ID Application: Other Test (TESTTEAM02)"')
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_ad_hoc_and_development_identity(self):
        for identity in ["-", "Apple Development: Test (TESTTEAM01)"]:
            with self.subTest(identity=identity):
                result = self.run_shell(f"SIGN_IDENTITY={shlex.quote(identity)}; select_release_signing_identity")
                self.assertNotEqual(result.returncode, 0)

    def test_release_requires_profile_dmg_and_separate_install(self):
        for change in ['NOTARY_PROFILE=""', "MAKE_DMG=false", "INSTALL_DIR=/Applications"]:
            with self.subTest(change=change):
                result = self.run_shell(change + "; release_preflight")
                self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_credentials_failure_stops_before_packaging(self):
        result = self.run_shell("release_preflight", TEST_NOTARY_FAIL="history")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("credentials unavailable", result.stderr)
        self.assertFalse(any("submit" in call for call in self.calls()))

    def test_disabled_or_unreadable_gatekeeper_blocks_release(self):
        for overrides in [{"TEST_GATEKEEPER_STATUS": "assessments disabled"}, {"TEST_GATEKEEPER_FAIL": "1"}]:
            with self.subTest(overrides=overrides):
                result = self.run_shell("release_preflight", **overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any("history" in call for call in self.calls()))

    def test_xcode_and_profile_modes_are_mutually_exclusive(self):
        result = self.run_shell("NOTARY_VIA_XCODE=true; release_preflight")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot be combined", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_dirty_release_source_is_rejected_before_credentials(self):
        result = self.run_shell("release_preflight", TEST_DIRTY_SOURCE=" M scripts/build_app.sh\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("committed and clean", result.stderr)
        self.assertFalse(any("history" in call for call in self.calls()))

    def test_unreadable_release_source_is_rejected_before_credentials(self):
        result = self.run_shell("release_preflight", TEST_GIT_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot inspect release source state", result.stderr)
        self.assertFalse(any("history" in call for call in self.calls()))

    def test_accepted_submission_is_saved_before_wait_and_stapled(self):
        result = self.run_shell('notarize_and_staple "/tmp/archive with spaces.zip" "/tmp/app with spaces.app" app')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        actions = [call[2] for call in calls if call[0] == "xcrun"]
        self.assertEqual(actions, ["submit", "wait", "info", "log", "staple", "validate"])
        self.assertIn("--no-wait", calls[0])
        self.assertIn("/tmp/archive with spaces.zip", calls[0])
        self.assertIn("test profile", calls[0])
        self.assertEqual(json.loads((self.evidence / "app-submit.json").read_text())["id"], UUID)
        self.assertTrue((self.evidence / "app-notary-log.json").exists())

    def test_rejected_submission_saves_log_and_never_staples(self):
        result = self.run_shell('notarize_and_staple archive.zip app.app app', TEST_STATUS="Invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.evidence / "app-notary-log.json").exists())
        self.assertFalse(any("stapler" in call for call in self.calls()))

    def test_wait_timeout_preserves_submission_id_without_stapling(self):
        result = self.run_shell('notarize_and_staple archive.zip app.app app', TEST_STATUS="In Progress", TEST_NOTARY_FAIL="wait")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads((self.evidence / "app-submit.json").read_text())["id"], UUID)
        self.assertFalse(any("stapler" in call for call in self.calls()))

    def test_upload_failure_and_malformed_id_never_staple(self):
        for overrides in [{"TEST_NOTARY_FAIL": "submit"}, {"TEST_UUID": "not-a-uuid"}]:
            with self.subTest(overrides=overrides):
                result = self.run_shell('notarize_and_staple archive.zip app.app app', **overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any("stapler" in call for call in self.calls()))

    def test_stapling_failure_is_fatal(self):
        for action in ["staple", "validate"]:
            with self.subTest(action=action):
                result = self.run_shell('notarize_and_staple archive.zip app.app app', TEST_STAPLER_FAIL=action)
                self.assertNotEqual(result.returncode, 0)

    def test_wrong_team_missing_timestamp_or_missing_runtime_is_fatal(self):
        good = self.env["TEST_SIGNATURE"]
        for bad in [good.replace("TeamIdentifier=TESTTEAM01", "TeamIdentifier=WRONGTEAM0"), good.replace("Timestamp=Oct 30, 2026\n", ""), good.replace("flags=0x10000(runtime)", "flags=0x0(none)"), good.replace(IDENTITY, "Apple Development: Test (TESTTEAM01)")]:
            with self.subTest(signature=bad):
                result = self.run_shell('assert_release_signature app.app true', TEST_SIGNATURE=bad)
                self.assertNotEqual(result.returncode, 0)

    def test_signature_gate_accepts_expected_developer_id(self):
        result = self.run_shell('assert_release_signature app.app true')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_all_embedded_macho_code_is_signed_before_the_main_bundle(self):
        app = self.root / "XiaoPen.app"
        macos = app / "Contents/MacOS"
        macos.mkdir(parents=True)
        for name in ["XiaoPen", "XiaoPenSpeechWorker", "nested.dylib"]:
            (macos / name).write_bytes(b"test code")
        result = self.run_shell(f'''
STAGED_APP={shlex.quote(str(app))}
MACOS_DIR={shlex.quote(str(macos))}
APP_NAME=XiaoPen
sign_release_app
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        signatures = [call for call in self.calls() if call[0] == "codesign" and "--force" in call]
        self.assertEqual({Path(call[-1]).name for call in signatures[:-1]}, {"XiaoPenSpeechWorker", "nested.dylib"})
        self.assertEqual(signatures[-1][-1], str(app))
        self.assertTrue(all("--timestamp" in call and "runtime" in call for call in signatures))
        self.assertTrue(all("--deep" not in call and "--timestamp=none" not in call for call in signatures))
        entitlement_exports = [call for call in self.calls() if call[0] == "codesign" and "--entitlements" in call and "--display" in call]
        self.assertEqual(len(entitlement_exports), 1)
        self.assertIn("--xml", entitlement_exports[0])
        exported = self.evidence / "app-entitlements.plist"
        lint = subprocess.run(["plutil", "-lint", str(exported)], capture_output=True, text=True)
        self.assertEqual(lint.returncode, 0, lint.stderr)
        self.assertTrue((self.evidence / "app-entitlements-lint.log").exists())

    def test_gatekeeper_or_integrity_check_failure_is_fatal(self):
        result = self.run_shell('release_check gatekeeper /usr/bin/false; printf "must not run"')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("must not run", result.stdout)


class XcodeNotarizationProofTests(unittest.TestCase):
    def apple_log(self):
        return {"jobId": UUID, "status": "Accepted", "statusCode": 0, "issues": None,
                "ticketContents": [{"path": "Carrier.zip/XiaoPen.app/Contents/Resources/Distribution/XiaoPen-1.1.1.dmg",
                                    "cdhash": "a" * 40}]}

    def test_accepted_dmg_requires_exact_filename_and_codehash(self):
        log = self.apple_log()
        proof = xcode_notarize.verify_apple_log(log, UUID.upper(), "XiaoPen-1.1.1.dmg", "a" * 40)
        self.assertEqual(len(proof["matchingTickets"]), 1)
        for filename, codehash in [("Other.dmg", "a" * 40), ("XiaoPen-1.1.1.dmg", "b" * 40)]:
            with self.subTest(filename=filename, codehash=codehash):
                with self.assertRaises(xcode_notarize.NotarizationError):
                    xcode_notarize.verify_apple_log(log, UUID, filename, codehash)

    def test_accepted_carrier_without_nested_dmg_ticket_is_rejected(self):
        log = self.apple_log()
        log["ticketContents"] = [{"path": "Carrier.zip/XiaoPen.app", "cdhash": "a" * 40}]
        with self.assertRaises(xcode_notarize.NotarizationError):
            xcode_notarize.verify_apple_log(log, UUID, "XiaoPen-1.1.1.dmg", "a" * 40)

    def test_dmg_ticket_must_be_in_the_exact_carrier_resource_path(self):
        ticket_path = "XiaoPen.app/Contents/Resources/Distribution/XiaoPen-1.1.1.dmg"
        xcode_notarize.verify_apple_log(self.apple_log(), UUID, ticket_path, "a" * 40)
        log = self.apple_log()
        log["ticketContents"][0]["path"] = "Other.zip/Other.app/XiaoPen-1.1.1.dmg"
        with self.assertRaises(xcode_notarize.NotarizationError):
            xcode_notarize.verify_apple_log(log, UUID, ticket_path, "a" * 40)

    def test_rejects_mismatched_submission_invalid_status_or_apple_errors(self):
        for changes in [{"jobId": "different"}, {"status": "In Progress"}, {"statusCode": 4000},
                        {"issues": [{"severity": "error", "message": "bad code"}]}]:
            with self.subTest(changes=changes):
                log = dict(self.apple_log(), **changes)
                with self.assertRaises(xcode_notarize.NotarizationError):
                    xcode_notarize.verify_apple_log(log, UUID, "XiaoPen-1.1.1.dmg", "a" * 40)

    def test_warnings_are_retained_without_overriding_accepted_verdict(self):
        log = dict(self.apple_log(), issues=[{"severity": "warning", "message": "review warning"}])
        proof = xcode_notarize.verify_apple_log(log, UUID, "XiaoPen-1.1.1.dmg", "a" * 40)
        self.assertEqual(proof["warningCount"], 1)

    def test_app_ticket_requires_apple_silicon_architecture(self):
        log = dict(self.apple_log(), ticketContents=[{"path": "App.zip/XiaoPen.app", "cdhash": "a" * 40, "arch": "x86_64"}])
        with self.assertRaises(xcode_notarize.NotarizationError):
            xcode_notarize.verify_apple_log(log, UUID, "XiaoPen.app", "a" * 40, "arm64")

    def test_submission_must_belong_to_selected_developer_id_team(self):
        record = {"identifier": UUID, "teamID": "TESTTEAM01", "uploadDestination": "Developer ID",
                  "processingEvent": {"state": "processing"}}
        self.assertEqual(xcode_notarize.matching_distribution({"Distributions": [record]}, "TESTTEAM01"), UUID)
        for changes in [{"teamID": "WRONGTEAM0"}, {"uploadDestination": "App Store Connect"}, {"identifier": "malformed"}]:
            with self.subTest(changes=changes):
                with self.assertRaises(xcode_notarize.NotarizationError):
                    xcode_notarize.matching_distribution({"Distributions": [dict(record, **changes)]}, "TESTTEAM01")

    def test_only_processing_error_is_retryable(self):
        self.assertTrue(xcode_notarize.is_processing_error('error: Archive "app.xcarchive" is processing and not ready for distribution.\n** EXPORT FAILED **'))
        self.assertFalse(xcode_notarize.is_processing_error('error: Account authentication failed while processing archive.'))
        self.assertFalse(xcode_notarize.is_processing_error('** EXPORT FAILED **'))
        self.assertFalse(xcode_notarize.is_processing_error('error: Archive "app.xcarchive" is processing and not ready for distribution.\nerror: Authentication failed.'))

    def test_external_and_broken_bundle_symlinks_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "XiaoPen.app"
            app.mkdir()
            (app / "file").write_text("inside")
            (app / "link").symlink_to("file")
            xcode_notarize.validate_symlinks(app)
            (app / "link").unlink()
            for destination in [root / "outside", root / "does-not-exist"]:
                with self.subTest(destination=destination):
                    if destination.name == "outside":
                        destination.write_text("outside")
                    (app / "link").symlink_to(destination)
                    with self.assertRaises(xcode_notarize.NotarizationError):
                        xcode_notarize.validate_symlinks(app)
                    (app / "link").unlink()

    def test_payload_fidelity_allows_resigning_but_rejects_code_and_resource_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.app"
            executable = source / "Contents/MacOS/probe"
            executable.parent.mkdir(parents=True)
            compile_result = subprocess.run(["xcrun", "clang", "-arch", "arm64", "-x", "c", "-o", str(executable), "-"],
                                            input="int main(void) { return 0; }\n", capture_output=True, text=True)
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            resource = source / "Contents/resource.txt"
            resource.write_text("original resource")
            baseline = xcode_notarize.payload_hash(source)
            exported = root / "exported.app"
            shutil.copytree(source, exported)
            exported_code = exported / "Contents/MacOS/probe"
            result = subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(exported_code)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            (exported / "Contents/_CodeSignature").mkdir()
            (exported / "Contents/_CodeSignature/CodeResources").write_bytes(b"new seal")
            (exported / "Contents/CodeResources").write_bytes(b"stapled ticket")
            self.assertEqual(xcode_notarize.payload_hash(exported), baseline)
            (exported / "Contents/resource.txt").write_text("changed resource")
            self.assertNotEqual(xcode_notarize.payload_hash(exported), baseline)
            (exported / "Contents/resource.txt").write_text("original resource")
            code = bytearray(exported_code.read_bytes())
            code[8192] ^= 1
            exported_code.write_bytes(code)
            self.assertNotEqual(xcode_notarize.payload_hash(exported), baseline)

    def test_private_dmg_copy_omits_finder_metadata_and_preserves_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "original.dmg"
            destination = Path(temporary) / "private-resource.dmg"
            source.write_bytes(b"signed DMG data fork fixture")
            finder_info = b"TEXTttxt" + b"\0" * 24
            quarantine = b"0081;69032200;Safari;TEST"
            subprocess.run(["xattr", "-wx", "com.apple.FinderInfo", finder_info.hex(), str(source)], check=True, capture_output=True)
            subprocess.run(["xattr", "-wx", "com.apple.quarantine", quarantine.hex(), str(source)], check=True, capture_output=True)
            original_digest = xcode_notarize.sha256(source)
            xcode_notarize.copy_dmg_resource(source, destination)
            self.assertEqual(xcode_notarize.sha256(destination), original_digest)
            self.assertEqual(xcode_notarize.sha256(source), original_digest)
            destination_attributes = subprocess.run(["xattr", str(destination)], check=True, capture_output=True, text=True).stdout.splitlines()
            self.assertNotIn("com.apple.FinderInfo", destination_attributes)
            self.assertNotIn("com.apple.ResourceFork", destination_attributes)
            for name, expected in [("com.apple.FinderInfo", finder_info), ("com.apple.quarantine", quarantine)]:
                actual = subprocess.run(["xattr", "-px", name, str(source)], check=True, capture_output=True, text=True).stdout
                self.assertEqual(bytes.fromhex(actual), expected)

    def test_validation_failure_saves_private_diagnostics_without_command_arguments(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "dmg-validation.log"
            with mock.patch.object(xcode_notarize, "VALIDATION_LOG", log):
                with self.assertRaises(xcode_notarize.NotarizationError):
                    xcode_notarize.command([sys.executable, "-c", "import sys;sys.stderr.write('Finder metadata rejected');sys.exit(2)", "private-argument-sentinel"])
            self.assertIn("Finder metadata rejected", log.read_text())
            self.assertNotIn("private-argument-sentinel", log.read_text())
            self.assertEqual(log.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main(verbosity=2)
