#!/usr/bin/env python3
"""Plan release acceptance from committed Git changes, without building or signing.

The policy is an explicit allowlist for the current Package.swift/build_app.sh
inputs. New paths fail closed to ``full`` until reviewed here. ``none`` means no
new binary may be released, not that signing or notarization can be skipped for
a binary release. Working-tree edits are deliberately outside this commit plan.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import subprocess
from xml.parsers.expat import ExpatError


TIERS = ("none", "standard", "full")
STANDARD_CHECKS = ("clean_install", "upgrade_retention", "voice_smoke")
FULL_CHECKS = STANDARD_CHECKS + (
    "offline_first_launch", "permission_recovery", "wake_modes", "follow_up",
    "local_tts", "system_voice", "shortcut_replay",
)

# These are app inputs with ordinary product behavior. New source files are
# intentionally not covered by a blanket Sources/ prefix.
STANDARD_INPUTS = frozenset({
    "Resources/AppIcon.icns",
    "Sources/XiaoPen/App/ConversationHistory.swift",
    "Sources/XiaoPen/Brain/LLMProvider.swift",
    "Sources/XiaoPen/Brain/LLMVendor.swift",
    "Sources/XiaoPen/Brain/OllamaProvider.swift",
    "Sources/XiaoPen/Brain/ProviderCatalog.swift",
    "Sources/XiaoPen/Resources/Mascot.png",
    "Sources/XiaoPen/Resources/README.md",
    "Sources/XiaoPen/Resources/SponsorAlipay.png",
    "Sources/XiaoPen/Resources/SponsorWeChat.png",
    "Sources/XiaoPen/Skills/AssistantContext.swift",
    "Sources/XiaoPen/Skills/ReminderIntentParser.swift",
    "Sources/XiaoPen/Skills/ReminderStore.swift",
    "Sources/XiaoPen/Skills/Weather.swift",
    "Sources/XiaoPen/UI/FloatingHUDView.swift",
    "Sources/XiaoPen/UI/FloatingPanelController.swift",
    "Sources/XiaoPen/UI/SponsorView.swift",
    "Sources/XiaoPen/UI/WaveformVisualizer.swift",
})
FULL_INPUTS = frozenset({
    "Package.swift", "Package.resolved", "Resources/XiaoPen.entitlements",
    "docs/voice/model-manifest.json",
    "Sources/XiaoPen/Resources/voice-model-manifest.json",
    "Sources/XiaoPen/App/AppState.swift",
    "Sources/XiaoPen/App/XiaoPenApp.swift",
    "Sources/XiaoPen/Brain/ChatGPTAuth.swift",
    # These clients construct authentication headers or read/write credentials;
    # they are not ordinary model or UI changes merely because of their folder.
    "Sources/XiaoPen/Brain/AnthropicProvider.swift",
    "Sources/XiaoPen/Brain/ChatGPTResponsesProvider.swift",
    "Sources/XiaoPen/Brain/LLMHTTPClient.swift",
    "Sources/XiaoPen/Brain/OpenAIProvider.swift",
    "Sources/XiaoPen/UI/BrainSettingsForm.swift",
    "Sources/XiaoPen/Skills/LocationService.swift",
    "Sources/XiaoPen/UI/OnboardingView.swift",
    "Sources/XiaoPen/UI/SettingsView.swift",
})
NON_INPUTS = frozenset({
    "README.md", "README.zh-CN.md", "CHANGELOG.md", "LICENSE",
    ".github/FUNDING.yml",
})
VERSION_KEYS = frozenset({"CFBundleShortVersionString", "CFBundleVersion"})


class ReleasePolicyError(ValueError):
    """The requested commit range or tier cannot be safely planned."""


def _git(repo: Path, *args: str, allow_failure: bool = False) -> subprocess.CompletedProcess:
    env = dict(os.environ, GIT_NO_REPLACE_OBJECTS="1", GIT_OPTIONAL_LOCKS="0")
    try:
        result = subprocess.run(
            ["git", "--no-pager", "--literal-pathspecs", "-C", str(repo), *args],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, check=False,
        )
    except OSError as error:
        raise ReleasePolicyError(f"Cannot run Git: {error}") from error
    if result.returncode and not allow_failure:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise ReleasePolicyError(f"Git {args[0]} failed: {detail}")
    return result


def _commit(repo: Path, ref: str) -> str:
    if not isinstance(ref, str) or not ref or "\0" in ref:
        raise ReleasePolicyError("A nonempty Git commit reference is required.")
    return _git(repo, "rev-parse", "--verify", "--end-of-options", ref + "^{commit}").stdout.decode("ascii").strip()


def _changes(repo: Path, base: str, head: str) -> list[dict]:
    # NUL records preserve spaces, tabs, newlines and Git-quoted filenames.
    raw = _git(repo, "diff", "--name-status", "-z", "--find-renames=50%",
               "--no-relative", "--ignore-submodules=none", "--no-ext-diff",
               "--no-textconv", base, head, "--").stdout
    if not raw:
        return []
    fields = raw.split(b"\0")
    if fields.pop() != b"":
        raise ReleasePolicyError("Malformed Git diff records.")
    changes = []
    index = 0
    while index < len(fields):
        status = fields[index].decode("ascii")
        index += 1
        count = 2 if status.startswith(("R", "C")) else 1
        paths = fields[index:index + count]
        if len(paths) != count or any(not path for path in paths):
            raise ReleasePolicyError("Incomplete Git diff record.")
        index += count
        change = {"status": status, "path": paths[-1].decode("utf-8", "surrogateescape")}
        if count == 2:
            change["oldPath"] = paths[0].decode("utf-8", "surrogateescape")
        changes.append(change)
    return changes


def _nonregular_paths(repo: Path, base: str, head: str, changes: list[dict]) -> set[str]:
    paths = sorted({path for change in changes for path in
                    (change.get("oldPath"), change["path"]) if path is not None})
    unusual = set()
    if not paths:
        return unusual
    for commit in (base, head):
        raw = _git(repo, "ls-tree", "-z", commit, "--", *paths).stdout
        for entry in raw.split(b"\0"):
            if not entry:
                continue
            metadata, path = entry.split(b"\t", 1)
            if metadata.split(b" ", 1)[0] not in {b"100644", b"100755"}:
                unusual.add(path.decode("utf-8", "surrogateescape"))
    return unusual


def _version_only(repo: Path, base: str, head: str) -> bool:
    """Allow only version values or equivalent plist serialization to be standard."""
    plists = []
    for commit in (base, head):
        tree = _git(repo, "ls-tree", "-z", commit, "--", "Resources/Info.plist").stdout
        # Symlinks, executable mode changes and missing files are not a version bump.
        if not tree.startswith(b"100644 blob "):
            return False
        blob = _git(repo, "cat-file", "blob", commit + ":Resources/Info.plist").stdout
        try:
            data = plistlib.loads(blob)
            if not isinstance(data, dict) or any(not isinstance(data.get(key), str) for key in VERSION_KEYS):
                return False
            for key in VERSION_KEYS:
                del data[key]
            # Canonical bytes also distinguish bools from numbers, unlike dict ==.
            plists.append(plistlib.dumps(data, fmt=plistlib.FMT_BINARY, sort_keys=True))
        except (ValueError, TypeError, OverflowError, plistlib.InvalidFileException, ExpatError):
            return False
    return plists[0] == plists[1]


def _classify(path: str) -> tuple[str, str]:
    if path in FULL_INPUTS or path.startswith((
        "Sources/XiaoPen/Audio/", "Sources/XiaoPen/Storage/",
        "Sources/XiaoPen/System/", "Sources/XiaoPenSpeechWorker/",
        "scripts/", ".github/workflows/",
    )):
        return "full", "packaging, signing, permissions, authentication, audio, helper, dependency or release input"
    if path in STANDARD_INPUTS:
        return "standard", "ordinary product input"
    if path in NON_INPUTS:
        return "none", "documentation or repository metadata outside signing inputs"
    posix = PurePosixPath(path)
    if path.startswith("docs/") and posix.suffix.lower() == ".md":
        return "none", "documentation outside signing inputs"
    if path.startswith("docs/assets/") and posix.suffix.lower() in {".png", ".jpg", ".jpeg", ".svg", ".txt"}:
        return "none", "documentation asset outside signing inputs"
    if path.startswith("Tests/XiaoPenTests/") and posix.suffix == ".swift":
        return "none", "test source outside app and helper signing inputs"
    return "full", "unknown path; full acceptance required until its inputs are reviewed"


def plan_release(repo: Path, base_ref: str, head_ref: str = "HEAD", requested_tier=None) -> dict:
    """Return a deterministic JSON-compatible acceptance plan for an ancestor range.

    ``requested_tier`` may retain or raise the detected tier, never lower it.
    Raising a docs-only plan does not authorize publishing a new binary:
    ``binaryReleaseAllowed`` remains false when ``detectedTier`` is ``none``.
    Signing, notarization and artifact verification remain unconditional gates
    in the release runner for every binary release, including ``standard``.
    """
    if requested_tier is not None and requested_tier not in TIERS:
        raise ReleasePolicyError(f"Unknown requested tier: {requested_tier!r}")
    repo = Path(repo).resolve()
    top_level = _git(repo, "rev-parse", "--show-toplevel").stdout
    repo = Path(os.fsdecode(top_level[:-1] if top_level.endswith(b"\n") else top_level))
    base, head = _commit(repo, base_ref), _commit(repo, head_ref)
    ancestry = _git(repo, "merge-base", "--is-ancestor", base, head, allow_failure=True)
    if ancestry.returncode == 1:
        raise ReleasePolicyError("The baseline must be an ancestor of the source commit.")
    if ancestry.returncode:
        raise ReleasePolicyError("Git could not verify baseline ancestry.")
    changes = _changes(repo, base, head)
    nonregular = _nonregular_paths(repo, base, head, changes)
    detected = "none"
    reasons = []
    for change in changes:
        # Both rename endpoints matter: moving a sensitive input into docs must
        # not hide removal from the old location. Deletions use their old path.
        for path in dict.fromkeys([change.get("oldPath"), change["path"]]):
            if path is None:
                continue
            if path in nonregular:
                tier, reason = "full", "symlink, submodule or other nonregular input changed"
            elif change["status"][:1] not in {"A", "M", "D", "R", "C"}:
                tier, reason = "full", "file type or unrecognized Git status changed"
            elif path == "Resources/Info.plist":
                if change["status"] == "M" and _version_only(repo, base, head):
                    tier, reason = "standard", "only version/build values or equivalent plist serialization changed"
                else:
                    tier, reason = "full", "application identity, permission or bundle metadata may have changed"
            else:
                tier, reason = _classify(path)
            detected = max(detected, tier, key=TIERS.index)
            reasons.append(f"{path}: {reason}.")
    tier = requested_tier or detected
    if TIERS.index(tier) < TIERS.index(detected):
        raise ReleasePolicyError(f"Cannot lower detected tier {detected!r} to {tier!r}.")
    if tier != detected:
        reasons.append(f"Acceptance was raised from {detected} to the requested {tier} tier.")
    if detected == "none":
        reasons.append("No new signing or release inputs changed; publishing a new binary is not allowed.")
    return {
        "schemaVersion": 1,
        "baseline": {"ref": base_ref, "commit": base},
        "sourceCommit": head,
        "changedFiles": changes,
        "detectedTier": detected,
        "tier": tier,
        "binaryReleaseAllowed": detected != "none",
        "requiredChecks": list(FULL_CHECKS if tier == "full" else STANDARD_CHECKS if tier == "standard" else ()),
        "reasons": reasons,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--tier", choices=TIERS)
    args = parser.parse_args()
    try:
        result = plan_release(args.repo, args.base, args.head, args.tier)
    except ReleasePolicyError as error:
        parser.exit(2, f"Release policy error: {error}\n")
    print(json.dumps(result, indent=2, ensure_ascii=True))


if __name__ == "__main__":
    main()
