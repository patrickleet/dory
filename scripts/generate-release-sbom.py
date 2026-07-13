#!/usr/bin/env python3
"""Generate a deterministic CycloneDX inventory for the exact shipped Dory.app tree."""

import argparse
import hashlib
import json
import os
import pathlib
import stat
import urllib.parse
import uuid


def digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def digest_file(path: pathlib.Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def inventory(app: pathlib.Path) -> tuple[list[dict[str, object]], str]:
    components: list[dict[str, object]] = []
    tree = hashlib.sha256()
    for path in sorted(app.rglob("*"), key=lambda item: item.relative_to(app.parent).as_posix()):
        relative = path.relative_to(app.parent).as_posix()
        metadata = path.lstat()
        if stat.S_ISREG(metadata.st_mode):
            kind = "regular"
            sha256 = digest_file(path)
            size = metadata.st_size
        elif stat.S_ISLNK(metadata.st_mode):
            kind = "symlink"
            target = os.readlink(path)
            encoded = target.encode("utf-8")
            sha256 = digest_bytes(encoded)
            size = len(encoded)
        else:
            continue
        mode = f"{stat.S_IMODE(metadata.st_mode):04o}"
        bom_ref = "dory-file:" + urllib.parse.quote(relative, safe="/._-")
        components.append(
            {
                "type": "file",
                "bom-ref": bom_ref,
                "name": relative,
                "hashes": [{"alg": "SHA-256", "content": sha256}],
                "properties": [
                    {"name": "dev.dory.file.type", "value": kind},
                    {"name": "dev.dory.file.mode", "value": mode},
                    {"name": "dev.dory.file.size", "value": str(size)},
                ],
            }
        )
        tree.update(f"{relative}\0{kind}\0{mode}\0{size}\0{sha256}\n".encode())
    return components, tree.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=pathlib.Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    if not args.app.is_dir() or args.app.name != "Dory.app":
        raise SystemExit(f"exact Dory.app is missing: {args.app}")
    if len(args.source_commit) != 40 or any(char not in "0123456789abcdef" for char in args.source_commit):
        raise SystemExit("source commit must be a full lowercase Git SHA")

    components, tree_sha256 = inventory(args.app)
    if not components:
        raise SystemExit("Dory.app inventory is empty")
    root_ref = f"pkg:github/Augani/dory@{args.version}?commit={args.source_commit}"
    serial = uuid.uuid5(uuid.NAMESPACE_URL, f"{root_ref}#{tree_sha256}")
    document = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{serial}",
        "version": 1,
        "metadata": {
            "component": {
                "type": "application",
                "bom-ref": root_ref,
                "group": "Augani",
                "name": "Dory",
                "version": args.version,
                "licenses": [{"license": {"id": "GPL-3.0-only"}}],
                "properties": [
                    {"name": "dev.dory.source.commit", "value": args.source_commit},
                    {"name": "dev.dory.app.tree.sha256", "value": tree_sha256},
                    {"name": "dev.dory.inventory.scope", "value": "exact-shipped-app-files"},
                ],
            }
        },
        "components": components,
        "dependencies": [{"ref": root_ref, "dependsOn": [item["bom-ref"] for item in components]}],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
