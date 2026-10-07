/** Optional discovery metadata for one existing standard declaration.
 * No RIGHTCLICK dependency, network request, credentials or execution.
 */
export type DiscoveryKind = "openapi" | "graphql" | "mcp";

export function discoveryJSON(kind: DiscoveryKind, path: string): string {
  if (!["openapi", "graphql", "mcp"].includes(kind)) {
    throw new Error("Supported manifest links are openapi, graphql and mcp.");
  }
  const match = typeof path === "string"
    ? /^\/(?:[A-Za-z0-9._~-]+(?:\/[A-Za-z0-9._~-]+)*)?$/.exec(path)
    : null;
  if (!match || match[0] !== path || path.length > 4096 ||
      path.split("/").some(segment => segment === "." || segment === "..")) {
    throw new Error("Use a bounded root-relative ASCII declaration path without authority, escapes, traversal, query or fragment.");
  }
  return JSON.stringify({ schemaVersion: 1, links: [{ kind, url: path }] });
}
