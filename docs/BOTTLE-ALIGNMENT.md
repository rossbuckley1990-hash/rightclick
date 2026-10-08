# Bottle substrate alignment

The Homebrew bottle is the primary installed product. When `main` gains reflector or substrate kinds that the published bottle does not contain, agents must cut the next immutable release rather than leave the tap behind.

## Auto-detect (fail closed)

```bash
python3 scripts/detect-bottle-alignment.py --compare
```

Exit codes:

- `0` — every checkout kind is present in the published bottle
- `1` — checkout has kinds missing from the bottle; alignment required
- `2` — inventory/fetch error

Useful variants:

```bash
# Inventory only
python3 scripts/detect-bottle-alignment.py --json

# Write the packaging snapshot used inside the source asset
python3 scripts/detect-bottle-alignment.py --write-manifest packaging/substrate-kinds.json

# Compare against a local archive or explicit release
python3 scripts/detect-bottle-alignment.py --compare --bottle dist/rightclick-0.2.2-source.tar.gz
python3 scripts/detect-bottle-alignment.py --compare --bottle v0.2.1
```

CI runs `--compare` in a separate macOS check so public substrate drift fails closed. Candidate tests independently require alignment with their local deterministic source archive. The candidate may be tagged only after its complete native/source/provider/package gates pass; its PR remains unmerged until the published asset, reviewed tap, matching bottle, fresh installation and public alignment pass. See [RELEASE.md](RELEASE.md) for this staging order.

## Kind catalogue

Kinds are durable fingerprints over composition roots and source files, including:

- macOS Services / Sharing / Action Extension reflectors
- Bonjour and configured OpenAPI sources
- Bonjour GraphQL and gRPC sources
- Universal configured capability artifacts and OpenAPI/GraphQL/gRPC artifact resolvers
- ARD registry source
- MCP federation peer source
- OAuth/OIDC authority

`scripts/package-source.py` regenerates `packaging/substrate-kinds.json` and embeds it in the immutable source archive.

## Alignment path

When detect fails closed:

1. Confirm `RightClickVersion.current` is the next unpublished patch (never move an existing release tag).
2. Follow [RELEASE.md](RELEASE.md): `swift test`, `scripts/build-cli.sh`, `python3 scripts/package-source.py`.
3. Publish the immutable GitHub Release assets.
4. Re-download the published source archive and require byte/SHA identity with the local asset.
5. Update `rossbuckley1990-hash/homebrew-tap` `Formula/rightclick.rb` to the new URL and SHA.
6. Run `brew update && brew upgrade rightclick` acceptance outside the checkout.
7. Re-run `python3 scripts/detect-bottle-alignment.py --compare` and require exit `0`.

Never force-move an existing release tag such as `v0.2.1`.
