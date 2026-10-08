# Release procedure — v0.2.3

Previously published releases and their tags are immutable. This procedure
prepares a new v0.2.3 from the reconciled portable architecture; it does not
declare the candidate published or the eleven-substrate goal complete.

The public Homebrew package targets Apple Silicon on macOS 14+. Native Linux
x86_64 and arm64 source-runtime evidence is required separately. No Windows
executable, Linux package or network Link deployment is claimed by this release.
Windows failures and incomplete substrate acceptance remain recorded as RED.

## Freeze the composed source

Reconcile PR99's extracted core with PR49's current provider, authority, process,
verification, profile and regression fixes. Preserve the original execution
engine and seven-operation Core Profile. Review the exact source, tests,
assertions, intentional method mappings and Git ancestry before importing it
into the publishing branch. A merge that preserves ancestry does not establish
content preservation by itself.

Record the exact head and physical Git bytes/modes before and after execution.
Require the complete native Mac suite, native Linux x86_64/arm64 suites and
relevant production acceptance scripts against this composition. Record skips
and failed attempts without treating historical or selected tests as a fresh
full-suite result. Independent audits must bind fixture effects, verification,
receipts and provider lifecycle to the tested source and actual executable.

Keep the published-bottle alignment gate distinct: it remains RED until the
accepted source and matching new bottle reach the public distribution.

## Close the source package

The version is defined by `RightClickVersion.current` in
`Sources/RightClickProviders/ProductSurface.swift`.

Run in the reviewed checkout:

```sh
python3 scripts/package-source.py
python3 scripts/detect-bottle-alignment.py --compare --bottle dist/rightclick-0.2.3-source.tar.gz --json
```

The outputs are `dist/rightclick-0.2.3-source.tar.gz`,
`dist/SHA256SUMS-source`, the two identical generated Homebrew formulas and the
source-kind manifest. Repeat packaging and require identical archive bytes.
Independently compare every archive payload, mode and canonical metadata with
the clean frozen Git inputs. The descriptor examples required by the shipped
acceptance script are part of this closure. Private evidence, local credentials,
build caches and untracked files must be absent.

Both formulas must point to the new v0.2.3 source asset, pin its exact SHA256,
retain the existing OpenAI tunnel-client compatibility resource and contain no
stale bottle block. A source-kind inventory does not prove runtime acceptance.

Freeze the package and exact packaged Git inputs. Repin the independent release
reader without changing its fail-closed verification predicates, and repeat all
21 positive and rejection controls. Keep all native and package scopes explicit.

## Tag, audit a draft, then publish

Verify that `v0.2.3` does not already exist. Create an annotated tag at the
reviewed source head and push it without moving any existing tag.

Create a draft containing exactly the accepted source archive and checksum:

```sh
gh release create v0.2.3 dist/rightclick-0.2.3-source.tar.gz dist/SHA256SUMS-source --draft --verify-tag --title "RIGHTCLICK 0.2.3" --notes-file docs/RELEASE_NOTES_v0.2.3.md
```

Before publishing, independently verify the actual tag closure, immutable-release
setting, release ID, complete asset inventory, digest/size and asset-by-ID bytes
against the frozen package. The release notes must state the demonstrated
platform/provider scope and remaining RED rows.

Publish that audited draft. Independently re-download both assets from their
public URLs, verify identical bytes and re-read the tag/release inventory. Require
the public release to be immutable. Do not replace an asset or move a tag.

## Produce and publish the Homebrew bottle

Update the tap source formula only after the immutable public source audit.
Preserve both repositories' formula agreement and tunnel compatibility pin.
The trusted tap main workflow must build and test the accepted source, produce
the bottle and sign its provenance. Its run, attempt, source assets, formula,
bottle digest and attestation must be independently closed before finalization.

Use the tap's reviewed bottle staging/finalizer procedure. Publish its exact
validated formula and bottle through ordinary Git ancestry; do not substitute
an old bottle, an unreviewed local binary or an unsigned handoff.

## Verify a fresh installed product

From outside the development checkout, install the accepted public bottle and
require the poured executable to match its independently accepted digest.
Require `rightclick version`, `rightclick doctor`, Homebrew's formula test,
setup dry-run and installed seven-operation execution/verification checks.
Repeat the profile-redirection controls against these new installed bytes.

For an already paired ChatGPT bridge, preserve the profile, LaunchAgent and
tunnel identity. Observe the product's existing upgrade reconciliation first.
If a verified stale service needs refresh, use only its exact owned launchd
service after accepted installation. Attest the new connected runtime's PID,
version and executable path/hash, and independently verify process ownership
and mapped executable identity. A changed version string alone is insufficient.

Finally require:

```sh
python3 scripts/detect-bottle-alignment.py --compare --json
```

to exit zero against the actual published bottle. Close the distribution gates
and merge the passing, reviewed source PR only after public/install evidence
matches the release. Developer ID signing, notarization and standalone Apple app
distribution remain separate work.
