import importlib.util
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "scripts" / "update_appcast.py"
SPEC = importlib.util.spec_from_file_location("update_appcast", MODULE_PATH)
update_appcast = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(update_appcast)


BASE_FEED = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>SpaceNamer Updates</title>
    <item>
      <title>Version 3.1.18</title>
      <pubDate>Sun, 19 Jul 2026 22:17:21 +0000</pubDate>
      <sparkle:version>202607192216</sparkle:version>
      <sparkle:shortVersionString>3.1.18</sparkle:shortVersionString>
      <enclosure url="https://example.test/old.dmg" sparkle:edSignature="old" length="10" type="application/x-apple-diskimage" />
    </item>
  </channel>
</rss>
"""


class AppcastTests(unittest.TestCase):
    def test_upsert_is_idempotent_and_keeps_newest_first(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "appcast.xml"
            path.write_text(BASE_FEED)
            item = update_appcast.ReleaseItem(
                version="3.2.0",
                build=20260720000100,
                url="https://github.com/ZipLyne-Agency/SpaceNamer/releases/download/v3.2.0/SpaceNamer-3.2.0.dmg",
                signature="new-signature",
                length=42,
                publication_date="Mon, 20 Jul 2026 00:01:00 +0000",
            )

            update_appcast.update(path, item)
            update_appcast.update(path, item)

            releases = update_appcast.read_releases(path)
            self.assertEqual([release.version for release in releases], ["3.2.0", "3.1.18"])
            self.assertEqual(sum(release.version == "3.2.0" for release in releases), 1)

    def test_rejects_non_monotonic_new_build(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "appcast.xml"
            path.write_text(BASE_FEED)
            item = update_appcast.ReleaseItem(
                version="3.2.0",
                build=202607192216,
                url="https://example.test/new.dmg",
                signature="new-signature",
                length=42,
                publication_date="Mon, 20 Jul 2026 00:01:00 +0000",
            )

            with self.assertRaisesRegex(ValueError, "greater than existing build"):
                update_appcast.update(path, item)

    def test_bridge_contains_only_latest_release(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "appcast.xml"
            bridge = Path(directory) / "bridge-appcast.xml"
            path.write_text(BASE_FEED)
            item = update_appcast.ReleaseItem(
                version="3.2.0",
                build=20260720000100,
                url="https://example.test/new.dmg",
                signature="new-signature",
                length=42,
                publication_date="Mon, 20 Jul 2026 00:01:00 +0000",
            )

            update_appcast.update(path, item, bridge_path=bridge)

            releases = update_appcast.read_releases(bridge)
            self.assertEqual([release.version for release in releases], ["3.2.0"])


if __name__ == "__main__":
    unittest.main()
