import Foundation

enum QuotaFetcherError: LocalizedError {
    case cliNotFound
    case scriptNotFound
    case spawnFailed(String)
    case timedOut
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Couldn't find the `claude` CLI. Install Claude Code from https://claude.ai/code."
        case .scriptNotFound:
            return "Missing fetch-quota.exp in the app bundle."
        case .spawnFailed(let detail):
            return "Failed to run claude: \(detail)"
        case .timedOut:
            return "Quota fetch timed out. The /usage panel didn't render in time."
        case .parseFailed(let detail):
            return "Couldn't parse /usage output: \(detail)"
        }
    }
}

/// Fetches Claude Code quota by driving an interactive `claude` session.
///
/// Safety invariants:
/// - NEVER passes `--dangerously-skip-permissions`. (See fetch-quota.exp.)
/// - Runs from `~/.claude` to avoid the workspace-trust dialog.
/// - Hard process timeout — never leaves a CLI session hanging.
/// - Why expect? `claude` detects when stdin/stdout aren't a TTY and falls
///   through to print mode, where `/usage` is interpreted as a prompt instead
///   of a slash command. The bundled fetch-quota.exp gives it a real pty.
struct QuotaFetcher {
    private let hardKillSeconds: TimeInterval = 18

    func fetch() async throws -> QuotaData {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<QuotaData, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let raw = try Self.runUsageSession(hardKill: self.hardKillSeconds)
                    let parsed = try Self.parse(raw)
                    continuation.resume(returning: parsed)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Subprocess

    private static func runUsageSession(hardKill: TimeInterval) throws -> String {
        guard let claudePath = resolveClaudePath() else {
            throw QuotaFetcherError.cliNotFound
        }
        guard let scriptPath = Bundle.main.path(forResource: "fetch-quota", ofType: "exp") else {
            throw QuotaFetcherError.scriptNotFound
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let claudeDir = "\(home)/.claude"

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
        process.arguments = ["-f", scriptPath, claudePath]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: claudeDir) ? claudeDir : home)
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = minimalEnv(home: home)

        do {
            try process.run()
        } catch {
            throw QuotaFetcherError.spawnFailed(error.localizedDescription)
        }

        // Hard kill if the process is still running after the deadline.
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

        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""

        if out.isEmpty {
            throw QuotaFetcherError.parseFailed(err.isEmpty ? "no output" : String(err.prefix(200)))
        }
        return out
    }

    // MARK: - CLI path resolution

