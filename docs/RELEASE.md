# Release procedure — 0.1.0

Apple Silicon/macOS 14+. The capability engine is frozen; do not expand it to resolve distribution gates. No public repository, release, asset, or tap was created during this work.

## Gates

The unsigned local candidate builds, tests, packages, and installs through a temporary Homebrew tap. Public distribution is blocked: no Developer ID Application identity is installed, notarisation credentials have not been supplied, Gatekeeper rejects the development artifact, and publication has not been authorised. The production formula deliberately has no invented URL/hash.

## Ross's account actions

1. Enrol in Apple's Developer Program if needed. Create/install a **Developer ID Application** certificate and its corresponding private key in this Mac's keychain. Confirm `security find-identity -p codesigning -v` lists it.
2. Store a valid notarisation credential in the keychain by running `xcrun notarytool store-credentials RIGHTCLICK_NOTARY` interactively. Supply your Apple ID, team ID and app-specific password there; do not put secrets in chat, Git, or scripts.
3. Explicitly authorise publication under `ross-buckley/rightclick` and `ross-buckley/homebrew-tap`. Sign into GitHub locally with rights to create/push these repositories. Nothing here grants that publication approval.

## Build → sign → notarise → validate → archive

The staged `dist/RIGHTCLICK.app` is the tested candidate. If source changes, preserve/move the old bundle before `scripts/build-release.sh`; that script refuses to overwrite a potentially signed artifact. Do not rebuild after signing.

```bash
swift test
# Run this only if a fresh bundle is needed:
scripts/build-release.sh
NOTARY_KEYCHAIN_PROFILE=RIGHTCLICK_NOTARY scripts/sign-release.sh
scripts/validate-release.sh dist/RIGHTCLICK.app
scripts/make-release-archive.sh
shasum -a 256 dist/RIGHTCLICK.app/Contents/MacOS/rightclick
shasum -a 256 dist/rightclick-0.1.0-arm64.tar.gz
```

`sign-release.sh` requires Developer ID and a keychain profile before mutation; signs with hardened runtime/timestamp; verifies; submits a ZIP; requires notary status `Accepted`; staples the app bundle; and checks staple validity and Gatekeeper. It never falls back to ad-hoc signing. The public archive is created **after** those checks from that exact bundle.

Extract the archive into a new directory and run `scripts/validate-release.sh <extracted>/RIGHTCLICK.app` again before publication. This is mandatory: packaging must preserve the notarised payload and ticket. Save the notarisation receipt, binary/archive hashes and validation output under `dist/notary/` privately; publish only safe release evidence.

The archive has sorted paths, fixed ownership/modes/time and a gzip timestamp of zero. Unsigned builds were byte-identical across two independent pinned workspaces on this toolchain/SDK. Apple signing timestamps change bytes, so the final signed binary/archive hashes must be recorded anew. Different compiler/SDK reproducibility is not claimed.

## Publish only after explicit authorisation

From the final committed checkout, assuming these repository names are available and no origin already exists:

```bash
RELEASE_COMMIT=$(git rev-parse HEAD)
gh repo create ross-buckley/rightclick --public --source=. --remote=origin \
  --description "Install an app. Your AI learns what it can do."
git push -u origin HEAD:main
gh repo edit ross-buckley/rightclick --default-branch main
git tag -a v0.1.0 -m "RIGHTCLICK 0.1.0" "$RELEASE_COMMIT"
git push origin v0.1.0
gh release create v0.1.0 \
  dist/rightclick-0.1.0-arm64.tar.gz \
  --title "RIGHTCLICK 0.1.0" --notes-file docs/RELEASE_NOTES_v0.1.0.md
```

Attach SHA256SUMS containing the **signed** binary and archive hashes as an additional release asset. Do not upload development archives. Verify the downloaded public archive again.

```bash
scripts/fill-homebrew-formula.sh \
  https://github.com/ross-buckley/rightclick/releases/download/v0.1.0/rightclick-0.1.0-arm64.tar.gz
```

That script validates the local bundle, downloads the exact allowed HTTPS asset, compares bytes, validates the extracted bundle, and fills both formula copies with the archive SHA256. This avoids advertising an unverified asset.

The prepared public tap structure is `packaging/tap/` (README, Apache licence, Formula). Copy it to a new tap repository, commit the verified formula, then publish with the same explicit approval:

```bash
git init -b main dist/homebrew-tap
cp -R packaging/tap/. dist/homebrew-tap/
git -C dist/homebrew-tap add README.md LICENSE Formula/rightclick.rb
git -C dist/homebrew-tap commit -m "Add RIGHTCLICK 0.1.0"
gh repo create ross-buckley/homebrew-tap --public --source=dist/homebrew-tap --remote=origin
git -C dist/homebrew-tap push -u origin main
```

Commit the filled formula in the source repository as a packaging follow-up. Do not replace an existing release asset silently.

## Public clean-install gate

On a separate Apple Silicon Mac that did not build RIGHTCLICK:

```bash
brew install ross-buckley/tap/rightclick
rightclick version
rightclick doctor
rightclick actions "RightClick acceptance"
rightclick providers
rightclick setup
brew test ross-buckley/tap/rightclick
```

In Cursor, ask the connected RIGHTCLICK tools to discover actions for `RightClick`, execute Convert Text to Full Width, and retrieve its execution status. Require exact `ＲｉｇｈｔＣｌｉｃｋ`. With ordinary BBEdit installed, invoke New BBEdit Document with Selection once and independently inspect the exact text. Verify authenticated HTTP initialize/tools/discovery/status and 401 without authentication; no public tunnel is required to test that transport. Record actual client, OS, hash and observations.

```bash
brew uninstall rightclick
```

Uninstall must remove the keg and command symlink. User Cursor configuration, token and logs are retained; disconnect/remove only RIGHTCLICK's entries/data when desired. Local same-Mac rehearsal does not count as this fresh public clean-install gate. Announce launch only after it passes.
