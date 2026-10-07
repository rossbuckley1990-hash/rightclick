#!/usr/bin/env python3
"""One-time, fail-closed repair of PR37. No installed runtime or secrets touched."""
from pathlib import Path
import hashlib, json, shutil, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
SDK = 'a0ae212ebf6eab5f754c3129608bc5557637e605'
MARKER = ROOT / 'evidence/portable-runtime-001/repairs-applied.json'
def command(*args, **kwargs):
    return subprocess.check_output(args, text=True, timeout=180, **kwargs).strip()
def digest(data): return hashlib.sha256(data).hexdigest()
def main():
    assert command('git', 'branch', '--show-current', cwd=ROOT) == 'feature/portable-runtime-001'
    if MARKER.exists():
        print('Repairs already applied; source tests remain authoritative.'); return
    changes = {}
    def read(name): return changes.get(name, (ROOT / name).read_text())
    def edit(name, old, new):
        text = read(name)
        assert text.count(old) == 1, (name, 'source precondition mismatch', old[:65])
        changes[name] = text.replace(old, new)
    package = 'Package.swift'
    edit(package, '.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")', '.package(path: "Vendor/swift-sdk")')
    edit(package, '"MOAT004G1AcquisitionTests.swift", "MOAT004G2SplitOriginTests.swift",', '"MOAT004G1AcquisitionTests.swift",')
    for name, method in [('MOAT004G3ZeroArgumentGETTests','testFrozenGitHubAuthenticatedUserStillDoesNotReflectUntilG4'), ('MOAT004G4JSONSyntaxFallbackTests','testFrozenGitHubUserReflectsForFirstTimeButHasNoExternalAuthorityYet')]:
        name = 'Tests/RightClickCoreTests/' + name + '.swift'
        text = read(name); start = text.index('    func ' + method + '('); end = text.index('\n    }', start) + 6
        changes[name] = text[:start] + '#if os(macOS)\n' + text[start:end] + '\n#endif' + text[end:]
    # Runtime-owned learning hints must neither break repeat calls nor become authority.
    engine = 'Sources/RightClickCore/CapabilityEngine.swift'
    edit(engine, 'encoder.encode(capability) else { return nil }', 'encoder.encode(CapabilityExperience.withoutExperience(capability)) else { return nil }')
    edit(engine, 'encoder.encode(candidate), actual == expected', 'encoder.encode(CapabilityExperience.withoutExperience(candidate)), actual == expected')
    cli = 'Sources/RightClickCLI/ProviderConfigurationCLI.swift'
    edit(cli, 'import Foundation\n', 'import Foundation\n#if os(Windows)\nimport ucrt\n#endif\n')
    server = 'Sources/RightClickMCP/Server.swift'
    edit(server, '#endif\n            return 0\n        }\n        return StdioMCPServer', '#endif\n        }\n        return StdioMCPServer')
    modern = 'Sources/RightClickMCP/ModernMCPStdioTransport.swift'
    text = read(modern)
    changes[modern] = text.replace('RIGHTCLICK discovers and safely invokes capabilities exposed by software installed on this Mac.', 'RIGHTCLICK discovers capabilities from this host and configured services. Discovery, authorization and outcome evidence are separate.')
    listener = 'Sources/RightClickMCP/HTTPListener.swift'
    edit(listener, '    private func handle(_ connection: NWConnection) async {\n        do {', '''    private func handle(_ connection: NWConnection) async {
        let deadline = DispatchWorkItem { [weak connection] in connection?.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: deadline)
        defer { deadline.cancel(); connection.cancel() }
        do {''')
    edit(listener, '        let headerText = String(data: headerData, encoding: .utf8) ?? ""', '''        guard headerData.count <= 16_384,
              let headerText = String(data: headerData, encoding: .utf8) else {
            throw RightClickListenerError("Invalid or excessive headers.")
        }''')
    text = read(listener); start = text.index('        var headers: [String: String] = [:]'); end = text.index('        // Validate framing', start)
    changes[listener] = text[:start] + '''        guard lines.count <= 65 else { throw RightClickListenerError("Too many headers.") }
        var headers: [String: String] = [:]
        let singleton = Set(["content-length", "authorization", "content-type", "host", "transfer-encoding"])
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw RightClickListenerError("Malformed header.") }
            let name = String(line[..<colon])
            guard !name.isEmpty, name.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                "!#$%&'*+-.^_`|~".utf8.contains($0)
            }) else { throw RightClickListenerError("Invalid header name.") }
            let key = name.lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard value.unicodeScalars.allSatisfy({ $0.value == 9 || ($0.value >= 32 && $0.value != 127) }),
                  !singleton.contains(key) || headers[key] == nil else {
                throw RightClickListenerError("Ambiguous or invalid header.")
            }
            headers[key] = headers[key].map { $0 + ", " + value } ?? value
        }
''' + text[end:]
    edit(listener, '''        guard body.count >= length else { throw RightClickListenerError("Incomplete request body.") }
        if body.count > length {
            body = body.prefix(length)
        }''', '        guard body.count == length else { throw RightClickListenerError("Incomplete or excessive request body.") }')
    acceptance = 'scripts/acceptance-portable.py'
    edit(acceptance, 'import http.client\n', 'import http.client\nimport hashlib\n')
    edit(acceptance, "assert config['command'] == str(binary)", "assert os.path.samefile(config['command'], binary)")
    edit(acceptance, "assert len(runtime['executableSHA256']) == 64", "assert runtime['executableSHA256'] == hashlib.sha256(binary.read_bytes()).hexdigest()\n            assert os.path.samefile(runtime['executableRealPath'], binary)")
    edit(acceptance, "b'Content-Length: 1\\r\\nContent-Length: 2\\r\\n']", "b'Content-Length: 1\\r\\nContent-Length: 2\\r\\n',\n                            b'Content-Length: 1\\r\\ncontent-length: 2\\r\\n',\n                            b'Authorization: one\\r\\nauthorization: two\\r\\nContent-Length: 0\\r\\n']")
    # A complete source package must retain its local dependency and licence.
    source = 'scripts/package-source.py'
    edit(source, '"Package.swift", "Package.resolved", "LICENSE", "Sources", "Tests",', '"Package.swift", "Package.resolved", "LICENSE", "Sources", "Tests", "Vendor",')
    docker = 'Dockerfile'
    edit(docker, 'USER rightclick', 'COPY --from=build /src/Vendor/swift-sdk/LICENSE /usr/local/share/rightclick/licenses/MCP-LICENSE\nUSER rightclick')
    vendor = ROOT / 'Vendor/swift-sdk'
    assert not vendor.exists(), 'Unexpected local SDK; do not overwrite it.'
    with tempfile.TemporaryDirectory(prefix='rightclick-sdk-') as temp:
        upstream = Path(temp) / 'sdk'
        command('git','clone','--quiet','--depth=1','--branch','0.12.1','https://github.com/modelcontextprotocol/swift-sdk.git',str(upstream))
        assert command('git','rev-parse','HEAD',cwd=upstream) == SDK
        staged = Path(temp) / 'vendor'; staged.mkdir()
        for folder in ['Sources/MCP','Tests']:
            for p in (upstream / folder).rglob('*'):
                assert not p.is_symlink(), 'Unexpected SDK symlink'
                if p.is_file():
                    target = staged / p.relative_to(upstream); target.parent.mkdir(parents=True,exist_ok=True); target.write_bytes(p.read_bytes())
        (staged / 'LICENSE').write_bytes((upstream / 'LICENSE').read_bytes())
        (staged / 'Package.swift').write_bytes((upstream / 'Package@swift-6.0.swift').read_bytes())
        changed = 'Sources/MCP/Base/Transports/HTTPClientTransport.swift'
        text = (staged / changed).read_text(); assert text.count('#if !os(Linux)') == 2
        (staged / changed).write_text(text.replace('#if !os(Linux)', '#if canImport(EventSource)'))
        rows = {}
        for p in (staged / 'Sources/MCP').rglob('*'):
            if p.is_file():
                name = p.relative_to(staged).as_posix()
                rows[name] = {'upstream':digest((upstream/name).read_bytes()), 'patched':digest(p.read_bytes())}
        assert [p for p,r in rows.items() if r['upstream'] != r['patched']] == [changed]
        (staged / 'UPSTREAM.json').write_text(json.dumps({'repository':'modelcontextprotocol/swift-sdk','revision':SDK,'tag':'0.12.1','files':rows,'manifest_sha256':digest((staged/'Package.swift').read_bytes()),'license_sha256':digest((staged/'LICENSE').read_bytes())},sort_keys=True,indent=2)+'\n')
        (staged / 'README.rightclick.md').write_text('Pinned MCP SDK 0.12.1. Only two EventSource compilation guards differ from upstream. Original tests and licence retained. All hosts share these sources. Original/patched hashes are in UPSTREAM.json. Remove this compatibility snapshot after a verified upstream Windows-capable release; do not develop an independent protocol fork.\n')
        # Only commit source after all transformation and upstream preconditions passed.
        shutil.copytree(staged,vendor)
    for name,text in changes.items(): (ROOT/name).write_text(text)
    MARKER.write_text(json.dumps({'base_head':command('git','rev-parse','HEAD',cwd=ROOT),'sdk':SDK,'scope':'Source repair, not a successful build or release claim.','changed':{p:digest((ROOT/p).read_bytes()) for p in sorted(changes)}},sort_keys=True,indent=2)+'\n')
    print('Applied source repairs; run all platform validation gates before release.')
if __name__ == '__main__': main()
