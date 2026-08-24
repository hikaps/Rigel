#!/usr/bin/env python3
"""Generate an AltStore/SideStore-compatible source from an exported IPA."""

from __future__ import annotations

import argparse
import json
import plistlib
import zipfile
from datetime import datetime, timezone
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--source-url", required=True)
    parser.add_argument("--icon-url", required=True)
    parser.add_argument("--release-date", default=None)
    return parser.parse_args()


def read_app_info(ipa: Path) -> tuple[str, str]:
    with zipfile.ZipFile(ipa) as archive:
        info_path = next(
            (
                name
                for name in archive.namelist()
                if len(Path(name).parts) == 3
                and Path(name).parts[0] == "Payload"
                and Path(name).parts[1].endswith(".app")
                and Path(name).parts[2] == "Info.plist"
            ),
            None,
        )
        if info_path is None:
            raise ValueError(f"main app Info.plist not found in {ipa}")
        with archive.open(info_path) as info_file:
            info = plistlib.load(info_file)

    try:
        bundle_identifier = str(info["CFBundleIdentifier"])
        version = str(info["CFBundleShortVersionString"])
        build = str(info["CFBundleVersion"])
    except KeyError as error:
        raise ValueError(f"missing {error.args[0]} in {info_path}") from error
    if bundle_identifier != "com.rigel.player":
        raise ValueError(f"unexpected app bundle identifier: {bundle_identifier}")
    if not version or not build:
        raise ValueError("CFBundleShortVersionString and CFBundleVersion must be non-empty")
    return version, build


def main() -> None:
    args = parse_args()
    if not args.ipa.is_file():
        raise SystemExit(f"IPA does not exist: {args.ipa}")

    version, build = read_app_info(args.ipa)
    release_date = args.release_date or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    source = {
        "name": "Rigel",
        "identifier": "com.rigel.player.source",
        "sourceURL": args.source_url,
        "apps": [
            {
                "name": "Rigel",
                "bundleIdentifier": "com.rigel.player",
                "developerName": "Rigel contributors",
                "subtitle": "Play media formats iOS does not natively support.",
                "localizedDescription": "Rigel is an iOS media player for HTTP(S) links, local files, HLS, Jellyfin, and formats such as MKV, WebM, AVI, MPEG-TS, and FLV. It can cast to DLNA, Kodi, Roku, and AirPlay devices, and can act as a UPnP renderer.",
                "iconURL": args.icon_url,
                "tintColor": "#243B53",
                "permissions": [
                    {
                        "type": "network",
                        "usageDescription": "Rigel discovers and connects to media devices on your local network.",
                    },
                    {
                        "type": "background-audio",
                        "usageDescription": "Rigel continues audio playback while the app is in the background.",
                    },
                ],
                "appPermissions": {
                    "entitlements": [],
                    "privacy": {
                        "NSLocalNetworkUsageDescription": "Rigel discovers TVs on your local network (DLNA, Roku).",
                    },
                },
                "versions": [
                    {
                        "version": version,
                        "date": release_date,
                        "downloadURL": args.download_url,
                        "localizedDescription": f"Rolling beta build {build}. This IPA is development-signed and may require re-signing for your device.",
                        "size": args.ipa.stat().st_size,
                        "minOSVersion": "16.0",
                    }
                ],
            }
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(source, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
