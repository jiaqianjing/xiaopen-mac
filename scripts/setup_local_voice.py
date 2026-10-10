#!/usr/bin/env python3
"""Install a pinned, hash-verified Qwen3-TTS model without a Python ML runtime."""
from __future__ import annotations

import argparse
import concurrent.futures
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import urllib.parse


def verified(path, entry):
    if not path.is_file() or path.is_symlink() or path.stat().st_size != entry["size"]:
        return False
    digest = hashlib.sha256() if entry["algorithm"] == "sha256" else hashlib.sha1()
    if entry["algorithm"] == "git-sha1":
        digest.update(f"blob {entry['size']}\0".encode())
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest() == entry["hash"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", choices=("hf", "modelscope"), default="hf")
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--model-dir", type=Path)
    args = parser.parse_args()
    manifest = json.loads((Path(__file__).resolve().parents[1] / "docs/voice/model-manifest.json").read_text())
    directory = args.model_dir or Path.home() / "Library/Application Support/XiaoPen/Models" / manifest["repository"].split("/")[-1]
    if directory.is_symlink():
        raise RuntimeError("Model directory must not be a symlink.")
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / ".install.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)

        def install(entry):
            relative = Path(entry["path"])
            if relative.is_absolute() or ".." in relative.parts:
                raise RuntimeError("Invalid model manifest path.")
            target = directory / relative
            if verified(target, entry):
                print(f"Verified: {relative}", flush=True)
                return
            if args.verify_only:
                raise RuntimeError(f"Missing or incorrect model file: {relative}")
            if target.is_symlink():
                raise RuntimeError(f"Model file must not be a symlink: {relative}")
            target.parent.mkdir(parents=True, exist_ok=True)
            staging = target.with_name("." + target.name + ".download")
            if staging.is_symlink():
                raise RuntimeError("Download staging file must not be a symlink.")
            quoted = urllib.parse.quote(entry["path"], safe="/")
            if args.source == "hf":
                url = f"https://huggingface.co/{manifest['repository']}/resolve/{manifest['revision']}/{quoted}"
            else:
                url = f"https://modelscope.cn/models/{manifest['repository']}/resolve/master/{quoted}?xiaopen={manifest['revision']}"
            subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--connect-timeout", "20",
                            "--continue-at", "-", "--output", str(staging), url], check=True)
            if not verified(staging, entry):
                raise RuntimeError(f"Checksum mismatch: {relative}; published model was not installed.")
            os.replace(staging, target)
            print(f"Installed and verified: {relative}", flush=True)

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            list(executor.map(install, manifest["files"]))
    print(f"Ready: {directory}\nRevision: {manifest['revision']}")


if __name__ == "__main__":
    main()
