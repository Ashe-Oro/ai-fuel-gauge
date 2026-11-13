import SwiftUI

struct MenuBarDropdown: View {
    @ObservedObject var store = UsageStore.shared

    @State private var tick = Date()
    private let tickTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            footer
        }
        .padding(14)
        .frame(width: 340)
        .task { await store.refreshIfNeeded() }
        .onReceive(tickTimer) { tick = $0 }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("AI Fuel Gauge")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
            Spacer()
            if store.isFetchingAny {
                ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
            } else {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh all")
            }
        }
    }

    // MARK: - Body content

    @ViewBuilder
    private var content: some View {
        let _ = tick // re-evaluate relative times each minute

        let hasClaude = !store.claudeMetrics.isEmpty
        let hasCodex  = !store.codexMetrics.isEmpty
        let hasGrok = !store.grokMetrics.isEmpty
        let hasAny    = hasClaude || hasCodex || hasGrok

        if hasAny {
            VStack(spacing: 10) {
                if hasGrok || store.grokStatus != nil {
                    ServiceSection(source: .grok, metrics: store.grokMetrics, error: store.grokStatus)
                }
                if hasClaude || store.claudeError != nil {
                    ServiceSection(
                        source: .claudeCode,
                        metrics: store.claudeMetrics,
                        error: store.claudeError
                    )
                }
                if hasCodex || store.codexError != nil {
                    ServiceSection(
                        source: .codex,
                        metrics: store.codexMetrics,
                        error: store.codexError
                    )
                }

            }
        } else if store.isFetchingAny {
            loadingState
        } else if store.claudeError != nil || store.codexError != nil || store.grokStatus != nil {
            VStack(spacing: 12) {
                if let err = store.grokStatus { errorRow(source: .grok, message: err) }
                if let err = store.claudeError { errorRow(source: .claudeCode, message: err) }
                if let err = store.codexError  { errorRow(source: .codex,      message: err) }
            }
        } else {
            emptyState
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().scaleEffect(0.7)
            Text("Fetching usage…")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No data yet.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Button {
                Task { await store.refreshAll() }
            } label: {
                Text("Fetch now")
                    .font(.system(size: 11, design: .monospaced))
            }
            .controlSize(.small)
        }
    }

    private func errorRow(source: QuotaSource, message: String) -> some View {
        ServiceSection(source: source, metrics: [], error: message)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let loaded = store.claudeLoadedAt ?? store.codexLoadedAt {
                let _ = tick
                Text("fetched \(loaded, style: .relative) ago")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Service section

private struct ServiceSection: View {
    let source: QuotaSource
    let metrics: [QuotaMetric]
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: source.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(source.accentColor)
                Text(source.displayName.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(source.accentColor)
                Spacer()
            }

            if let err = error, metrics.isEmpty {
                Text(err)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 14) {
                    ForEach(metrics) { metric in
                        QuotaRow(metric: metric)
                    }
                }
                if let status = error {
                    Text(status)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(source.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(source.accentColor.opacity(0.18), lineWidth: 1)
        }
    }
}
