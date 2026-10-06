# MOAT-004 G7 — actual ChatGPT live GitHub gate

G7 closes the live surface of MOAT-004.

The exact frozen RIGHTCLICK candidate was exposed through the existing
ChatGPT tunnel. A generic `_rightclick._tcp.` OpenAPI advertisement
pointed at GitHub's pinned official REST contract and the real
`https://api.github.com` execution origin.

Through the actual ChatGPT RIGHTCLICK MCP connection:

1. `context_runtime` matched the exact candidate.
2. `context_actions` discovered `Get the authenticated user`.
3. `context_explain` reported:
   - `operationId=users/get-authenticated`
   - `GET /user`
   - `http_bearer`
   - exact origin `https://api.github.com`
   - `json_syntax_only`
4. `context_run` performed `GET https://api.github.com/user`.
5. GitHub returned HTTP 200.
6. Returned login/id matched the independent G6 `gh api user` control.

RIGHTCLICK correctly left `outcomeVerified=false`; provider HTTP
acceptance is not itself semantic verification. The independent G6/G7
identity comparison closes the experiment-level proof.

The credential was stored outside MCP in the existing origin-bound
Keychain authority store and was not printed or supplied as a model/tool
argument.

No GitHub-specific MCP tool and no GitHub-specific production branch
were added.
