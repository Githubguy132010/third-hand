import Foundation

enum TextExtractor {
    /// Conservative convenience for a single editable field without a generator key.
    /// Complex/multi-field requests must go through the field-aware text generator.
    static func extract(from goal: String) -> String? {
        let patterns = [#"^(?:type|enter)\s+"([^"]*)"\s*$"#,
                        #"^search for\s+"([^"]+)"\s*$"#,
                        #"^search for\s+([^"\n]+)$"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: goal, range: NSRange(goal.startIndex..., in: goal)),
                  let range = Range(match.range(at: 1), in: goal) else { continue }
            let value = String(goal[range])
            if value.range(of: #"\b(and|then|into)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
            return value
        }
        return nil
    }
}
