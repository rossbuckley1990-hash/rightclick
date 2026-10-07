# Release procedure — next candidate v0.2.3

v0.2.2 is already published and remains the Stable Homebrew pin. Its source and bottle checksums identify accepted historical bytes. GitHub currently reports this release as non-immutable; preserve the existing tag and assets regardless. Never replace or retag an existing version.

v0.2.3 is the next unpublished runtime candidate. Preparing this identity does not establish accepted packaging, native platform support, fresh installation or eleven-substrate acceptance. PR49 remains the candidate integration; its exact source, binary and remaining RED gates must be reviewed separately from the version number.

Stable and Edge plugin package versions are separate connector identities. Report `context_runtime` to identify the actual serving executable.

## Accepted code gate

Before tagging, publishing assets or changing the Stable tap formula, the integrated product must pass:

- `swift test`
- `scripts/build-cli.sh`
- relevant acceptance scripts under `scripts/`
- the applicable native macOS/Linux/Windows build, protected authority and real-provider gates; preserve every skipped or unproved boundary
- `python3 scripts/detect-bottle-alignment.py --write-manifest packaging/substrate-kinds.json`

Historical evidence remains unchanged.

## Prepare release source

The product version is defined by `RightClickVersion.current`.

Run:

    swift test
    scripts/build-cli.sh
    python3 scripts/package-source.py

`package-source.py` creates:

    dist/rightclick-0.2.3-source.tar.gz
    dist/SHA256SUMS-source
    packaging/homebrew/rightclick.rb
    packaging/tap/Formula/rightclick.rb
    packaging/substrate-kinds.json

The source archive is deterministic.

Repeating `package-source.py` with unchanged inputs must produce identical bytes.

The generated formula must point to:

    https://github.com/rossbuckley1990-hash/rightclick/releases/download/v0.2.3/rightclick-0.2.3-source.tar.gz

and must pin the exact SHA256 of the prepared source archive.

The old v0.1.0 bottle metadata is historical and must not be attached to v0.2.3.

## Substrate alignment gate

Before tagging, require:

    python3 scripts/detect-bottle-alignment.py --compare --bottle dist/rightclick-0.2.3-source.tar.gz

This proves the packaged asset contains every checkout substrate kind.

CI keeps candidate package alignment and published bottle alignment as separate checks. The candidate's complete native tests, builds, real-provider acceptance and deterministic source-package gates must pass before tagging its reviewed bytes. Public bottle drift remains a failing check while the tap still points at 0.2.2; it is not a runtime test failure and must not be suppressed.

Release staging therefore publishes the accepted candidate source first, independently re-downloads it, and verifies the matching new tap formula, bottle and fresh installation. Only then can the published bottle alignment check turn green. Do not merge the candidate PR until that public check and every other required check pass.

After the public tap moves, require:

    python3 scripts/detect-bottle-alignment.py --compare

Agents: see [BOTTLE-ALIGNMENT.md](BOTTLE-ALIGNMENT.md).

## Commit and tag

Do not commit or tag until the final release-candidate and source-package gates pass.

Before tagging, verify that `v0.2.3` does not already exist.

Then create the reviewed release commit and immutable tag:

    git tag -a v0.2.3 -m "RIGHTCLICK 0.2.3"
    git push origin v0.2.3

Never force-move an existing release tag.

## GitHub Release

After the tag exists, publish the exact prepared source bytes:

    gh release create v0.2.3 \
      dist/rightclick-0.2.3-source.tar.gz \
      dist/SHA256SUMS-source \
      --title "RIGHTCLICK 0.2.3" \
      --notes-file docs/RELEASE_NOTES_v0.2.3.md

Download the published source asset again and require its bytes and SHA256 to match the local accepted asset before changing the public Homebrew tap.

## Public Homebrew tap

Only after the release asset has been independently re-downloaded and verified should the public tap formula move from v0.2.2 to v0.2.3. Build and verify a new matching bottle through the tap’s reviewed-head publication workflow; never attach the old bottle checksum to new source.

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

Finally:

    python3 scripts/detect-bottle-alignment.py --compare

must exit `0`.

## Scope

Homebrew is the primary distribution path.

Developer ID signing, notarisation and standalone Apple application distribution remain separate from this release unless explicitly re-opened.
