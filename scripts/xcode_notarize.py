#!/usr/bin/env python3
"""Notarize a signed app through the existing Xcode account and public CLI.

An optional signed DMG is copied into a private upload-only app. That carrier
never becomes a release artifact: Apple's log must explicitly ticket the exact
DMG code hash before the caller may staple the original, separate DMG.
"""

import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid


class NotarizationError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise NotarizationError(message)


def command(parts, timeout=120):
    result = subprocess.run([str(part) for part in parts], capture_output=True, timeout=timeout)
    require(result.returncode == 0, f"Validation command failed: {parts[0]} (exit {result.returncode})")
    return result.stdout, result.stderr


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def bundle_hash(app):
    """Hash regular bytes and symlink destinations, including existing tickets."""
    digest = hashlib.sha256()
    for path in sorted(app.rglob("*")):
        relative = str(path.relative_to(app)).encode()
        if path.is_symlink():
            digest.update(b"L\0" + relative + b"\0" + str(path.readlink()).encode() + b"\0")
        elif path.is_file():
            digest.update(b"F\0" + relative + b"\0" + sha256(path).encode() + b"\0")
    return digest.hexdigest()


def payload_hash(app):
    """Compare source bytes while allowing Xcode signatures and stapled ticket.

Xcode legitimately re-signs both executables and the outer app. Strip signatures
only on private temporary Mach-O copies; all ordinary resources, symlinks, and
unsigned code bytes must remain identical to the archive that was submitted.
"""
    digest = hashlib.sha256()
    with tempfile.TemporaryDirectory(prefix="xiaopen-unsigned-comparison-") as temporary:
        unsigned_copy = Path(temporary) / "code"
        for path in sorted(app.rglob("*")):
            relative = path.relative_to(app)
            if "_CodeSignature" in relative.parts or str(relative) == "Contents/CodeResources":
                continue
            if path.is_symlink():
                digest.update(b"L\0" + str(relative).encode() + b"\0" + str(path.readlink()).encode() + b"\0")
            elif path.is_file():
                description, _ = command(["file", "-b", path])
                if b"Mach-O" in description:
                    shutil.copyfile(path, unsigned_copy)
                    command(["codesign", "--remove-signature", unsigned_copy])
                    file_digest = sha256(unsigned_copy)
                    unsigned_copy.unlink()
                else:
                    file_digest = sha256(path)
                digest.update(b"F\0" + str(relative).encode() + b"\0" + file_digest.encode() + b"\0")
    return digest.hexdigest()


def validate_symlinks(app):
    root = app.resolve()
    for path in app.rglob("*"):
        if path.is_symlink():
            try:
                path.resolve(strict=True).relative_to(root)
            except (OSError, ValueError) as error:
                raise NotarizationError(f"App symlink leaves its bundle or is broken: {path.relative_to(app)}") from error


def signature(path, identity, team, runtime=True):
    command(["codesign", "--verify", "--strict", path])
    stdout, stderr = command(["codesign", "--display", "--verbose=4", path])
    text = (stdout + stderr).decode("utf-8", errors="replace")
    require(f"Authority={identity}" in text.splitlines(), f"Unexpected Developer ID: {path.name}")
    require(f"TeamIdentifier={team}" in text.splitlines(), f"Unexpected signing team: {path.name}")
    require(re.search(r"^Timestamp=.+", text, re.M), f"No secure timestamp: {path.name}")
    if runtime:
        require(re.search(r"^CodeDirectory .*flags=.*\bruntime\b", text, re.M), f"No Hardened Runtime: {path.name}")
    match = re.search(r"^CDHash=([a-fA-F0-9]{40,64})$", text, re.M)
    require(match, f"No signed code hash: {path.name}")
    return match.group(1).lower()


