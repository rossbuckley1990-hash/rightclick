# Release

v0.1.0 is arm64. Intel is not part of this artefact.

## Current gates

| Gate | Status |
| --- | --- |
| Developer ID Application certificate | Not installed. `0 valid identities found`. |
| Notarisation credentials | Not configured. |
| Signed binary | No. The release binary is linker ad-hoc signed. |
| Notarised binary | No. |
| Stapled artefact | No. |
| Public release archive | Not uploaded. `scripts/make-release-archive.sh` can build a local tarball. |
| Public Homebrew tap | Not created. |
| Formula URL and sha256 | Deferred until the GitHub Release asset exists. |
| `brew install ross-buckley/tap/rightclick` | Blocked on the tap and the asset. |

## Sequence, after the certificate exists

```bash
scripts/make-release-archive.sh
NOTARY_KEYCHAIN_PROFILE=RIGHTCLICK_NOTARY scripts/sign-release.sh .build/release/rightclick
```

Create the GitHub Release only when ready to publish. Attach `dist/rightclick-0.1.0-arm64.tar.gz`. Then:

```bash
scripts/fill-homebrew-formula.sh \
  https://github.com/ross-buckley/rightclick/releases/download/v0.1.0/rightclick-0.1.0-arm64.tar.gz
```

That command refuses any URL that is not a `ross-buckley/rightclick` release asset. It writes the sha256 of the local archive into `packaging/homebrew/rightclick.rb`.

## Tap

The tap does not exist yet. When publishing:

```bash
brew tap-new ross-buckley/tap
cp packaging/homebrew/rightclick.rb "$(brew --repository)/Library/Taps/ross-buckley/homebrew-tap/Formula/rightclick.rb"
git -C "$(brew --repository)/Library/Taps/ross-buckley/homebrew-tap" add Formula/rightclick.rb
git -C "$(brew --repository)/Library/Taps/ross-buckley/homebrew-tap" commit -m "Add rightclick 0.1.0"
git -C "$(brew --repository)/Library/Taps/ross-buckley/homebrew-tap" push -u origin HEAD
```

Install and remove:

```bash
brew install ross-buckley/tap/rightclick
brew uninstall rightclick
```

v0.1.0 is `depends_on arch: :arm64`. The formula installs the archived `rightclick` binary. It does not build from a checkout.

## Acceptance still required on a clean machine

```text
brew install ross-buckley/tap/rightclick
rightclick version
rightclick doctor
rightclick setup
rightclick actions <fixture>
```

Then Cursor `context_actions` and `context_run`, and an authenticated `rightclick serve` discovery and execution. Those public-install steps are blocked until the tap and the signed asset exist.
