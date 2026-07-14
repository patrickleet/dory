#!/usr/bin/env python3
"""Validate the public release manifest and complete Sparkle appcast contract."""

import base64
import email.utils
import hashlib
import json
import os
import pathlib
import re
import sys
import urllib.parse
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MANIFEST_KEYS = {
    "schemaVersion",
    "version",
    "build",
    "sourceCommit",
    "publicRelease",
    "bundleEngine",
    "notarized",
    "variants",
    "artifacts",
}
RECORD_KEYS = {"name", "path", "kind", "bytes", "sha256"}
VERSION_PATTERN = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_manifest(build_dir: pathlib.Path, version: str, build: str) -> tuple[dict, str]:
    path = build_dir / "release-manifest.json"
    manifest = json.loads(path.read_text(encoding="utf-8"))
    require(isinstance(manifest, dict) and set(manifest) == MANIFEST_KEYS, "release manifest shape is invalid")
    require(manifest["schemaVersion"] == 2, "unexpected release manifest schema")
    require(manifest["version"] == version, "manifest version mismatch")
    require(str(manifest["build"]) == build, "manifest build mismatch")
    source_commit = manifest["sourceCommit"]
    require(
        isinstance(source_commit, str)
        and re.fullmatch(r"[0-9a-f]{40}", source_commit) is not None,
        "manifest sourceCommit is not a full lowercase Git SHA",
    )
    require(manifest["publicRelease"] is True, "manifest is not marked as a public release")
    require(manifest["bundleEngine"] is True, "manifest describes an app-only release")
    require(manifest["notarized"] is True, "manifest describes an unnotarized release")
    require(manifest["variants"] == "arm64", "manifest is not Apple-Silicon-only")

    required = {
        f"Dory-{version}-arm64.zip",
        f"Dory-{version}.zip",
        f"Dory-{version}-arm64.dmg",
        f"Dory-{version}.dmg",
        f"Dory-{version}-lite.zip",
        f"Dory-{version}-app-update.zip",
        f"dory-engine-{version}-arm64.tar.gz",
        f"Dory-{version}.cdx.json",
        "appcast.xml",
    }
    records = manifest["artifacts"]
    require(isinstance(records, list) and records, "manifest has no artifacts")
    require(
        all(isinstance(record, dict) and set(record) == RECORD_KEYS for record in records),
        "manifest artifact record shape is invalid",
    )
    by_name = {record["name"]: record for record in records}
    require(len(by_name) == len(records), "manifest contains duplicate artifact names")
    require(set(by_name) == required, f"manifest artifact set mismatch: {sorted(set(by_name) ^ required)}")
    for name, record in by_name.items():
        require(record["path"] == name, f"manifest path is not portable: {name}")
        require(isinstance(record["kind"], str) and record["kind"], f"manifest kind is invalid: {name}")
        artifact = build_dir / name
        require(artifact.is_file(), f"manifest artifact is missing: {name}")
        require(record["bytes"] == artifact.stat().st_size, f"manifest byte count mismatch: {name}")
        require(record["sha256"] == sha256_file(artifact), f"manifest SHA-256 mismatch: {name}")
    require(by_name[f"Dory-{version}.cdx.json"]["kind"] == "cyclonedx-json", "SBOM artifact kind mismatch")
    return by_name, source_commit


