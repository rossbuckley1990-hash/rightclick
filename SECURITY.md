# Security

RIGHTCLICK lists capabilities it discovers on the Mac. Discovery is not approval.

External-share, destructive, financial, and unclassified actions require confirmation. RIGHTCLICK returns that requirement instead of running the action. A friendly title is not treated as proof that an action is safe.

`NSPerformService` returning true means the service was accepted. It does not, by itself, prove the semantic outcome.

Remote MCP requires a bearer token. `rightclick serve` prints the token once and does not put it in the process arguments. Do not expose RIGHTCLICK on a network without that authentication. Do not commit the token.

`--tunnel` can start a temporary Cloudflare quick tunnel when `cloudflared` is installed. Those hostnames are for development and testing. They are not a supported public deployment, and they should not be published.
