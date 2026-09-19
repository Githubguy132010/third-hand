import AppKit
import Foundation

enum ElectronDetector {

    static let debugPort = 9222

    static func isElectron(_ target: AppTarget) -> Bool {
        guard let bundleId = target.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return false }
        let frameworkPath = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path
        return FileManager.default.fileExists(atPath: frameworkPath)
    }

    static func findDebugPort(pid: pid_t) async -> Int? {
        if let port = portFromProcessArgs(pid: pid) { return port }
        for port in [debugPort, 9229] {
            if await probePort(port) { return port }
        }
        return nil
    }

    static func relaunchWithDebugging(target: AppTarget) async throws -> Int {
        guard let bundleId = target.bundleIdentifier else {
            throw ControllerError.invalid("Cannot relaunch: no bundle identifier")
        }
        let port = debugPort

        target.application.terminate()
        for _ in 0..<40 {
            if target.application.isTerminated { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if !target.application.isTerminated {
            target.application.forceTerminate()
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-b", bundleId, "--args", "--remote-debugging-port=\(port)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()

        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if await probePort(port) { return port }
        }
        throw ControllerError.invalid("\(target.name) restarted but CDP port \(port) did not respond")
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
        guard let range = output.range(of: "--remote-debugging-port=") else { return nil }
        let after = output[range.upperBound...]
        let digits = after.prefix(while: { $0.isNumber })
        return Int(digits)
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
