import plistlib
import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
BUILD_NUMBER_SPEC = importlib.util.spec_from_file_location(
    "build_number", ROOT / "scripts" / "build_number.py"
)
build_number = importlib.util.module_from_spec(BUILD_NUMBER_SPEC)
BUILD_NUMBER_SPEC.loader.exec_module(build_number)


class ReleaseContractTests(unittest.TestCase):
    def test_build_number_is_deterministic_and_semver_monotonic(self):
        self.assertEqual(build_number.for_version("3.1.19"), 3_001_019_000_001)
        self.assertLess(build_number.for_version("3.1.19"), build_number.for_version("3.1.20"))
        self.assertLess(build_number.for_version("3.999.999"), build_number.for_version("4.0.0"))

    def test_bundle_metadata_moves_updates_to_canonical_repository(self):
        with (ROOT / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
        self.assertEqual(info["CFBundleShortVersionString"], "3.1.19")
        self.assertGreater(int(info["CFBundleVersion"]), 202607192216)
        self.assertEqual(
            info["SUFeedURL"],
            "https://raw.githubusercontent.com/ZipLyne-Agency/SpaceNamer/main/appcast.xml",
        )
        # This remains stable so installed users keep preferences and permissions.
        self.assertEqual(info["CFBundleIdentifier"], "com.isaac.spacenamer")

    def test_release_signs_dmg_before_notarizing_and_verifies_every_layer(self):
        script = (ROOT / "release.sh").read_text()
        dmg_sign = script.index('codesign --force --timestamp --sign "$IDENTITY" "$DMG"')
        dmg_notary = script.index('xcrun notarytool submit "$DMG"')
        self.assertLess(dmg_sign, dmg_notary)
        self.assertIn('xcrun stapler validate "$APP"', script)
        self.assertIn('xcrun stapler validate "$DMG"', script)
        self.assertIn('spctl --assess --type execute', script)
        self.assertIn('spctl --assess --type open', script)
        self.assertIn("key.isValidSignature", script)
        self.assertIn("--bridge-output", script)
        self.assertIn("already exists; releases are immutable", script)
        self.assertNotIn("--clobber", script)
        draft = script.index("--title \"SpaceNamer v$VERSION\" --notes \"$NOTES\"")
        feed_update = script.index('-f message="Publish appcast for v$VERSION"')
        publish = script.index('gh release edit "v$VERSION" --repo "$REPO" --draft=false')
        self.assertLess(draft, feed_update)
        self.assertLess(feed_update, publish)

    def test_release_workflow_is_gated_and_uses_same_repo_token(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("workflow_dispatch:", workflow)
        self.assertNotIn("push:", workflow)
        self.assertIn("GH_TOKEN: ${{ github.token }}", workflow)
        self.assertNotIn("RELEASES_PAT", workflow)
        self.assertIn("security default-keychain -s ci.keychain", workflow)
        self.assertNotIn("security default-keychain -s ci ci.keychain", workflow)

    def test_build_artifacts_are_not_source_control_inputs(self):
        ignores = (ROOT / ".gitignore").read_text().splitlines()
        self.assertIn("build/", ignores)
        self.assertIn("dist/", ignores)
        self.assertFalse((ROOT / "SpaceNamer.app").exists())


if __name__ == "__main__":
    unittest.main()
