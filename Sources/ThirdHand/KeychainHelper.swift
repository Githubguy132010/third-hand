import Foundation

enum KeychainHelper {
    private static let filePath = NSHomeDirectory() + "/.thirdhand-api-key"

    static func saveAPIKey(_ key: String) {
        try? key.write(toFile: filePath, atomically: true, encoding: .utf8)
    }

    static func getAPIKey() -> String? {
        guard let key = try? String(contentsOfFile: filePath, encoding: .utf8) else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func delete() {
        try? FileManager.default.removeItem(atPath: filePath)
    }
}
