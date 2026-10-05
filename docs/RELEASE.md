# Release procedure — 0.1.0

Publication is complete under `rossbuckley1990-hash`: [source/release](https://github.com/rossbuckley1990-hash/rightclick/releases/tag/v0.1.0), [tap](https://github.com/rossbuckley1990-hash/homebrew-tap), and [Apple Silicon bottle](https://github.com/rossbuckley1990-hash/homebrew-tap/releases/tag/rightclick-0.1.0). Public source build, fresh bottle install and installed-product acceptance passed. See the [final report](V0.1_COMPLETION_REPORT.md). The commands below preserve the release procedure; do not recreate or replace the existing v0.1.0 tag/assets.

The primary v0.1 distribution is a Homebrew CLI/MCP developer package. Free Apple Command Line Tools with Swift 6.2+ compile its pinned dependencies. The runtime targets Apple Silicon/macOS 14+. The engine remains frozen. Paid Apple distribution is [deferred](SIGNING.md), not a release blocker.

## Prepare and validate

```bash
swift test --force-resolved-versions # contributors: free full Xcode supplies XCTest
scripts/build-cli.sh
python3 scripts/package-source.py
python3 scripts/acceptance-mcp.py "$(pwd)/.build/release/rightclick" evidence/release-mcp
python3 scripts/acceptance-setup.py "$(pwd)/.build/release/rightclick"
```

The source package contains build inputs, tests, fixtures and dependency licences. Paths, modes, owner/group, tar timestamps and gzip timestamps are normalized. It contains no `.build`, Git metadata, credentials, private user configuration or execution evidence. `package-source.py` computes its SHA256 and fills both production formula copies with the actual release-asset URL and exact digest. Repeating it with unchanged inputs produces identical bytes.

The generated formula uses Homebrew's fetch phase to resolve the locked dependencies, then builds offline inside Homebrew's sandbox. SwiftPM's nested manifest sandbox is disabled because it cannot nest inside that sandbox; Homebrew confinement remains. A version guard gives a clear error for older compilers. No full Xcode or paid Apple account is required.

Before publication, the identical source asset may be staged in Homebrew's download cache for a clearly labelled local rehearsal. This proves package construction and a fresh source build, not public availability. Actual public download/clean-install acceptance remains mandatory after publication.

## Publication

Ross authorised publication in the chat. GitHub authentication must be valid and have rights under `rossbuckley1990-hash`. Sign in interactively with `gh auth login --hostname github.com --web`; never paste a credential into chat or source.

For a first publication, after the final clean commit, prepare the local tag and publish the source repository. This sequence was completed for v0.1.0; subsequent releases must use a new version:

```bash
gh repo create rossbuckley1990-hash/rightclick --public --source=. --remote=origin \
  --description "Install an app. Your AI learns what it can do."
git push -u origin HEAD:main
git tag -a v0.1.0 -m "RIGHTCLICK 0.1.0"
git push origin v0.1.0
gh release create v0.1.0 \
  dist/rightclick-0.1.0-source.tar.gz dist/SHA256SUMS-source \
  --title "RIGHTCLICK 0.1.0" --notes-file docs/RELEASE_NOTES_v0.1.0.md
```

If a repository or tag already exists, inspect it and preserve it; never force-push or replace an existing release asset silently. Download the exact public asset and compare its SHA256 and bytes with the prepared file before publishing the formula.

Prepare the separate tap from `packaging/tap/`, commit its full contents including dotfiles, then:

```bash
gh repo create rossbuckley1990-hash/homebrew-tap --public --source=dist/homebrew-tap --remote=origin
git -C dist/homebrew-tap push -u origin main
```

The tap repository contains Formula/rightclick.rb, README, Apache-2.0 licence and the standard pinned Homebrew Actions workflows. It does not contain source builds or Ross's personal paths.

## Actual public clean installation

Run from outside the source checkout. Remove only RIGHTCLICK and its tap if already installed:

```bash
cd /tmp
brew uninstall rightclick || true
brew untap rossbuckley1990-hash/tap || true
brew install rossbuckley1990-hash/tap/rightclick
which rightclick
rightclick version
rightclick doctor
rightclick actions "RightClick acceptance"
rightclick providers
rightclick setup
brew test rossbuckley1990-hash/tap/rightclick
```

Require the executable to resolve into Homebrew's Cellar, with no source-checkout dependency. Save its actual SHA256. Enable RIGHTCLICK in Cursor's MCP settings if required. In a new chat ask it to inspect `RightClick`, discover actions, invoke Convert Text to Full Width once, then retrieve that execution's status. Require exact `ＲｉｇｈｔＣｌｉｃｋ`. Check the actual running MCP process path/hash; a retained older server does not prove the installed candidate.

Use `scripts/acceptance-mcp.py /opt/homebrew/bin/rightclick <output-dir>` to verify stdio and authenticated loopback HTTP: initialize, all six tools, exact inspection, discovery, confirmation, exact full-width execution/status, 401 without valid credentials, loopback binding and malformed request rejection. No tunnel is needed.

With ordinary BBEdit installed independently, invoke New BBEdit Document with Selection once and independently inspect its new document for the exact fixture. Preserve the historical 36→41 acquisition proof. Do not repeat the closed Yojam experiment or present it as semantic success.

This sequence passed on the proof Mac with the published bottle and, independently, the public source asset. A second supported Mac is valuable independent portability evidence; do not describe a same-Mac test as a fresh-machine result.

## Published bottle and future bottle procedure

The v0.1.0 Apple Silicon Tahoe bottle was built, tested, attested and published through these standard workflows, then downloaded and accepted through the exact public Homebrew install. Source fallback also passed. The tap's `tests.yml` builds bottles for formula pull requests on Apple Silicon macOS. After a green reviewed PR, run the `brew pr-pull` workflow with its PR number and reviewed head SHA. It publishes the standard bottle assets and commits the bottle checksums. Do not publish unreviewed workflow results or hand-invent a bottle checksum. A Linux job that manages bottle publication is infrastructure, not Linux product support.

`packaging/homebrew/bottle.json` preserves the actual published bottle DSL and its source SHA256. Source packaging refuses to attach that bottle to changed source; prepare a new version instead. Both formula copies match the public tap.

Local bottle validation uses `brew install --build-bottle rossbuckley1990-hash/tap/rightclick`, `brew bottle --json rossbuckley1990-hash/tap/rightclick`, then uninstall/pour the resulting bottle and repeat acceptance. A local bottle is not evidence that GitHub Actions has executed.

## Uninstall

```bash
brew uninstall rightclick
```

Require the keg and command symlink to disappear. Cursor configuration, logs and credentials are retained. Remove only the rightclick entry from ~/.cursor/mcp.json when disconnecting, preserving other servers. Delete RIGHTCLICK support data only deliberately.
