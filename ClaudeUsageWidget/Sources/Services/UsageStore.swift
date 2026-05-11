import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published var quota: QuotaData?
    @Published var quotaError: String?
    @Published var quotaLoadedAt: Date?
    @Published var isFetchingQuota: Bool = false

    /// How long the cached quota stays "fresh." Reopening the dropdown within
    /// this window reuses the cached data; older than this triggers a refetch.
    private let staleAfter: TimeInterval = 15 * 60

    /// Background refresh interval. Chosen to keep the menu bar fresh-ish
    /// without spawning `claude` excessively.
    private let backgroundRefreshInterval: TimeInterval = 20 * 60

    private let fetcher = QuotaFetcher()
    private var refreshTimer: Timer?

    private init() {}

    /// Kick off the first fetch and start the background refresh timer.
    /// Call once from app launch.
    func start() {
        Task { await refreshQuota() }
        startBackgroundTimer()
    }

    private func startBackgroundTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: backgroundRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshQuota()
            }
        }
    }

    var quotaIsStale: Bool {
        guard let loaded = quotaLoadedAt else { return true }
        return Date().timeIntervalSince(loaded) > staleAfter
    }

    // MARK: - Fetch

    func refreshQuota() async {
        guard !isFetchingQuota else { return }
        isFetchingQuota = true
        defer { isFetchingQuota = false }

        do {
            quota = try await fetcher.fetch()
            quotaError = nil
            quotaLoadedAt = Date()
        } catch {
            quotaError = error.localizedDescription
        }
    }

    func refreshIfNeeded() async {
        if quota == nil || quotaIsStale {
            await refreshQuota()
        }
    }

    // MARK: - Derived metrics

    var metrics: [QuotaMetric] {
        guard let q = quota else { return [] }
        return [
            QuotaMetric(
                kind: .weeklyAll,
                label: "Weekly · all models",
                percent: q.weeklyAllPercent,
                resetRaw: q.weeklyAllResetTime,
                resetDate: Self.parseResetDate(q.weeklyAllResetTime)
            ),
            QuotaMetric(
                kind: .weeklySonnet,
                label: "Weekly · Sonnet",
                percent: q.weeklySonnetPercent,
                resetRaw: q.weeklySonnetResetTime,
                resetDate: Self.parseResetDate(q.weeklySonnetResetTime)
            ),
            QuotaMetric(
                kind: .session,
                label: "Session · 5h",
                percent: q.sessionPercent,
                resetRaw: q.sessionResetTime,
                resetDate: Self.parseResetDate(q.sessionResetTime)
            ),
        ]
    }

    /// Metrics to show, in display order: session first (most immediate,
    /// resets within 5h), then weekly limits.
    var displayMetrics: [QuotaMetric] {
        let order: [QuotaMetric.Kind] = [.session, .weeklyAll, .weeklySonnet]
        let byKind = Dictionary(uniqueKeysWithValues: metrics.map { ($0.kind, $0) })
        return order.compactMap { byKind[$0] }.filter(\.hasData)
    }

    // MARK: - Reset-time parsing
    //
    // Claude's /usage panel formats reset times like:
    //   "Mar 22 at 11pm (America/Los_Angeles)"
    //   "2pm"                       (today/tomorrow)
    // We need a Date so we can show "in 5d 22h".

    static func parseResetDate(_ raw: String) -> Date? {
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

        // "Mar 22 at 11pm" or "Mar 22 at 11:30pm"
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

        // "2pm" or "2:30pm" — interpret as today, else tomorrow
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
    /// "in 5d 22h" / "in 2h 14m" / "in 9m" / "now" — what to show
    /// the user as the "time until reset" hint next to a quota row.
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
