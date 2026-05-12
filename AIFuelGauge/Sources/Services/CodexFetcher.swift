import Foundation

enum CodexFetcherError: LocalizedError {
    case cliNotFound
    case spawnFailed(String)
    case timedOut
    case rpcError(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Couldn't find the `codex` CLI. Install Codex from https://openai.com/codex/."
        case .spawnFailed(let detail):
            return "Failed to start codex app-server: \(detail)"
        case .timedOut:
            return "Codex didn't respond to rate-limits request in time."
        case .rpcError(let msg):
            return "Codex app-server returned an error: \(msg)"
        case .decodeFailed(let detail):
            return "Couldn't decode Codex response: \(detail)"
        }
    }
}

/// Fetches Codex usage by speaking the documented JSON-RPC `codex app-server`
/// protocol over stdio. Much cleaner than the Claude path — no TUI scraping,
/// no expect script, no terminal emulation.
///
/// Protocol: send `initialize` then `account/rateLimits/read`, read responses
/// line-by-line (JSON-Lines), filter by JSON-RPC `id` field.
struct CodexFetcher {
    private let hardKillSeconds: TimeInterval = 10

    func fetch() async throws -> CodexRateLimits {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CodexRateLimits, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.runRPC(hardKill: self.hardKillSeconds)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Subprocess + JSON-RPC

    private static func runRPC(hardKill: TimeInterval) throws -> CodexRateLimits {
        guard let codexPath = resolveCodexPath() else {
            throw CodexFetcherError.cliNotFound
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()

        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        process.environment = minimalEnv()

        do {
            try process.run()
        } catch {
            throw CodexFetcherError.spawnFailed(error.localizedDescription)
        }

        // Send initialize, then rate-limits read. The server is async and may
        // also push unsolicited notifications (e.g. remoteControl/status/changed)
        // mixed into the response stream — we filter by `id`.
        let initRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["clientInfo": ["name": "ai-fuel-gauge", "version": "0.1.0"]]
        ]
        let limitsRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "account/rateLimits/read",
            "params": [:]
        ]

        let stdinHandle = stdin.fileHandleForWriting
        do {
            try Self.writeJsonLine(initRequest, to: stdinHandle)
            try Self.writeJsonLine(limitsRequest, to: stdinHandle)
        } catch {
            process.terminate()
            throw CodexFetcherError.spawnFailed("write to stdin failed: \(error.localizedDescription)")
        }

        // Hard kill if the process is still alive after the deadline.
        let killDeadline = Date().addingTimeInterval(hardKill)
        DispatchQueue.global(qos: .utility).async {
            while process.isRunning {
                if Date() >= killDeadline {
                    process.terminate()
                    break
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        // Read stdout line-by-line, looking for the response with id=2.
        let outHandle = stdout.fileHandleForReading
        var rateLimits: CodexRateLimits?
        var rpcError: String?
        let deadline = Date().addingTimeInterval(hardKill)

        while Date() < deadline {
            guard let line = readLine(from: outHandle, deadline: deadline) else { break }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }

            // Only care about responses with id=2
            if (json["id"] as? Int) == 2 {
                if let err = json["error"] as? [String: Any] {
                    rpcError = (err["message"] as? String) ?? String(describing: err)
                } else if let result = json["result"] as? [String: Any],
                          let limits = result["rateLimits"] as? [String: Any] {
                    rateLimits = Self.parseRateLimits(limits)
                }
                break
            }
        }

        process.terminate()
        process.waitUntilExit()

        if let err = rpcError {
            throw CodexFetcherError.rpcError(err)
        }
        guard let rl = rateLimits else {
            let errData = stderr.fileHandleForReading.availableData
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw CodexFetcherError.timedOut.localized(or: errStr.isEmpty ? nil : "stderr: \(errStr.prefix(200))")
        }
        return rl
    }

    private static func writeJsonLine(_ obj: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data("\n".utf8))
    }

    /// Read one '\n'-terminated line from the handle, honoring the deadline.
    /// `FileHandle.readLine` doesn't exist on FileHandle proper, so we accumulate
    /// bytes until we see `\n` or the deadline elapses.
    private static func readLine(from handle: FileHandle, deadline: Date) -> String? {
        var buf = Data()
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            buf.append(chunk)
            if let nl = buf.firstIndex(of: 0x0A) {
                let lineData = buf[buf.startIndex..<nl]
                return String(data: lineData, encoding: .utf8)
            }
        }
        return buf.isEmpty ? nil : String(data: buf, encoding: .utf8)
    }

    private static func parseRateLimits(_ dict: [String: Any]) -> CodexRateLimits {
        var rl = CodexRateLimits(primary: nil, secondary: nil, planType: dict["planType"] as? String)
        if let primary = dict["primary"] as? [String: Any] {
            rl.primary = Self.parseWindow(primary)
        }
        if let secondary = dict["secondary"] as? [String: Any] {
            rl.secondary = Self.parseWindow(secondary)
        }
        return rl
    }

    private static func parseWindow(_ dict: [String: Any]) -> CodexWindow {
        CodexWindow(
            usedPercent: (dict["usedPercent"] as? Int) ?? 0,
            windowDurationMins: dict["windowDurationMins"] as? Int,
            resetsAt: (dict["resetsAt"] as? Int64) ?? (dict["resetsAt"] as? Int).map(Int64.init)
        )
    }

    // MARK: - Paths + env

    private static func resolveCodexPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin/codex",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["sh", "-c", "command -v codex"]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    private static func minimalEnv() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [
            "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        env["HOME"] = home
        env["USER"] = NSUserName()
        return env
    }
}

private extension CodexFetcherError {
    func localized(or detail: String?) -> CodexFetcherError {
        if let detail { return .rpcError(detail) }
        return self
    }
}
