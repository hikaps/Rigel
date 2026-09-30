#!/usr/bin/env python3
"""Behavioral tests for the AltStore source generator."""

from __future__ import annotations

import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPT = Path(__file__).with_name("generate-altstore-source.py")


class GeneratorTests(unittest.TestCase):
    def run_generator(
        self,
        channel: str,
        manifest: dict,
        version: str,
        build: str,
    ) -> dict:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa = root / "Rigel.ipa"
            output = root / "source.json"
            app_name = "Rigel.app"
            bundle_identifier = (
                "com.rigel.player" if channel == "stable" else "com.rigel.player.beta"
            )
            info = {
                "CFBundleIdentifier": bundle_identifier,
                "CFBundleShortVersionString": version,
                "CFBundleVersion": build,
            }
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr(
                    f"Payload/{app_name}/Info.plist",
                    plistlib.dumps(info),
                )
            output.write_text(json.dumps(manifest), encoding="utf-8")
            subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--channel",
                    channel,
                    "--ipa",
                    str(ipa),
                    "--output",
                    str(output),
                    "--download-url",
                    "https://example.invalid/rigel.ipa",
                    "--source-url",
                    "https://example.invalid/source.json",
                    "--icon-url",
                    "https://example.invalid/icon.png",
                    "--release-date",
                    "2026-09-24T00:00:00Z",
                ],
                check=True,
            )
            return json.loads(output.read_text(encoding="utf-8"))

    @staticmethod
    def app(bundle_identifier: str, version: str, build: str) -> dict:
        return {
            "name": "Rigel Beta" if bundle_identifier.endswith(".beta") else "Rigel",
            "bundleIdentifier": bundle_identifier,
            "versions": [{"version": version, "buildVersion": build}],
        }

    def test_stable_update_preserves_newer_beta_entry(self) -> None:
        newer_beta = self.app("com.rigel.player.beta", "1.0.900", "900")
        source = {
            "name": "Rigel",
            "identifier": "com.rigel.player.source",
            "sourceURL": "https://example.invalid/source.json",
            "apps": [newer_beta],
        }

        result = self.run_generator("stable", source, "1.0.1", "101")

        self.assertIn(newer_beta, result["apps"])
        stable = next(app for app in result["apps"] if app["bundleIdentifier"] == "com.rigel.player")
        self.assertEqual(stable["versions"][0]["buildVersion"], "101")

    def test_beta_update_preserves_newer_stable_entry(self) -> None:
        newer_stable = self.app("com.rigel.player", "2.0.0", "2000")
        source = {
            "name": "Rigel",
            "identifier": "com.rigel.player.source",
            "sourceURL": "https://example.invalid/source.json",
            "apps": [newer_stable],
        }

        result = self.run_generator("beta", source, "1.0.902", "902")

        self.assertIn(newer_stable, result["apps"])
        beta = next(app for app in result["apps"] if app["bundleIdentifier"] == "com.rigel.player.beta")
        self.assertEqual(beta["versions"][0]["buildVersion"], "902")


if __name__ == "__main__":
    unittest.main()
