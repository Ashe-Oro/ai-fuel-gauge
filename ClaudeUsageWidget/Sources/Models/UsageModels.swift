import Foundation

// MARK: - Quota Data (from on-demand /usage fetch)

struct QuotaData: Codable, Equatable {
    var sessionPercent: Int
    var sessionResetTime: String
    var weeklyAllPercent: Int
    var weeklyAllResetTime: String
    var weeklySonnetPercent: Int
    var weeklySonnetResetTime: String
}

/// One of the three /usage metrics, normalized for display.
struct QuotaMetric: Identifiable, Equatable {
    enum Kind: String { case session, weeklyAll, weeklySonnet }
    let kind: Kind
    let label: String
    let percent: Int
    let resetRaw: String
    let resetDate: Date?

    var id: String { kind.rawValue }
    var hasData: Bool { resetRaw != "—" && !resetRaw.isEmpty }
}
