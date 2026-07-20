# Releasing SpaceNamer

SpaceNamer releases are produced only from `ZipLyne-Agency/SpaceNamer`. A push
to `main` never publishes a release; a maintainer must manually dispatch the
`release` workflow and provide an explicit numeric `MAJOR.MINOR.PATCH` version.

## Required GitHub Actions secrets

- `BUILD_CERTIFICATE`: base64-encoded Developer ID Application PKCS#12
- `CERT_PASSWORD`: password for that PKCS#12
- `NOTARY_KEY`: App Store Connect API private key contents
- `NOTARY_KEY_ID`: App Store Connect API key ID
- `NOTARY_ISSUER`: App Store Connect issuer UUID
- `SPARKLE_ED_KEY`: existing Sparkle EdDSA private key

The workflow uses `github.token` with `contents: write`. Do not add a
`RELEASES_PAT`; release assets and `appcast.xml` live in the same repository.

## Release invariants

- The release version and numeric bundle build must exceed every existing feed
  item. Bundle builds are derived deterministically from semantic version and
  do not depend on time or commit count.
- Both `SpaceNamer.app` and the DMG container are Developer-ID signed.
- Both are submitted to Apple notarization and stapled.
- Gatekeeper and stapler validation must pass for both artifacts.
- Sparkle signs the final, already-stapled DMG; the workflow verifies the
  signature against `SUPublicEDKey` before publishing.
- `scripts/update_appcast.py` replaces a matching version and never appends a
  duplicate item.
- Existing release tags are immutable. A repeated version is refused instead
  of overwriting assets. A new release remains a draft until the canonical feed
  update succeeds; a later failure rolls the feed back before exiting.

## One-time compatibility bridge (3.1.19)

These are intentionally human-gated migration steps. Do not archive or delete
the compatibility repository until all checks pass.

1. Commit and publish the audited canonical source, including its carried-forward
   `appcast.xml`, before releasing.
2. Dispatch the canonical `release` workflow with version `3.1.19`.
3. Verify the canonical release contains `SpaceNamer-3.1.19.dmg` and
   `spacenamer-releases-appcast.xml`.
4. Download `spacenamer-releases-appcast.xml`. It must contain exactly one item,
   version 3.1.19, whose enclosure points to the canonical repository.
5. Replace `appcast.xml` in `ZipLyne-Agency/spacenamer-releases` with that file,
   commit it, and publish that single compatibility update.
6. Fetch both raw feeds without authentication. Confirm the compatibility feed
   exposes 3.1.19 and the canonical feed exposes 3.1.19 plus historical items.
7. From a pre-3.1.19 installed build, use **Check for Updates**, install 3.1.19,
   relaunch, and confirm its bundled `SUFeedURL` is the canonical feed.
8. Only then archive `spacenamer-releases` remotely. Keep it public and do not
   delete its feed or historical releases; old installed builds still request it.

Every later release is dispatched and hosted only from the canonical repository.
