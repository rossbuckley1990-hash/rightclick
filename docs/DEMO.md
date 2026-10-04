# Demo

Sixty seconds. One ordinary app. No RIGHTCLICK code changes.

1. Query plain text.

```bash
rightclick actions "RightClick third party capability test"
```

2. The development Mac returned 36 capabilities. None of them were third-party.
3. Install ordinary BBEdit 16.0.3.
4. Do not edit RIGHTCLICK. Run `rightclick refresh` if macOS has not registered the new Services yet.
5. Run the same query again.
6. The same Mac returned 41 capabilities.
7. Five of them are new, and they come from BBEdit:

- New BBEdit Document with Selection
- New Note in BBEdit
- Open File in BBEdit
- Search Here in BBEdit
- Append Selection to BBEdit Scratchpad

8. Invoke the discovered id for New BBEdit Document with Selection. On that Mac it was:

```bash
rightclick run --yes service:com.barebones.bbedit:openSelectionService "RIGHTCLICK generic service final proof 73194"
```

9. BBEdit's new document contains that exact text.

```text
BBEdit-specific RIGHTCLICK code:
NONE
```

Details: `docs/BBEDIT-PROOF.md`.
