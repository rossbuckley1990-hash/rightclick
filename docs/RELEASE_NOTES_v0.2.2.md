# RIGHTCLICK 0.2.2

RIGHTCLICK's north star is simple:

Install software. Your AI learns what it can do.

v0.2.2 permanently aligns the substrates that landed on `main` after the immutable v0.2.1 bottle onto the Homebrew distribution path, and adds fail-closed bottle alignment detection for agents and CI.

## Substrate alignment

The published bottle now includes:

- Bonjour and configured OpenAPI capability reflection
- Bonjour GraphQL capability reflection
- Bonjour gRPC capability reflection
- Universal capability artifact resolution (OpenAPI, GraphQL, and gRPC resolvers)
- ARD registry acquisition
- MCP federation peer reflection
- OAuth/OIDC authority support

These remain ordinary reflector/source compositions behind the same generic MCP surface. No provider-specific model-facing tools were added.

## Automatic detect-and-align

`scripts/detect-bottle-alignment.py` inventories durable substrate/reflector kinds in the checkout and compares them to the published Homebrew bottle.

When `main` exposes kinds absent from the bottle, the script and CI fail closed and point at the release alignment path in `docs/BOTTLE-ALIGNMENT.md` and `docs/RELEASE.md`.

The immutable source archive embeds `packaging/substrate-kinds.json` so published bottles carry an explicit kind snapshot.

## Acceptance

The integrated release code passed:

- 411 tests
- 26 skipped
- 0 failures
- local package self-alignment via `detect-bottle-alignment.py --bottle dist/rightclick-0.2.2-source.tar.gz`
- deterministic source archive SHA `a3953eb8f1be2f9123d694b90202244c94ee21971171972f8ce1d3bacf807ca5`

## Immutable release discipline

v0.2.1 remains immutable. This release is a new tag and new source asset. Existing release tags are never force-moved.

## Install

    brew install rossbuckley1990-hash/tap/rightclick
    rightclick version

Upgrade:

    brew update
    brew upgrade rightclick
    rightclick version

For a local supported MCP client:

    rightclick setup

For the persistent ChatGPT bridge:

    rightclick setup chatgpt --dry-run --json
    rightclick setup chatgpt --yes