def validate_appcast(build_dir: pathlib.Path, version: str, build: str) -> None:
    root = ET.parse(build_dir / "appcast.xml").getroot()
    require(root.tag == "rss" and root.attrib == {"version": "2.0"}, "appcast root is invalid")
    channel = root.find("channel")
    require(channel is not None, "appcast has no channel")
    require(channel.findtext("title") == "Dory", "appcast channel identity mismatch")
    require(channel.findtext("link") == "https://augani.github.io/dory/appcast.xml", "appcast link mismatch")
    require(
        channel.findtext("description") == "Updates for Dory - native Docker and Linux containers for macOS.",
        "appcast description mismatch",
    )
    require(channel.findtext("language") == "en", "appcast language mismatch")
    items = channel.findall("item")
    require(bool(items), "appcast has no current item")
    require(items[0].findtext(f"{{{SPARKLE}}}version") == build, "appcast build mismatch")
    require(items[0].findtext(f"{{{SPARKLE}}}shortVersionString") == version, "appcast version mismatch")

    expected_name = f"Dory-{version}-app-update.zip"
    expected_size = (build_dir / expected_name).stat().st_size
    seen_builds: set[str] = set()
    seen_versions: set[str] = set()
    for index, item in enumerate(items):
        release_build = item.findtext(f"{{{SPARKLE}}}version", "")
        release_version = item.findtext(f"{{{SPARKLE}}}shortVersionString", "")
        require(release_build.isdigit() and int(release_build) > 0, "appcast item build is invalid")
        require(VERSION_PATTERN.fullmatch(release_version) is not None, "appcast item version is invalid")
        require(release_build not in seen_builds, f"duplicate appcast build: {release_build}")
        require(release_version not in seen_versions, f"duplicate appcast version: {release_version}")
        seen_builds.add(release_build)
        seen_versions.add(release_version)
        require(item.findtext("title") == release_version, f"appcast {release_version} title mismatch")
        require(
            item.findtext(f"{{{SPARKLE}}}minimumSystemVersion") == "14.0",
            f"appcast {release_version} macOS floor mismatch",
        )
        publication_date = email.utils.parsedate_to_datetime(item.findtext("pubDate", ""))
        require(publication_date.tzinfo is not None, f"appcast {release_version} publication date is invalid")
        enclosure = item.find("enclosure")
        require(enclosure is not None, f"appcast {release_version} item has no enclosure")
        expected_attributes = {"url", f"{{{SPARKLE}}}edSignature", "length", "type"}
        require(set(enclosure.attrib) == expected_attributes, f"appcast {release_version} enclosure shape is invalid")
        parsed_url = urllib.parse.urlparse(enclosure.attrib["url"])
        filename = os.path.basename(parsed_url.path)
        require(
            parsed_url.scheme == "https"
            and parsed_url.netloc == "github.com"
            and not parsed_url.params
            and not parsed_url.query
            and not parsed_url.fragment,
            f"appcast {release_version} enclosure is not a canonical GitHub URL",
        )
        require(
            parsed_url.path.startswith(f"/Augani/dory/releases/download/v{release_version}/"),
            f"appcast {release_version} enclosure is outside its versioned Dory release",
        )
        require(
            filename.startswith(f"Dory-{release_version}") and filename.endswith(".zip"),
            f"appcast {release_version} enclosure filename is invalid",
        )
        require(enclosure.attrib["type"] == "application/octet-stream", "appcast enclosure type is invalid")
        length = enclosure.attrib["length"]
        require(length.isdigit() and int(length) > 0, f"appcast {release_version} length is invalid")
        signature = base64.b64decode(enclosure.attrib[f"{{{SPARKLE}}}edSignature"], validate=True)
        require(len(signature) == 64, f"appcast {release_version} EdDSA signature length is invalid")
        if index == 0:
            require(filename == expected_name, f"appcast points at {filename!r}, expected {expected_name!r}")
            require(int(length) == expected_size, "appcast length mismatch")
        else:
            require(
                int(release_build) < int(build),
                f"historical appcast build {release_build} is not older than {build}",
            )


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: validate-release-metadata.py <build-dir> <version> <build>")
    build_dir = pathlib.Path(sys.argv[1])
    version, build = sys.argv[2:]
    _, source_commit = validate_manifest(build_dir, version, build)
    validate_appcast(build_dir, version, build)
    print(source_commit)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, ET.ParseError) as error:
        raise SystemExit(f"release metadata error: {error}") from error
