# Canonical launch demonstration

Start with “RIGHTCLICK: Install an app. Your AI learns what it can do.” The historical proof is real, but capability totals depend on the Mac. For a fresh live demo, start on a Mac without BBEdit, capture actual before/after results, and do not change RIGHTCLICK between queries. Do not uninstall a user's existing BBEdit just to stage this demo.

1. Query `rightclick actions "RightClick third party capability test"`. The preserved proof baseline was 36 capabilities and 0 third-party.
2. Install ordinary BBEdit from Bare Bones. RIGHTCLICK acquisition code changes: 0.
3. Run `rightclick refresh`, then repeat the exact query. The preserved after state was 41 capabilities, including five new BBEdit capabilities.
4. Show New BBEdit Document with Selection, New Note, Open File, Search Here, and Append Selection to Scratchpad. Explain that these came from the app's existing Services contract.
5. Inspect and confirm New BBEdit Document with Selection, then invoke once:

```bash
rightclick run --yes service:com.barebones.bbedit:openSelectionService "RIGHTCLICK demo fixture"
```

6. Show the new BBEdit document containing exactly `RIGHTCLICK demo fixture`. Inspect all new windows before judging the result; the previous document may remain selected.
7. Say: “The app already exposed this capability. RIGHTCLICK reflected it; no bespoke BBEdit AI integration was added.” MCP is the transport between the AI and this capability layer.

For a replay, clearly label the preserved before/after acquisition records as historical. Current regression verified `RIGHTCLICK v0.1 BBEdit regression 20261005`, exactly 42 characters, in a new BBEdit window. See [BBEDIT-PROOF.md](BBEDIT-PROOF.md).

Do not demonstrate Yojam semantic execution as passing. Its new capability was acquired automatically, but accepted invocation did not establish the expected external result. Do not announce public installation until signing, notarisation, tap publication, and clean-machine acceptance pass.
