#!/usr/bin/env python3
"""Build a self-contained, non-notarized Rayslides.app around the Zig executable."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


ICON_SIZES = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}


def info_plist(version: str) -> dict[str, object]:
    return {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": "Rayslides",
        "CFBundleDocumentTypes": [
            {
                "CFBundleTypeExtensions": ["sld"],
                "CFBundleTypeIconFile": "Rayslides.icns",
                "CFBundleTypeName": "Rayslides Deck",
                "CFBundleTypeRole": "Editor",
                "LSHandlerRank": "Owner",
            }
        ],
        "CFBundleExecutable": "rayslides",
        "CFBundleIconFile": "Rayslides.icns",
        "CFBundleIdentifier": "ai.technologylab.rayslides",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "Rayslides",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
        "LSApplicationCategoryType": "public.app-category.productivity",
        "LSMinimumSystemVersion": "13.0",
        "NSHighResolutionCapable": True,
        "NSHumanReadableCopyright": "Open-source software",
        "NSCameraUsageDescription": "Rayslides uses a camera only when a presentation camera item is started.",
        "UTExportedTypeDeclarations": [
            {
                "UTTypeConformsTo": ["public.plain-text"],
                "UTTypeDescription": "Rayslides Deck",
                "UTTypeIdentifier": "ai.technologylab.rayslides.deck",
                "UTTypeTagSpecification": {
                    "public.filename-extension": ["sld"],
                    "public.mime-type": "text/plain",
                },
            }
        ],
    }


def make_icon(source: Path, destination: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="rayslides-icon-") as temporary:
        iconset = Path(temporary) / "Rayslides.iconset"
        iconset.mkdir()
        for name, size in ICON_SIZES.items():
            subprocess.run(
                ["/usr/bin/sips", "-z", str(size), str(size), str(source), "--out", str(iconset / name)],
                check=True,
                stdout=subprocess.DEVNULL,
            )
        subprocess.run(
            ["/usr/bin/iconutil", "-c", "icns", str(iconset), "-o", str(destination)],
            check=True,
        )


def verify_bundle(bundle: Path, version: str) -> None:
    plist_path = bundle / "Contents" / "Info.plist"
    binary = bundle / "Contents" / "MacOS" / "rayslides"
    icon = bundle / "Contents" / "Resources" / "Rayslides.icns"
    with plist_path.open("rb") as file:
        plist = plistlib.load(file)
    if plist.get("CFBundleShortVersionString") != version:
        raise RuntimeError("bundle version does not match the requested version")
    if plist.get("CFBundleExecutable") != "rayslides":
        raise RuntimeError("bundle executable metadata is invalid")
    if not plist.get("NSCameraUsageDescription"):
        raise RuntimeError("bundle does not declare its camera usage")
    extensions = plist["CFBundleDocumentTypes"][0]["CFBundleTypeExtensions"]
    if "sld" not in extensions:
        raise RuntimeError("bundle does not advertise .sld documents")
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise RuntimeError("bundle executable is missing or not executable")
    if not icon.is_file() or icon.stat().st_size == 0:
        raise RuntimeError("bundle icon is missing")


def seal_adhoc(bundle: Path) -> None:
    # Apple Silicon executables carry a linker-generated ad-hoc signature. The
    # bundle's plist and icon are added afterward, so seal the final directory
    # with another local ad-hoc signature. This uses no identity, certificate,
    # developer account, or notarization service.
    subprocess.run(
        ["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(bundle)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)],
        check=True,
        stdout=subprocess.DEVNULL,
    )


def package(binary: Path, output: Path, version: str, icon_source: Path) -> None:
    if output.exists():
        shutil.rmtree(output)
    macos = output / "Contents" / "MacOS"
    resources = output / "Contents" / "Resources"
    macos.mkdir(parents=True)
    resources.mkdir()

    packaged_binary = macos / "rayslides"
    shutil.copy2(binary, packaged_binary)
    packaged_binary.chmod(packaged_binary.stat().st_mode | 0o111)
    with (output / "Contents" / "Info.plist").open("wb") as file:
        plistlib.dump(info_plist(version), file, fmt=plistlib.FMT_XML, sort_keys=True)
    (output / "Contents" / "PkgInfo").write_bytes(b"APPL????")
    make_icon(icon_source, resources / "Rayslides.icns")
    verify_bundle(output, version)
    seal_adhoc(output)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--icon", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    package(args.binary.resolve(), args.output.resolve(), args.version, args.icon.resolve())
    print(f"Packaged locally ad-hoc-signed, non-notarized app: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
