# RIGHTCLICK Homebrew tap

## Install an app. Your AI learns what it can do.

```bash
brew install rossbuckley1990-hash/tap/rightclick
rightclick setup
```

Apple Silicon, macOS 14+. Source builds need Swift 6.2+ from free Apple Command Line Tools. Update Command Line Tools through Software Update if needed. A matching bottle is used automatically when available. No paid Apple Developer account is required.

The formula pins the immutable v0.1.0 source asset by SHA256, resolves only the locked dependency revisions, and builds inside Homebrew's sandbox. Its test verifies version and exact text classification. It does not rely on a development checkout or existing build directory.

Bottles use the standard `brew tap-new` test-bot and reviewed `brew pr-pull` workflows, restricted to Apple Silicon macOS. Before publishing bottles, require a green formula pull request and its reviewed head SHA. Source installation remains supported when no bottle matches.

`brew uninstall rightclick` removes the package. Cursor configuration and user logs/token remain; remove only RIGHTCLICK's entries/data if desired. See the [main repository](https://github.com/rossbuckley1990-hash/rightclick) for evidence, limits and security guidance.
