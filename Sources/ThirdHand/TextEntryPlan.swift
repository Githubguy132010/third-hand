import Foundation

struct TextEntryPlan {
    let kind: String
    let text: String
    var directoryMarker: String? = nil

    static func isTerminal(_ bundle: String?) -> Bool {
        ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty"].contains(bundle ?? "")
    }

    /// Contiguous phrases from the current request only: never recycle screen/history text.
    static func candidates(_ goal: String) -> [String] {
        var values: [String] = []
        func add(_ value: String) {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text.utf8.count <= 1000, !values.contains(text) { values.append(text) }
        }
        if let literal = TextExtractor.extract(from: goal) { add(literal) }
        if let regex = try? NSRegularExpression(pattern: #"["“]([^"”]+)["”]|'([^']+)'"#) {
            for match in regex.matches(in: goal, range: NSRange(goal.startIndex..., in: goal)) {
                for group in 1..<match.numberOfRanges {
                    if let range = Range(match.range(at: group), in: goal) { add(String(goal[range])) }
                }
            }
        }
        let words = goal.split(whereSeparator: \.isWhitespace).map(String.init)
        for length in 1...max(1, min(12, words.count)) where length <= words.count {
            for start in 0...(words.count - length) {
                add(words[start..<(start + length)].joined(separator: " "))
                if values.count >= 100 { return values }
            }
        }
        return values
    }

    static func build(kind: String, content: String, terminal: Bool) throws -> TextEntryPlan {
        guard !content.contains("\n"), !content.contains("\r"), !content.contains("\0") else {
            throw ControllerError.invalid("Multi-line entry is not supported by structured text selection.")
        }
        switch kind {
        case "search" where !terminal, "literal":
            return TextEntryPlan(kind: kind, text: content)
        case "change_directory" where terminal:
            let marker = "THIRDHAND_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let path: String
            if content == "~" { path = "\"$HOME\"" }
            else if content.hasPrefix("~/") { path = "\"$HOME\"/" + quote(String(content.dropFirst(2))) }
            else { path = quote(content) }
            // The marker appears as its own output line only if cd succeeds.
            return TextEntryPlan(kind: kind, text: "cd -- \(path) && printf '\\n\(marker):%s\\n' \"$PWD\"", directoryMarker: marker)
        default:
            throw ControllerError.invalid("This request needs writing or command generation that Jev cannot provide. Specify the exact text or a directory to open.")
        }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func directoryResult(in elements: [AccessibilityElement]) -> String? {
        guard let directoryMarker else { return nil }
        let prefix = directoryMarker + ":"
        for element in elements where element.source != "ocr" {
            for line in (element.value ?? "").components(separatedBy: .newlines) {
                if line.hasPrefix(prefix) {
                    let path = String(line.dropFirst(prefix.count))
                    if path.hasPrefix("/") { return path }
                }
            }
        }
        return nil
    }
}
