import AppKit
import Foundation

enum ElectronDetector {

    static func isElectron(_ target: AppTarget) -> Bool {
        guard let bundleId = target.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return false }
        let frameworkPath = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path
        return FileManager.default.fileExists(atPath: frameworkPath)
    }

    // Only connect to an explicitly enabled listener owned by the captured app.
    // Never scan common ports, terminate the app, or change its launch arguments.
    static func findDebugPort(pid: pid_t) async -> Int? {
        guard let port = portFromProcessArgs(pid: pid), ownsListener(pid: pid, port: port),
              await probePort(port) else { return nil }
        return port
    }

    static func debugPort(in arguments: String) -> Int? {
        let parts = arguments.split(whereSeparator: { $0.isWhitespace })
        guard let flag = parts.first(where: { $0.hasPrefix("--remote-debugging-port=") }),
              let port = Int(flag.dropFirst("--remote-debugging-port=".count)),
              (1...65535).contains(port) else { return nil }
        return port
    }

    private static func ownsListener(pid: pid_t, port: Int) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", String(pid), "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace }).contains(Substring(String(pid)))
    }

    private static func portFromProcessArgs(pid: pid_t) -> Int? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "args="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return debugPort(in: output)
    }

    static func probePort(_ port: Int) async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)/json/version") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 1)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json?["Browser"] != nil || json?["webSocketDebuggerUrl"] != nil
        } catch {
            return false
        }
    }
}
