import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    // Claude Code quota (TUI scrape)
    @Published var claudeQuota: QuotaData?
    @Published var claudeError: String?
    @Published var claudeLoadedAt: Date?
    @Published var isFetchingClaude: Bool = false

    // Codex quota (JSON-RPC app-server)
    @Published var codexQuota: CodexRateLimits?
    @Published var codexError: String?
    @Published var codexLoadedAt: Date?
    @Published var isFetchingCodex: Bool = false

    /// Cached results stay "fresh" for this window before triggering refetches
    /// when the dropdown opens.
    private let staleAfter: TimeInterval = 15 * 60
    private let backgroundRefreshInterval: TimeInterval = 20 * 60

    private let claudeFetcher = QuotaFetcher()
    private let codexFetcher = CodexFetcher()
    private var refreshTimer: Timer?

    private init() {}

    var isFetchingAny: Bool { isFetchingClaude || isFetchingCodex }

    /// Kick off the first fetch and start the background refresh timer.
    func start() {
        Task { await refreshAll() }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: backgroundRefreshInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
    }

    // MARK: - Refresh

    func refreshAll() async {
        async let claude: Void = refreshClaude()
        async let codex:  Void = refreshCodex()
        _ = await (claude, codex)
    }

    func refreshIfNeeded() async {
        let claudeStale = claudeLoadedAt.map { Date().timeIntervalSince($0) > staleAfter } ?? true
        let codexStale  = codexLoadedAt.map  { Date().timeIntervalSince($0) > staleAfter } ?? true
        if claudeStale || codexStale {
            await refreshAll()
        }
    }

    func refreshClaude() async {
        guard !isFetchingClaude else { return }
        isFetchingClaude = true
        defer { isFetchingClaude = false }

        do {
            claudeQuota = try await claudeFetcher.fetch()
            claudeError = nil
            claudeLoadedAt = Date()
        } catch {
            claudeError = error.localizedDescription
        }
    }

    func refreshCodex() async {
        guard !isFetchingCodex else { return }
        isFetchingCodex = true
        defer { isFetchingCodex = false }

        do {
            codexQuota = try await codexFetcher.fetch()
            codexError = nil
            codexLoadedAt = Date()
        } catch {
            codexError = error.localizedDescription
        }
    }

    // MARK: - Derived per-service metrics

    var claudeMetrics: [QuotaMetric] {
        guard let q = claudeQuota else { return [] }
        let raw: [QuotaMetric] = [
            QuotaMetric(
                source: .claudeCode, kind: .session, label: "Session · 5h",
                percent: q.sessionPercent,
                resetRaw: q.sessionResetTime,
                resetDate: Self.parseClaudeResetDate(q.sessionResetTime)
            ),
            QuotaMetric(
                source: .claudeCode, kind: .weeklyAll, label: "Weekly · all models",
                percent: q.weeklyAllPercent,
                resetRaw: q.weeklyAllResetTime,
                resetDate: Self.parseClaudeResetDate(q.weeklyAllResetTime)
            ),
            QuotaMetric(
                source: .claudeCode, kind: .weeklySonnet, label: "Weekly · Sonnet",
                percent: q.weeklySonnetPercent,
                resetRaw: q.weeklySonnetResetTime,
                resetDate: Self.parseClaudeResetDate(q.weeklySonnetResetTime)
            ),
        ]
        return raw.filter(\.hasData)
    }

    var codexMetrics: [QuotaMetric] {
        guard let rl = codexQuota else { return [] }
        var out: [QuotaMetric] = []
        if let p = rl.primary {
            out.append(QuotaMetric(
                source: .codex, kind: .codexPrimary, label: codexLabel(for: p, fallback: "Session · 5h"),
                percent: p.usedPercent,
                resetRaw: formatCodexReset(p),
                resetDate: p.resetDate
            ))
        }
        if let s = rl.secondary {
            out.append(QuotaMetric(
                source: .codex, kind: .codexSecondary, label: codexLabel(for: s, fallback: "Weekly"),
                percent: s.usedPercent,
                resetRaw: formatCodexReset(s),
                resetDate: s.resetDate
            ))
        }
        return out.filter(\.hasData)
    }

    var allMetrics: [QuotaMetric] { claudeMetrics + codexMetrics }

    var worstOverall: QuotaMetric? {
        allMetrics.max(by: { $0.percent < $1.percent })
    }

    // MARK: - Helpers

    /// Build a friendly Codex label like "Session · 5h" or "Weekly · 7d"
    /// derived from windowDurationMins, falling back to a literal.
    private func codexLabel(for w: CodexWindow, fallback: String) -> String {
        guard let mins = w.windowDurationMins else { return fallback }
        switch mins {
        case 0..<60:                   return "Last \(mins)m"
        case 60..<1440:                return "Session · \(mins / 60)h"
        case 1440..<10080:             return "Last \(mins / 1440)d"
        case 10080..<43200:            return "Weekly"
        default:                       return "Last \(mins / 1440)d"
        }
    }

    private func formatCodexReset(_ w: CodexWindow) -> String {
        guard let date = w.resetDate else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Claude reset-time parsing
    //
    // Claude's /usage panel formats reset times like:
    //   "Mar 22 at 11pm (America/Los_Angeles)"
    //   "2pm"                       (today/tomorrow)
    // Codex hands us a unix timestamp directly, no parsing needed.

    static func parseClaudeResetDate(_ raw: String) -> Date? {
        guard raw != "—", !raw.isEmpty else { return nil }

        var tz = TimeZone.current
        if let open = raw.range(of: "("), let close = raw.range(of: ")"), open.upperBound < close.lowerBound {
            let id = String(raw[open.upperBound..<close.lowerBound])
            tz = TimeZone(identifier: id) ?? .current
        }

        var calendar = Calendar.current
        calendar.timeZone = tz

        let stripped = raw.components(separatedBy: "(").first?
            .trimmingCharacters(in: .whitespaces) ?? raw

        let months: [String: Int] = [
            "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
            "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
        ]

        if let m = try? NSRegularExpression(
            pattern: #"([A-Za-z]+)\s+(\d+)\s+at\s+(\d+)(?::(\d+))?\s*(am|pm)"#,
            options: .caseInsensitive
        ).firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) {
            let group = { (i: Int) -> String in
                String(stripped[Range(m.range(at: i), in: stripped)!])
            }
            guard let month = months[group(1).lowercased()] else { return nil }
            let day = Int(group(2)) ?? 1
            var hour = Int(group(3)) ?? 0
            let minute = m.range(at: 4).length > 0 ? (Int(group(4)) ?? 0) : 0
            let ampm = group(5).lowercased()
            if ampm == "pm", hour != 12 { hour += 12 }
            if ampm == "am", hour == 12 { hour = 0 }

            var comps = DateComponents()
            comps.year = calendar.component(.year, from: Date())
            comps.month = month
            comps.day = day
            comps.hour = hour
            comps.minute = minute
            comps.timeZone = tz
            if let date = calendar.date(from: comps) {
                if date < Date() {
                    comps.year! += 1
                    return calendar.date(from: comps)
                }
                return date
            }
        }

        if let m = try? NSRegularExpression(
            pattern: #"(\d+)(?::(\d+))?\s*(am|pm)"#,
            options: .caseInsensitive
        ).firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) {
            let group = { (i: Int) -> String in
                String(stripped[Range(m.range(at: i), in: stripped)!])
            }
            var hour = Int(group(1)) ?? 0
            let minute = m.range(at: 2).length > 0 ? (Int(group(2)) ?? 0) : 0
            let ampm = group(3).lowercased()
            if ampm == "pm", hour != 12 { hour += 12 }
            if ampm == "am", hour == 12 { hour = 0 }

            var comps = calendar.dateComponents([.year, .month, .day], from: Date())
            comps.hour = hour
            comps.minute = minute
            comps.timeZone = tz
            if let date = calendar.date(from: comps) {
                return date < Date() ? calendar.date(byAdding: .day, value: 1, to: date) : date
            }
        }

        return nil
    }
}

// MARK: - Time-until formatting

enum ResetTimeFormatter {
    /// "in 5d 22h" / "in 2h 14m" / "in 9m" / "now"
    static func relative(_ date: Date, from now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "now" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(minutes)m" }
        return "in \(minutes)m"
    }
}
