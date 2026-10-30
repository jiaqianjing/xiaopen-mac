#!/usr/bin/env python3
"""Exercise release safety gates without certificates, uploads, or Apple services."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parent.parent
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
if "--display" in sys.argv:
    print(os.environ["TEST_SIGNATURE"], file=sys.stderr)
if os.environ.get("TEST_CODESIGN_FAIL"):
    sys.exit(1)
''')
        self.shim("file", '''
print("Mach-O 64-bit executable arm64" if Path(sys.argv[-1]).name in ("XiaoPen", "XiaoPenSpeechWorker", "nested.dylib") else "data")
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

    def test_gatekeeper_or_integrity_check_failure_is_fatal(self):
        result = self.run_shell('release_check gatekeeper /usr/bin/false; printf "must not run"')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("must not run", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
