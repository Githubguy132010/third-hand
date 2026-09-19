import Foundation

enum TextExtractor {
    static func extract(from goal: String) -> String? {
        // Quoted text: "hello", "hello", \u{201C}hello\u{201D}
        let quotePattern = #"[""\u{201C}](.+?)[""\u{201D}]"#
        if let regex = try? NSRegularExpression(pattern: quotePattern),
           let match = regex.firstMatch(in: goal, range: NSRange(goal.startIndex..., in: goal)),
           let range = Range(match.range(at: 1), in: goal) {
            return String(goal[range])
        }

        let keywordPattern = #"(?:search\s+for|search|type|enter|write|input|set\s+to|change\s+to)\s+(.+?)(?:\s+(?:in|into|on|at)\s+(?:the\s+)?\S+.*)?$"#
        if let regex = try? NSRegularExpression(pattern: keywordPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: goal, range: NSRange(goal.startIndex..., in: goal)),
           let range = Range(match.range(at: 1), in: goal) {
            let text = String(goal[range]).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }

        return nil
    }
}
