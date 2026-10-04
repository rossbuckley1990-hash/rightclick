# Demo script

About one minute. Do not edit RIGHTCLICK between the two queries.

1. Say: "This is a plain text query, before BBEdit is installed."
2. Run `rightclick actions "RightClick third party capability test"`.
3. Read the summary: 36 capabilities, no third-party row.
4. Install ordinary BBEdit 16.0.3 from Bare Bones. Do not change RIGHTCLICK.
5. Run `rightclick refresh`, then the same `rightclick actions` command.
6. Read the summary: 41 capabilities. Point at the five new rows:
   - New BBEdit Document with Selection
   - New Note in BBEdit
   - Open File in BBEdit
   - Search Here in BBEdit
   - Append Selection to BBEdit Scratchpad
7. Say: "BBEdit is not an MCP server, and RIGHTCLICK has no BBEdit-specific code."
8. Run:

```bash
rightclick run --yes service:com.barebones.bbedit:openSelectionService "RIGHTCLICK generic service final proof 73194"
```

9. Show the BBEdit document. The text is exactly `RIGHTCLICK generic service final proof 73194`.
