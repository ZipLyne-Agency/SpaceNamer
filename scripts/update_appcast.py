#!/usr/bin/env python3
"""Insert or replace a signed SpaceNamer release in a Sparkle appcast."""

from __future__ import annotations

import argparse
import copy
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import NamedTuple


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SPARKLE = f"{{{SPARKLE_NAMESPACE}}}"
ET.register_namespace("sparkle", SPARKLE_NAMESPACE)


class ReleaseItem(NamedTuple):
    version: str
    build: int
    url: str
    signature: str
    length: int
    publication_date: str


def _version_tuple(version: str) -> tuple[int, int, int]:
    parts = version.split(".")
    if len(parts) != 3 or any(not part.isdigit() for part in parts):
        raise ValueError(f"version must be numeric MAJOR.MINOR.PATCH, got {version!r}")
    return tuple(int(part) for part in parts)  # type: ignore[return-value]


def _release_from_element(item: ET.Element) -> ReleaseItem:
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("appcast item is missing its enclosure")
    version = item.findtext(f"{SPARKLE}shortVersionString")
    build = item.findtext(f"{SPARKLE}version")
    publication_date = item.findtext("pubDate")
    if not version or not build or not publication_date:
        raise ValueError("appcast item is missing version metadata")
    return ReleaseItem(
        version=version,
        build=int(build),
        url=enclosure.attrib["url"],
        signature=enclosure.attrib[f"{SPARKLE}edSignature"],
        length=int(enclosure.attrib["length"]),
        publication_date=publication_date,
    )


def read_releases(path: Path) -> list[ReleaseItem]:
    tree = ET.parse(path)
    channel = tree.getroot().find("channel")
    if channel is None:
        raise ValueError(f"{path} has no RSS channel")
    return [_release_from_element(item) for item in channel.findall("item")]


def _make_element(release: ReleaseItem) -> ET.Element:
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Version {release.version}"
    ET.SubElement(item, "pubDate").text = release.publication_date
    ET.SubElement(item, f"{SPARKLE}version").text = str(release.build)
    ET.SubElement(item, f"{SPARKLE}shortVersionString").text = release.version
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": release.url,
            f"{SPARKLE}edSignature": release.signature,
            "length": str(release.length),
            "type": "application/x-apple-diskimage",
        },
    )
    return item


def _write(tree: ET.ElementTree, path: Path) -> None:
    ET.indent(tree, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=True)
    with path.open("a", encoding="utf-8") as output:
        output.write("\n")


def update(path: Path, release: ReleaseItem, bridge_path: Path | None = None) -> None:
    _version_tuple(release.version)
    if release.build <= 0 or release.length <= 0:
        raise ValueError("build and length must be positive integers")

    tree = ET.parse(path)
    channel = tree.getroot().find("channel")
    if channel is None:
        raise ValueError(f"{path} has no RSS channel")

    existing_items = channel.findall("item")
    existing = [_release_from_element(item) for item in existing_items]
    same_version = [item for item in existing if item.version == release.version]
    other_releases = [item for item in existing if item.version != release.version]
    if same_version:
        if any(item.build != release.build for item in same_version):
            raise ValueError(f"version {release.version} already exists with a different build")
    else:
        if other_releases and release.build <= max(item.build for item in other_releases):
            raise ValueError("new build must be greater than existing build numbers")
        if other_releases and _version_tuple(release.version) <= max(_version_tuple(item.version) for item in other_releases):
            raise ValueError("new version must be greater than existing versions")

    for item in existing_items:
        channel.remove(item)
    channel.append(_make_element(release))
    for item in existing_items:
        parsed = _release_from_element(item)
        if parsed.version != release.version:
            channel.append(item)
    _write(tree, path)

    if bridge_path is not None:
        bridge_root = ET.Element("rss", {"version": "2.0"})
        bridge_channel = ET.SubElement(bridge_root, "channel")
        ET.SubElement(bridge_channel, "title").text = "SpaceNamer Compatibility Updates"
        bridge_channel.append(copy.deepcopy(_make_element(release)))
        _write(ET.ElementTree(bridge_root), bridge_path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appcast", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--length", type=int, required=True)
    parser.add_argument("--publication-date", required=True)
    parser.add_argument("--bridge-output", type=Path)
    args = parser.parse_args()
    update(
        args.appcast,
        ReleaseItem(
            version=args.version,
            build=args.build,
            url=args.url,
            signature=args.signature,
            length=args.length,
            publication_date=args.publication_date,
        ),
        bridge_path=args.bridge_output,
    )


if __name__ == "__main__":
    main()
