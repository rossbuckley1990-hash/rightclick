import Foundation

/// Attests the owned block profile emitted by RIGHTCLICK, not arbitrary YAML.
/// A command-looking line inside a scalar, another document or another binding
/// must never stand in for the command the tunnel client will actually launch.
enum RightClickChatGPTBridgeProfile {
    private struct Line {
        let indent: Int
        let sequenceEntry: Bool
        let key: String
        let value: String?
    }

    static func command(in text: String) -> String? {
        guard text.utf8.count <= 65_536 else { return nil }
        let physicalLines = text.components(separatedBy: "\n")
        guard physicalLines.count <= 4_096 else { return nil }
        var lines: [Line] = []
        for physical in physicalLines {
            let line = physical.hasSuffix("\r") ? String(physical.dropLast()) : physical
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let parsed = parse(line) else { return nil }
            lines.append(parsed)
        }

        // These are the sections emitted by profileYAML. In particular, a
        // second document, alias, flow mapping or extra transport cannot be
        // accepted merely because one physical line contains a trusted command.
        let sections: Set<String> = [
            "config_version", "control_plane", "health", "admin_ui", "log", "mcp"
        ]
        var rootKeys = Set<String>()
        for line in lines where line.indent == 0 {
            guard !line.sequenceEntry, sections.contains(line.key),
                  rootKeys.insert(line.key).inserted else { return nil }
            if line.key == "config_version" {
                guard line.value == "1" || line.value == "2" else { return nil }
            } else {
                guard line.value == nil else { return nil }
            }
        }
        guard rootKeys.contains("config_version"),
              let mcp = lines.firstIndex(where: { $0.indent == 0 && $0.key == "mcp" })
        else { return nil }
        // Non-MCP sections in the owned profile contain ordinary block fields,
        // never a sequence or a rootless/multiline YAML expression.
        guard lines.first?.indent == 0 else { return nil }
        var inMCP = false
        for line in lines {
            if line.indent == 0 { inMCP = line.key == "mcp" }
            if !inMCP && line.sequenceEntry { return nil }
        }
        let end = lines[(mcp + 1)...].firstIndex(where: { $0.indent == 0 }) ?? lines.endIndex
        let binding = Array(lines[(mcp + 1)..<end])
        guard (2...3).contains(binding.count),
              binding[0].key == "commands", binding[0].value == nil,
              !binding[0].sequenceEntry, binding[0].indent > 0,
              binding[1].sequenceEntry, binding[1].indent > binding[0].indent
        else { return nil }
        var values: [String: String] = [:]
        for (index, line) in binding.dropFirst().enumerated() {
            guard (line.key == "command" || line.key == "channel"),
                  let value = line.value, values[line.key] == nil,
                  (index == 0 || (!line.sequenceEntry && line.indent == binding[1].indent + 2))
            else { return nil }
            values[line.key] = value
        }
        guard values["channel"] == nil || values["channel"] == "main" else { return nil }
        return values["command"]
    }

    private static func parse(_ line: String) -> Line? {
        let expression = #"^( *)(- )?([a-z_][a-z0-9_]*):[ ]*(.*)$"#
        guard let match = line.range(of: expression, options: .regularExpression) else { return nil }
        let matched = String(line[match])
        guard matched == line, !matched.contains("\t") else { return nil }
        let indent = matched.prefix(while: { $0 == " " }).count
        var body = String(matched.dropFirst(indent))
        let sequence = body.hasPrefix("- ")
        if sequence { body = String(body.dropFirst(2)) }
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let key = String(body[..<colon])
        let tail = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if tail.isEmpty || tail.hasPrefix("#") {
            return Line(indent: indent, sequenceEntry: sequence, key: key, value: nil)
        }
        guard let value = scalar(tail) else { return nil }
        return Line(indent: indent, sequenceEntry: sequence, key: key, value: value)
    }

    private static func scalar(_ text: String) -> String? {
        if text.hasPrefix("\"") {
            let pattern = #"^("(?:[^"\\]|\\.)*")[ ]*(?:#.*)?$"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text),
                  let value = try? JSONSerialization.jsonObject(
                    with: Data(text[range].utf8), options: [.fragmentsAllowed]) as? String
            else { return nil }
            return value
        }
        if text.hasPrefix("'") {
            let pattern = #"^('(?:[^']|'')*')[ ]*(?:#.*)?$"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[range].dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        let value = text.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces)
        guard value.range(of: #"^[A-Za-z0-9_./:-]+(?: [A-Za-z0-9_./:-]+)*$"#,
                          options: .regularExpression) != nil else { return nil }
        return value
    }
}
