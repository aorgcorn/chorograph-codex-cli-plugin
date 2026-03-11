// ShellCommandParser.swift
// Utilities for parsing shell command strings into file-activity events.
// Used by CodexCLIProvider to detect file reads/writes from subprocess commands.

import Foundation

enum ShellCommandParser {

    /// Strip the `bash -lc '…'` / `bash -c '…'` wrapper that Codex adds.
    static func strippedBashWrapper(_ raw: String) -> String {
        let patterns = [
            #"^bash\s+-lc\s+'(.+)'$"#,
            #"^bash\s+-c\s+'(.+)'$"#,
            #"^bash\s+-lc\s+"(.+)"$"#,
            #"^bash\s+-c\s+"(.+)"$"#,
        ]
        for pattern in patterns {
            if let inner = raw.firstCapture(pattern: pattern) {
                return inner
            }
        }
        return raw
    }

    /// Match commands of the form `<tool> [flags] <file>` where the file is the
    /// last non-flag token. Returns the file path or nil.
    static func matchSimpleReadCommand(_ cmd: String, tools: [String]) -> String? {
        let tokens = cmd.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let tool = tokens.first, tools.contains(tool) else { return nil }
        let fileTokens = tokens.dropFirst().filter {
            !$0.hasPrefix("-") && !$0.hasPrefix(">") && !$0.hasPrefix("|")
        }
        return fileTokens.last
    }

    /// Return the last whitespace-separated token that doesn't start with `-`.
    static func lastNonFlagArg(_ cmd: String) -> String? {
        let tokens = cmd.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        return tokens.filter { !$0.hasPrefix("-") }.dropFirst().last
    }
}

// MARK: - String regex helper

private extension String {
    func firstCapture(pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(self.startIndex..., in: self)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }
}
