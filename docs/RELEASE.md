# Release procedure — v0.2.1

v0.2.0 is immutable and must not be replaced or retagged.

v0.2.1 is the next release line.

## Accepted code gate

Before release metadata was changed, the integrated product passed:

- 219 tests
- 0 skipped
- 0 failures
- 8/8 real environment-backed acceptance tests
- 7/7 generic bearer-authority tests
- three consecutive real Bonjour lifecycle controls
- zero forbidden cross-origin sink requests
- profile-redirection fail-closed testing
- Homebrew stable-entrypoint and upgrade-continuity testing

Historical evidence remains unchanged.

## Prepare release source

The product version is defined by RightClickVersion.current.

Run:

    swift test
    scripts/build-cli.sh
    python3 scripts/package-source.py

package-source.py creates:

    dist/rightclick-0.2.1-source.tar.gz
    dist/SHA256SUMS-source
    packaging/homebrew/rightclick.rb
    packaging/tap/Formula/rightclick.rb

The source archive is deterministic.

Repeating package-source.py with unchanged inputs must produce identical bytes.

The generated formula must point to:

    https://github.com/rossbuckley1990-hash/rightclick/releases/download/v0.2.1/rightclick-0.2.1-source.tar.gz

and must pin the exact SHA256 of the prepared source archive.

The old v0.1.0 bottle metadata is historical and must not be attached to v0.2.1.

## Commit and tag

Do not commit or tag until the final release-candidate and source-package gates pass.

Before tagging, verify that v0.2.1 does not already exist.

Then create the reviewed release commit and immutable tag:

    git tag -a v0.2.1 -m "RIGHTCLICK 0.2.1"
    git push origin v0.2.1

Never force-move an existing release tag.

## GitHub Release

After the tag exists, publish the exact prepared source bytes:

    gh release create v0.2.1 \
      dist/rightclick-0.2.1-source.tar.gz \
      dist/SHA256SUMS-source \
      --title "RIGHTCLICK 0.2.1" \
      --notes-file docs/RELEASE_NOTES_v0.2.1.md

Download the published source asset again and require its bytes and SHA256 to match the local accepted asset before changing the public Homebrew tap.

## Public Homebrew tap

Only after the release asset has been independently re-downloaded and verified should the public tap formula move from v0.2.0 to v0.2.1.

The formula must retain the pinned OpenAI tunnel-client compatibility resource and its licence/notice material.

Run Homebrew's formula test and the project acceptance gates against the installed package.

## Public installed-product acceptance

From outside the development checkout, require:

    brew update
    brew upgrade rightclick
    rightclick version
    rightclick doctor
    brew test rossbuckley1990-hash/tap/rightclick
    rightclick setup chatgpt --dry-run --json

The installed executable must resolve through the stable Homebrew entrypoint.

For an existing paired ChatGPT bridge, require the same tunnel identity to survive the package upgrade and require live runtime attestation to point at the new installed bytes.

Repeat the profile-redirection red-team against the released installed build before declaring the release complete.

## Scope

Homebrew is the primary distribution path.

Developer ID signing, notarisation and standalone Apple application distribution remain separate from this release unless explicitly re-opened.
