// Emit optional metadata for one existing standard; no RIGHTCLICK dependency.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
)

var declarationPath = regexp.MustCompile(`^/(?:[A-Za-z0-9._~-]+(?:/[A-Za-z0-9._~-]+)*)?$`)

// DiscoveryJSON creates only the closed, single-link schemaVersion 1 envelope.
func DiscoveryJSON(kind, path string) ([]byte, error) {
	if kind != "openapi" && kind != "graphql" && kind != "mcp" {
		return nil, errors.New("supported manifest links are openapi, graphql and mcp")
	}
	if len(path) > 4096 || !declarationPath.MatchString(path) {
		return nil, errors.New("use a bounded root-relative ASCII declaration path without authority, escapes, traversal, query or fragment")
	}
	for _, segment := range strings.Split(path, "/") {
		if segment == "." || segment == ".." {
			return nil, errors.New("declaration paths cannot traverse directories")
		}
	}
	type link struct {
		Kind string `json:"kind"`
		URL  string `json:"url"`
	}
	document := struct {
		SchemaVersion int    `json:"schemaVersion"`
		Links         []link `json:"links"`
	}{SchemaVersion: 1, Links: []link{{Kind: kind, URL: path}}}
	return json.Marshal(document)
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: manifest <openapi|graphql|mcp> </declaration-path>")
		os.Exit(2)
	}
	document, err := DiscoveryJSON(os.Args[1], os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	fmt.Println(string(document))
}
