# RIGHTCLICK Homebrew tap

Prepared locally; unpublished. The formula intentionally refuses installation until the signed, notarised release asset exists and its URL/hash are verified.

After `scripts/fill-homebrew-formula.sh` passes in the RIGHTCLICK repository, copy this directory to the root of `ross-buckley/homebrew-tap` and publish only with explicit authorisation.

```bash
brew install ross-buckley/tap/rightclick
rightclick setup
```

Apple Silicon/macOS 14+. `brew uninstall rightclick` removes package files. Cursor configuration and user logs/token are retained; remove only RIGHTCLICK's entries/data if desired. See the main repository's release and security documentation.