    private static func resolveClaudePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
        // Fall back to PATH lookup via /usr/bin/env
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["sh", "-c", "command -v claude"]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    private static func minimalEnv(home: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let path = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ].joined(separator: ":")
        env["PATH"] = path
        env["HOME"] = home
        env["USER"] = NSUserName()
        env["SHELL"] = env["SHELL"] ?? "/bin/zsh"
        env["TERM"] = "xterm-256color"
        return env
    }

    // MARK: - Parsing
    //
    // The /usage panel renders three sections in a TUI box. The pty stream
    // collapses inter-word whitespace, so "Current session" appears as
    // "Currentsession" and "12am (America/New_York)" as "12am(America/New_York)".
    //
    // Strategy:
    //   1. Strip ANSI / OSC / charset-switch escapes thoroughly.
    //   2. Locate each of the three section markers by regex.
    //   3. For each section, slice from its marker to the next section or to
    //      a known terminator ("What's contributing", "Esc to cancel", etc.)
    //      so descriptive footer text never bleeds into reset strings.
    //   4. Extract the percentage and the substring after "Resets" from each
    //      slice, then re-inject spaces only where digits abut month names or
    //      timezone parentheses — never touch arbitrary words.

    static func parse(_ raw: String) throws -> QuotaData {
        let clean = stripAnsi(raw)

        let sectionMarkers: [(QuotaMetric.Kind, String)] = [
            (.session,      #"Current\s*session\b"#),
            (.weeklyAll,    #"Current\s*week\s*\(?\s*all\s*models"#),
            (.weeklySonnet, #"Current\s*week\s*\(?\s*Sonnet"#),
        ]

        // Locate each section's offset in `clean`. Sort by document order
        // so each section's slice runs to the next section's start.
        struct Located { let kind: QuotaMetric.Kind; let start: String.Index }
        let located: [Located] = sectionMarkers.compactMap { kind, pattern in
            guard let r = clean.range(
                of: pattern, options: [.regularExpression, .caseInsensitive]
            ) else { return nil }
            return Located(kind: kind, start: r.lowerBound)
        }.sorted { $0.start < $1.start }

        guard !located.isEmpty else {
            throw QuotaFetcherError.parseFailed("no Current* section markers found")
        }

        // Anything from these terminators onward is descriptive footer text,
        // not metric content. We clamp every section's end at the earliest one.
        let terminatorPatterns = [
            #"What'?s\s*contributing"#,
            #"Approxim"#,
            #"Scanning\s*local"#,
            #"Refreshing"#,
            #"Esc\s*to\s*cancel"#,
        ]
        let footerStart: String.Index = terminatorPatterns
            .compactMap { clean.range(of: $0, options: [.regularExpression, .caseInsensitive])?.lowerBound }
            .min() ?? clean.endIndex

        var section: [QuotaMetric.Kind: (pct: Int, reset: String)] = [:]
        for (i, item) in located.enumerated() {
            let sectionEnd: String.Index
            if i + 1 < located.count {
                sectionEnd = min(located[i + 1].start, footerStart)
            } else {
                sectionEnd = footerStart
            }
            guard item.start < sectionEnd else { continue }
            let slice = String(clean[item.start..<sectionEnd])
            let pct = Self.extractPercent(slice) ?? 0
            let reset = Self.extractReset(slice) ?? "—"
            section[item.kind] = (pct, reset)
        }

        let result = QuotaData(
            sessionPercent:       section[.session]?.pct      ?? 0,
            sessionResetTime:     section[.session]?.reset    ?? "—",
            weeklyAllPercent:     section[.weeklyAll]?.pct    ?? 0,
            weeklyAllResetTime:   section[.weeklyAll]?.reset  ?? "—",
            weeklySonnetPercent:  section[.weeklySonnet]?.pct ?? 0,
            weeklySonnetResetTime: section[.weeklySonnet]?.reset ?? "—"
        )

        if result.sessionPercent == 0, result.weeklyAllPercent == 0, result.weeklySonnetPercent == 0,
           result.sessionResetTime == "—", result.weeklyAllResetTime == "—", result.weeklySonnetResetTime == "—" {
            throw QuotaFetcherError.parseFailed("section markers found but no metrics extracted")
        }
        return result
    }

    private static func extractPercent(_ s: String) -> Int? {
        guard let range = s.range(of: #"\d+%"#, options: .regularExpression) else { return nil }
        return Int(s[range].dropLast())
    }

    /// Find "Resets" inside a section slice, then capture only the immediately
    /// following datetime token. Bounded to avoid descriptive-text bleed.
    private static func extractReset(_ section: String) -> String? {
        guard let r = section.range(of: #"Resets?"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        // Cap at 60 chars — a reset string is always short. Defensive ceiling
        // against TUI redraws splicing extra content in.
        let after = section[r.upperBound...]
        let capped = after.prefix(60)
        let raw = capped.trimmingCharacters(in: .whitespacesAndNewlines)
        let spaced = restoreResetSpacing(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return spaced.isEmpty ? nil : spaced
    }

    /// The TUI collapses inter-word whitespace. We restore spaces ONLY in known
    /// reset-string positions — never on arbitrary text — to avoid mangling
    /// words like "What's" or "Approximate" that contain "at"/"am" substrings.
    private static func restoreResetSpacing(_ s: String) -> String {
        var out = s
        let subs: [(String, String)] = [
            // Month + digit (May18 → May 18)
            (#"(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)(\d)"#, "$1 $2"),
            // digit + "at" + digit (18at12 → 18 at 12)
            (#"(\d)at(\d)"#, "$1 at $2"),
            // am/pm + ( (12am( → 12am ()
            (#"(am|pm)\("#, "$1 ("),
            // digit + am/pm at word boundary already fine; leave alone.
        ]
        for (pat, rep) in subs {
            out = out.replacingOccurrences(of: pat, with: rep, options: .regularExpression)
        }
        return out
    }

    /// Strip ANSI escape sequences: CSI ESC [..letter, OSC ESC ]..BEL, plus
    /// charset switches (ESC ( B), save/restore cursor (ESC 7/8), and a few
    /// other stragglers that appear in Claude's TUI.
    ///
    /// NOTE: these patterns MUST be plain (not extended-raw) string literals so
    /// `\u{1B}` is interpreted as the ESC byte rather than 6 literal characters.
    /// Using `#"..."#` here silently breaks every ANSI strip.
    private static func stripAnsi(_ s: String) -> String {
        let patterns = [
            "\u{1B}\\[[0-9;?<>=]*[a-zA-Z]",   // CSI sequences
            "\u{1B}\\][^\u{07}]*\u{07}",      // OSC sequences terminated by BEL
            "\u{1B}[()][a-zA-Z]",             // charset designators
            "\u{1B}[78cHM>=]",                // 1-char escapes
        ]
        var out = s
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        return out
    }
}
