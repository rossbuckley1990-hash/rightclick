# Demo

The canonical [demo script](DEMO_SCRIPT.md) uses ordinary BBEdit installation and exact text transfer through the generic executor. The historical baseline is 36 → 41 capabilities, with five new BBEdit actions and zero provider-specific acquisition changes. The linked proof records its original independent semantic regression; it is not a fresh acceptance run.

Use actual counts for a fresh recording. Label historical evidence when replaying it. Yojam's acquisition can be described accurately; its semantic result must not be shown as proven.

Public install path:

```bash
brew install rossbuckley1990-hash/tap/rightclick
rightclick setup --all --dry-run --json
rightclick setup --all --yes
```

Use the [Homebrew tap](https://github.com/rossbuckley1990-hash/homebrew-tap) and its exact formula pins. A matching bottle is used only when its platform checksum and downloadable asset are published; otherwise the pinned source is built.
