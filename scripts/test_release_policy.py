#!/usr/bin/env python3
"""Exercise release classification using real, disposable Git repositories."""
from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
from release_policy import FULL_CHECKS, STANDARD_CHECKS, ReleasePolicyError, plan_release


class ReleasePolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xiaopen-policy-test-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        self.git("init", "-q", "--initial-branch=main")
        self.git("config", "user.email", "policy-test@example.invalid")
        self.git("config", "user.name", "Release Policy Test")
        self.plist = {
            "CFBundleIdentifier": "com.example.XiaoPen", "CFBundleShortVersionString": "1.1.1",
            "CFBundleVersion": "12", "NSMicrophoneUsageDescription": "Listen for commands",
            "LSUIElement": True,
        }
        self.write("Resources/Info.plist", plistlib.dumps(self.plist))
        self.write("README.md", "Release policy fixture\n")
        self.write("Sources/XiaoPen/UI/SponsorView.swift", "// ordinary UI\n" * 10)
        self.write("Sources/XiaoPen/Audio/SpeechSynthesizer.swift", "// sensitive audio\n" * 10)
        self.base = self.commit("baseline")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env,
                              check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.decode().strip()

    def write(self, name, data):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data if isinstance(data, bytes) else data.encode())

    def commit(self, message="change"):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def plan(self, **kwargs):
        return plan_release(self.repo, self.base, **kwargs)

    def reset(self):
        self.git("reset", "--hard", self.base)
        self.git("clean", "-fdq")

    def test_same_commit_has_no_binary_release(self):
        plan = self.plan()
        self.assertEqual(plan["schemaVersion"], 1)
        self.assertEqual(plan["tier"], "none")
        self.assertFalse(plan["binaryReleaseAllowed"])
        self.assertEqual(plan["requiredChecks"], [])
        self.assertEqual(plan["changedFiles"], [])
        self.assertEqual(plan["baseline"], {"ref": self.base, "commit": self.base})
        self.assertIn("publishing a new binary is not allowed", " ".join(plan["reasons"]))

    def test_documentation_and_native_tests_do_not_change_signing_inputs(self):
        for name in ("README.md", "docs/RELEASING.md", "docs/voice/local-tts.md",
                     "docs/assets/readme-hero.png", "Tests/XiaoPenTests/NewTests.swift"):
            self.write(name, "updated\n")
        head = self.commit()
        plan = self.plan()
        self.assertEqual(plan["tier"], "none")
        self.assertFalse(plan["binaryReleaseAllowed"])
        self.assertEqual(plan["sourceCommit"], head)

    def test_ordinary_product_change_requires_standard_checks(self):
        self.write("Sources/XiaoPen/UI/SponsorView.swift", "// revised UI\n")
        self.commit()
        plan = self.plan()
        self.assertEqual(plan["tier"], "standard")
        self.assertTrue(plan["binaryReleaseAllowed"])
        self.assertEqual(plan["requiredChecks"], list(STANDARD_CHECKS))
        self.assertEqual(plan["changedFiles"], [{"status": "M", "path": "Sources/XiaoPen/UI/SponsorView.swift"}])

    def test_version_only_is_standard(self):
        self.plist.update(CFBundleShortVersionString="1.1.2", CFBundleVersion="13")
        self.write("Resources/Info.plist", plistlib.dumps(self.plist))
        self.commit()
        self.assertEqual(self.plan()["tier"], "standard")

    def test_version_plus_docs_remains_standard(self):
        self.plist["CFBundleVersion"] = "13"
        self.write("Resources/Info.plist", plistlib.dumps(self.plist))
        self.write("CHANGELOG.md", "Release 1.1.2\n")
        self.commit()
        self.assertEqual(self.plan()["tier"], "standard")

    def test_equivalent_plist_serialization_is_standard(self):
        self.write("Resources/Info.plist", plistlib.dumps(self.plist, fmt=plistlib.FMT_BINARY))
        self.commit()
        self.assertEqual(self.plan()["tier"], "standard")

    def test_nonversion_plist_changes_are_full(self):
        for key, value in (("NSMicrophoneUsageDescription", "New permission text"),
                           ("CFBundleIdentifier", "com.example.Other"), ("LSUIElement", 1)):
            with self.subTest(key=key):
                self.reset()
                changed = dict(self.plist, **{key: value}, CFBundleVersion="13")
                self.write("Resources/Info.plist", plistlib.dumps(changed))
                self.commit()
                self.assertEqual(self.plan()["tier"], "full")

    def test_malformed_or_deleted_plist_is_full(self):
        for invalid in ("not a plist\n", '<?xml version="1.0"?><plist><dict><key>broken'):
            with self.subTest(invalid=invalid):
                self.reset()
                self.write("Resources/Info.plist", invalid)
                self.commit()
                self.assertEqual(self.plan()["tier"], "full")
        self.reset()
        (self.repo / "Resources/Info.plist").unlink()
        self.commit()
        self.assertEqual(self.plan()["tier"], "full")

    def test_added_plist_is_not_misclassified_as_version_only(self):
        self.git("rm", "Resources/Info.plist")
        self.base = self.commit("baseline without plist")
        self.write("Resources/Info.plist", plistlib.dumps(self.plist))
        self.commit()
        self.assertEqual(self.plan()["tier"], "full")

    def test_sensitive_paths_require_all_full_checks(self):
        paths = (
            "Package.swift", "Package.resolved", "Resources/XiaoPen.entitlements",
            "Sources/XiaoPen/Audio/CloudSpeech.swift", "Sources/XiaoPenSpeechWorker/main.swift",
            "Sources/XiaoPen/Storage/Preferences.swift", "Sources/XiaoPen/System/GlobalHotKey.swift",
            "Sources/XiaoPen/App/AppState.swift", "Sources/XiaoPen/UI/OnboardingView.swift",
            "Sources/XiaoPen/UI/SettingsView.swift", "Sources/XiaoPen/Brain/ChatGPTAuth.swift",
            "Sources/XiaoPen/Brain/LLMHTTPClient.swift", "Sources/XiaoPen/Brain/ChatGPTResponsesProvider.swift",
            "Sources/XiaoPen/Brain/OpenAIProvider.swift", "Sources/XiaoPen/Brain/AnthropicProvider.swift",
            "Sources/XiaoPen/UI/BrainSettingsForm.swift",
            "Sources/XiaoPen/Skills/LocationService.swift", "scripts/build_app.sh",
            "scripts/release_policy.py", ".github/workflows/release.yml",
            "docs/voice/model-manifest.json", "Sources/XiaoPen/Resources/voice-model-manifest.json",
        )
        for name in paths:
            with self.subTest(path=name):
                self.reset()
                self.write(name, "changed\n")
                self.commit()
                plan = self.plan()
                self.assertEqual(plan["tier"], "full")
                self.assertEqual(plan["requiredChecks"], list(FULL_CHECKS))

    def test_bundled_readme_is_product_input(self):
        self.write("Sources/XiaoPen/Resources/README.md", "packaged text\n")
        self.commit()
        self.assertEqual(self.plan()["tier"], "standard")

    def test_noncredential_product_files_remain_standard(self):
        for name in ("Sources/XiaoPen/Brain/OllamaProvider.swift", "Sources/XiaoPen/Brain/LLMVendor.swift",
                     "Sources/XiaoPen/Brain/LLMProvider.swift", "Sources/XiaoPen/UI/SponsorView.swift",
                     "Sources/XiaoPen/Skills/ReminderStore.swift", "Sources/XiaoPen/Skills/Weather.swift"):
            with self.subTest(path=name):
                self.reset()
                self.write(name, "ordinary product change\n")
                self.commit()
                self.assertEqual(self.plan()["tier"], "standard")

    def test_unknown_paths_fail_closed(self):
        for name in ("new-build-config.json", "docs/new-runtime-input.json", "Sources/XiaoPen/UI/NewView.swift"):
            with self.subTest(path=name):
                self.reset()
                self.write(name, "new input\n")
                self.commit()
                self.assertEqual(self.plan()["tier"], "full")

    def test_sensitive_rename_to_documentation_still_requires_full(self):
        old = "Sources/XiaoPen/Audio/SpeechSynthesizer.swift"
        new = "docs/retired-audio.md"
        (self.repo / new).parent.mkdir(parents=True)
        self.git("mv", old, new)
        self.commit()
        plan = self.plan()
        self.assertEqual(plan["tier"], "full")
        self.assertEqual(plan["changedFiles"], [{"status": "R100", "path": new, "oldPath": old}])

    def test_documentation_rename_to_product_checks_destination(self):
        old = "README.md"
        new = "Sources/XiaoPen/Brain/LLMProvider.swift"
        (self.repo / new).parent.mkdir(parents=True, exist_ok=True)
        self.git("mv", old, new)
        self.commit()
        self.assertEqual(self.plan()["tier"], "standard")

    def test_unknown_source_renamed_to_docs_remains_full(self):
        self.write("unreviewed-input.json", "unknown input\n" * 10)
        self.base = self.commit("baseline contains unknown input")
        (self.repo / "docs").mkdir()
        self.git("mv", "unreviewed-input.json", "docs/archive.md")
        self.commit()
        self.assertEqual(self.plan()["tier"], "full")

    def test_deleted_source_uses_old_path(self):
        self.git("rm", "Sources/XiaoPen/Audio/SpeechSynthesizer.swift")
        self.commit()
        plan = self.plan()
        self.assertEqual(plan["tier"], "full")
        self.assertEqual(plan["changedFiles"][0]["status"], "D")

    def test_documentation_rename_and_deletion_remain_none(self):
        self.git("mv", "README.md", "README.zh-CN.md")
        self.commit()
        self.assertEqual(self.plan()["tier"], "none")
        self.git("rm", "README.zh-CN.md")
        self.commit()
        self.assertEqual(self.plan()["tier"], "none")

    def test_file_type_change_requires_full_even_for_docs(self):
        (self.repo / "README.md").unlink()
        (self.repo / "README.md").symlink_to("Resources/Info.plist")
        self.commit()
        plan = self.plan()
        self.assertEqual(plan["changedFiles"][0]["status"], "T")
        self.assertEqual(plan["tier"], "full")

    def test_added_documentation_symlink_is_full(self):
        (self.repo / "docs").mkdir()
        (self.repo / "docs/linked.md").symlink_to("../README.md")
        self.commit()
        self.assertEqual(self.plan()["tier"], "full")

    def test_odd_filenames_preserved_without_shell_or_line_parsing(self):
        names = ("docs/with\ttab.md", "docs/with\nnewline.md", "docs/中文.md", "--odd-file")
        for name in names:
            self.write(name, "new\n")
        self.commit()
        plan = self.plan()
        self.assertEqual({entry["path"] for entry in plan["changedFiles"]}, set(names))
        self.assertEqual(plan["tier"], "full")
        json.dumps(plan)

    def test_downgrades_are_rejected_and_promotion_is_allowed(self):
        self.write("Sources/XiaoPen/UI/SponsorView.swift", "// updated\n")
        self.commit()
        with self.assertRaisesRegex(ReleasePolicyError, "Cannot lower"):
            self.plan(requested_tier="none")
        promoted = self.plan(requested_tier="full")
        self.assertEqual(promoted["detectedTier"], "standard")
        self.assertEqual(promoted["tier"], "full")
        self.assertEqual(promoted["requiredChecks"], list(FULL_CHECKS))
        self.write("Package.resolved", "changed dependencies\n")
        self.commit()
        with self.assertRaisesRegex(ReleasePolicyError, "Cannot lower"):
            self.plan(requested_tier="standard")

    def test_docs_only_promotion_still_cannot_authorize_new_binary(self):
        promoted = self.plan(requested_tier="full")
        self.assertEqual(promoted["tier"], "full")
        self.assertFalse(promoted["binaryReleaseAllowed"])

    def test_invalid_tier_and_missing_baseline_are_rejected(self):
        with self.assertRaisesRegex(ReleasePolicyError, "Unknown requested tier"):
            self.plan(requested_tier="fast")
        with self.assertRaises(ReleasePolicyError):
            plan_release(self.repo, "does-not-exist")
        with self.assertRaises(ReleasePolicyError):
            plan_release(self.repo, "--help")

    def test_diverged_or_newer_baseline_is_rejected(self):
        self.git("checkout", "-qb", "side")
        self.write("README.md", "side branch\n")
        side = self.commit()
        self.git("checkout", "-q", "main")
        self.write("README.md", "main branch\n")
        head = self.commit()
        with self.assertRaisesRegex(ReleasePolicyError, "ancestor"):
            plan_release(self.repo, side, head)
        with self.assertRaisesRegex(ReleasePolicyError, "ancestor"):
            plan_release(self.repo, head, self.base)

    def test_ref_resolution_uses_requested_commit_not_working_tree(self):
        self.write("README.md", "committed documentation\n")
        head = self.commit()
        self.write("Package.swift", "uncommitted dependency change\n")
        plan = self.plan(head_ref=head)
        self.assertEqual(plan["tier"], "none")
        self.assertEqual(plan["sourceCommit"], head)

    def test_subdirectory_and_relative_diff_config_cannot_hide_sensitive_change(self):
        self.git("config", "diff.relative", "true")
        self.write("Sources/XiaoPen/Audio/SpeechSynthesizer.swift", "// audio changed\n")
        self.commit()
        plan = plan_release(self.repo / "Sources/XiaoPen/UI", self.base)
        self.assertEqual(plan["tier"], "full")
        self.assertEqual(plan["changedFiles"][0]["path"], "Sources/XiaoPen/Audio/SpeechSynthesizer.swift")


if __name__ == "__main__":
    unittest.main()
