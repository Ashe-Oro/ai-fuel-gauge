import Foundation

// MARK: - Sources

enum QuotaSource: String, Codable, CaseIterable {
    case claudeCode
    case codex

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        }
    }

    var icon: String {
        switch self {
        case .claudeCode: return "sparkles"
        case .codex:      return "command"
        }
    }
}

// MARK: - Claude Quota (from /usage TUI scrape)

struct QuotaData: Codable, Equatable {
    var sessionPercent: Int
    var sessionResetTime: String
    var weeklyAllPercent: Int
    var weeklyAllResetTime: String
    var weeklySonnetPercent: Int
    var weeklySonnetResetTime: String
}

// MARK: - Codex Rate Limits (from app-server JSON-RPC)

/// Subset of Codex's `account/rateLimits/read` response that we actually use.
struct CodexRateLimits: Codable, Equatable {
    var primary: CodexWindow?      // typically 5-hour rolling
    var secondary: CodexWindow?    // typically 7-day rolling
    var planType: String?
}

struct CodexWindow: Codable, Equatable {
    var usedPercent: Int
    var windowDurationMins: Int?
    var resetsAt: Int64?  // unix seconds

    var resetDate: Date? {
        resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

// MARK: - Unified display metric

struct QuotaMetric: Identifiable, Equatable {
    enum Kind: String { case session, weeklyAll, weeklySonnet, codexPrimary, codexSecondary }

    let source: QuotaSource
    let kind: Kind
    let label: String
    let percent: Int
    let resetRaw: String
    let resetDate: Date?

    var id: String { "\(source.rawValue):\(kind.rawValue)" }
    var hasData: Bool { resetRaw != "—" && !resetRaw.isEmpty || resetDate != nil }
}