def read_info(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        return plistlib.load(stream)


def verify_app(app, identity, team, wanted_entitlements):
    validate_symlinks(app)
    command(["codesign", "--verify", "--deep", "--strict", app])
    cdhash = signature(app, identity, team)
    entitlement_xml, _ = command(["codesign", "--display", "--entitlements", "-", "--xml", app])
    require(plistlib.loads(entitlement_xml) == wanted_entitlements, "Export changed app entitlements")
    for path in app.rglob("*"):
        if path.is_file() and not path.is_symlink():
            description, _ = command(["file", "-b", path])
            if b"Mach-O" in description:
                signature(path, identity, team)
    return cdhash


def matching_distribution(archive_info, team):
    records = [item for item in archive_info.get("Distributions", [])
               if item.get("teamID") == team and item.get("uploadDestination") == "Developer ID"]
    require(records, "Xcode did not record a Developer ID submission for the selected team")
    record = records[-1]
    try:
        identifier = str(uuid.UUID(record["identifier"]))
    except (KeyError, ValueError, TypeError, AttributeError) as error:
        raise NotarizationError("Xcode recorded no valid submission UUID") from error
    return identifier


def verify_apple_log(log, identifier, ticket_name, ticket_hash, architecture=None):
    require(str(log.get("jobId", "")).lower() == identifier.lower(), "Apple log submission UUID differs")
    require(log.get("status") == "Accepted" and log.get("statusCode") == 0, "Apple did not accept the submission")
    issues = log.get("issues") or []
    require(not any(str(item.get("severity", "")).lower() == "error" for item in issues), "Apple log contains errors")
    matches = [item for item in log.get("ticketContents", [])
               if str(item.get("path", "")).endswith("/" + ticket_name)
               and str(item.get("cdhash", "")).lower() == ticket_hash.lower()
               and (architecture is None or item.get("arch") == architecture)]
    require(matches, f"Apple log does not ticket the exact signed artifact: {ticket_name}")
    return {"warningCount": sum(str(item.get("severity", "")).lower() == "warning" for item in issues),
            "matchingTickets": matches}


def is_processing_error(text):
    errors = re.findall(r'^.*\berror:.*$', text, re.M)
    return bool(errors) and all(re.fullmatch(r'error: Archive .+ is processing and not ready for distribution\.', line)
                                for line in errors)


def run_logged(parts, log_path, timeout):
    with log_path.open("wb") as stream:
        result = subprocess.run([str(part) for part in parts], stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
    return result.returncode


def prepare_archive(args, source_app, evidence, wanted_entitlements):
    source_info = read_info(source_app)
    require(source_info.get("CFBundlePackageType") == "APPL", "Input is not an application")
    executable = source_info.get("CFBundleExecutable", "")
    require(executable and "/" not in executable and executable not in (".", ".."), "Invalid app executable")
    source_cdhash = verify_app(source_app, args.identity, args.team, wanted_entitlements)
    source_tree = bundle_hash(source_app)
    architectures, _ = command(["lipo", "-archs", source_app / "Contents/MacOS" / executable])
    architectures = architectures.decode().split()
    require(architectures == ["arm64"], "This release workflow requires the Apple Silicon app")
    archive = evidence / "xcode" / (args.label + ".xcarchive")
    require(not archive.exists(), "Archive already exists; preserve it and use a new evidence directory")
    archived_app = archive / "Products/Applications" / source_app.name
    archived_app.parent.mkdir(parents=True, mode=0o700)
    command(["ditto", source_app, archived_app])
    require(bundle_hash(archived_app) == source_tree, "Archive copy changed source app bytes")
    dmg_record = None
    if args.dmg:
        dmg = args.dmg.expanduser().resolve(strict=True)
        require(dmg.is_file() and dmg.suffix == ".dmg", "Carrier input must be a signed DMG")
        dmg_hash = signature(dmg, args.identity, args.team, runtime=False)
        dmg_sha = sha256(dmg)
        embedded = archived_app / "Contents/Resources/Distribution" / dmg.name
        require(not embedded.exists(), "DMG carrier resource already exists")
        embedded.parent.mkdir(parents=True, exist_ok=True)
        command(["ditto", dmg, embedded])
        require(sha256(embedded) == dmg_sha, "Copying changed the signed DMG")
        # Embedded code and the DMG are already signed. Only the private outer
        # resource seal changed; re-sign it without touching the shipped app.
        command(["codesign", "--force", "--sign", args.fingerprint, "--options", "runtime", "--timestamp",
                 "--entitlements", args.entitlements, archived_app])
        dmg_record = {"path": str(dmg), "filename": dmg.name, "sha256BeforeStapling": dmg_sha,
                      "cdhash": dmg_hash, "carrierRelativePath": str(embedded.relative_to(archived_app))}
    archived_cdhash = verify_app(archived_app, args.identity, args.team, wanted_entitlements)
    archived_payload_hash = payload_hash(archived_app)
    archive_info = {
        "ArchiveVersion": 2, "CreationDate": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
        "Name": source_app.stem, "SchemeName": source_app.stem,
        "ApplicationProperties": {"ApplicationPath": "Applications/" + source_app.name,
            "Architectures": architectures, "CFBundleIdentifier": source_info["CFBundleIdentifier"],
            "CFBundleShortVersionString": source_info["CFBundleShortVersionString"],
            "CFBundleVersion": source_info["CFBundleVersion"], "SigningIdentity": args.identity, "Team": args.team}}
    with (archive / "Info.plist").open("wb") as stream:
        plistlib.dump(archive_info, stream)
    options = archive.parent / (args.label + "-ExportOptions.plist")
    with options.open("wb") as stream:
        plistlib.dump({"method": "developer-id", "destination": "upload", "teamID": args.team,
                      "signingStyle": "manual", "signingCertificate": args.fingerprint,
                      "distributionBundleIdentifier": source_info["CFBundleIdentifier"],
                      "manageAppVersionAndBuildNumber": False, "stripSwiftSymbols": False, "uploadSymbols": False}, stream)
    prepared = {"archive": str(archive), "sourceApp": str(source_app), "sourceTreeSHA256": source_tree,
                "sourceCDHash": source_cdhash, "archivedCDHash": archived_cdhash, "teamID": args.team,
                "archivedPayloadSHA256": archived_payload_hash,
                "identity": args.identity, "exportOptions": str(options), "dmg": dmg_record,
                "status": "prepared-not-submitted"}
    (evidence / (args.label + "-xcode-prepared.json")).write_text(json.dumps(prepared, indent=2) + "\n")
    return archive, options, prepared, source_info


def notarize(args):
    require(sys.platform == "darwin", "Xcode notarization requires macOS")
    require(re.fullmatch(r"[A-Z0-9]{10}", args.team), "Invalid Developer team")
    require(args.identity.startswith("Developer ID Application: ") and args.identity.endswith("(" + args.team + ")"),
            "Select a Developer ID Application identity for this team")
    require(re.fullmatch(r"[a-fA-F0-9]{40}", args.fingerprint), "Select the signing certificate by SHA-1 fingerprint")
    require(args.label in ("app", "dmg"), "Unsupported evidence label")
    require(bool(args.dmg) == (args.label == "dmg"), "Only the DMG submission may contain a DMG carrier resource")
    source_app = args.app.expanduser().resolve(strict=True)
    require(source_app.is_dir() and source_app.suffix == ".app", "Input must be an app bundle")
    evidence = args.evidence.expanduser().resolve(strict=True)
    with args.entitlements.open("rb") as stream:
        wanted_entitlements = plistlib.load(stream)
    archive, options, prepared, source_info = prepare_archive(args, source_app, evidence, wanted_entitlements)
    if args.prepare_only:
        print(f"Prepared Xcode archive only: {archive}")
        return
    upload_log = evidence / (args.label + "-xcode-upload.log")
    print(f"Uploading {args.label} with the existing Xcode account; evidence: {evidence}", flush=True)
    result = run_logged(["xcodebuild", "-exportArchive", "-archivePath", archive, "-exportOptionsPlist", options,
                         "-exportPath", archive.parent / (args.label + "-upload"), "-allowProvisioningUpdates"], upload_log, 1800)
    require(result == 0, f"Xcode upload failed; see {upload_log}")
    with (archive / "Info.plist").open("rb") as stream:
        identifier = matching_distribution(plistlib.load(stream), args.team)
    prepared.update({"submissionID": identifier, "status": "uploaded-awaiting-apple"})
    (evidence / (args.label + "-xcode-submission.json")).write_text(json.dumps(prepared, indent=2) + "\n")
    print(f"Apple submission: {identifier}; awaiting notarized export", flush=True)
    deadline = time.monotonic() + 1200
    export_path = archive.parent / (args.label + "-notarized")
    attempt = 0
    while True:
        remaining = deadline - time.monotonic()
        require(remaining > 0, "Apple processing exceeded 20 minutes; archive and submission UUID are retained")
        attempt += 1
        export_log = evidence / f"{args.label}-xcode-export-{attempt:02d}.log"
        result = run_logged(["xcodebuild", "-exportNotarizedApp", "-archivePath", archive,
                             "-exportPath", export_path], export_log, min(300, remaining))
        if result == 0:
            break
        require(is_processing_error(export_log.read_text(errors="replace")), f"Xcode export failed; see {export_log}")
        time.sleep(min(20, max(0, deadline - time.monotonic())))
    exported_app = export_path / source_app.name
    require(exported_app.is_dir(), "Xcode did not export the expected app")
    exported_cdhash = verify_app(exported_app, args.identity, args.team, wanted_entitlements)
    require(payload_hash(exported_app) == prepared["archivedPayloadSHA256"], "Xcode changed archived executable payloads or resources")
    exported_info = read_info(exported_app)
    for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
        require(exported_info.get(key) == source_info[key], f"Xcode changed {key}")
    require(bundle_hash(source_app) == prepared["sourceTreeSHA256"], "Xcode changed the original app")
    apple_log_path = archive / "Submissions" / identifier.upper() / "notarization-log.json"
    require(apple_log_path.is_file(), "Xcode did not retain Apple's notarization log")
    apple_log = json.loads(apple_log_path.read_text())
    dmg = prepared["dmg"]
    if dmg:
        require(sha256(Path(dmg["path"])) == dmg["sha256BeforeStapling"], "Original signed DMG changed during upload")
        for carrier_app in (archive / "Products/Applications" / source_app.name, exported_app):
            require(sha256(carrier_app / dmg["carrierRelativePath"]) == dmg["sha256BeforeStapling"], "Xcode modified the DMG carrier resource")
        proof = verify_apple_log(apple_log, identifier, source_app.name + "/" + dmg["carrierRelativePath"], dmg["cdhash"])
    else:
        proof = verify_apple_log(apple_log, identifier, source_app.name, exported_cdhash, "arm64")
    (evidence / (args.label + "-notary-log.json")).write_text(json.dumps(apple_log, indent=2) + "\n")
    output = {**prepared, **proof, "status": "Accepted", "exportedApp": str(exported_app),
              "exportedCDHash": exported_cdhash, "appleLog": str(apple_log_path)}
    (evidence / (args.label + "-xcode-result.json")).write_text(json.dumps(output, indent=2) + "\n")
    print(f"Apple Accepted {args.label}: {identifier}; exact artifact ticket verified", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--team", required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--fingerprint", required=True)
    parser.add_argument("--entitlements", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--label", choices=("app", "dmg"), required=True)
    parser.add_argument("--dmg", type=Path)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    try:
        notarize(args)
    except (NotarizationError, OSError, ValueError, KeyError, subprocess.SubprocessError, plistlib.InvalidFileException) as error:
        print(f"Xcode notarization stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
