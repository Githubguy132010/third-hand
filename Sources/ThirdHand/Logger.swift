import Foundation

enum Log {
    private static let path = NSHomeDirectory() + "/Desktop/thirdhand.log"

    static func info(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path) {
                if let fh = FileHandle(forWritingAtPath: path) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
        print(line, terminator: "")
    }
}
