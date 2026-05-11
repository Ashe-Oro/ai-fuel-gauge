import SwiftUI

// MARK: - Color thresholds

enum QuotaColor {
    static func tint(forPercent pct: Int) -> Color {
        if pct >= 85 { return .red }
        if pct >= 60 { return .orange }
        return .green
    }
}

// MARK: - Quota row

/// One quota metric — big number, capsule bar, reset info. Used for both
/// the 5h session and the weekly limits; same visual weight for all.
struct QuotaRow: View {
    let metric: QuotaMetric

    private var tint: Color { QuotaColor.tint(forPercent: metric.percent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.label.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(metric.percent)")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(tint.opacity(0.7))
            }

            CapsuleFill(percent: metric.percent, tint: tint, height: 8)

            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(resetLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var resetLine: String {
        let absolute = metric.resetRaw == "—" ? "" : "Resets \(metric.resetRaw)"
        if let reset = metric.resetDate {
            let rel = ResetTimeFormatter.relative(reset)
            return absolute.isEmpty ? rel : "\(absolute) · \(rel)"
        }
        return absolute.isEmpty ? "—" : absolute
    }
}

// MARK: - Capsule fill

struct CapsuleFill: View {
    let percent: Int
    let tint: Color
    var height: CGFloat = 8

    private var clamped: Double { max(0, min(100, Double(percent))) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: geo.size.width * clamped / 100)
            }
        }
        .frame(height: height)
    }
}
