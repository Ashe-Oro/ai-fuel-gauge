import SwiftUI

struct MenuBarDropdown: View {
    @ObservedObject var store = UsageStore.shared

    /// Re-renders the time-until labels every minute without re-fetching.
    @State private var tick = Date()
    private let tickTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            footer
        }
        .padding(14)
        .frame(width: 320)
        .task {
            // App launch starts the fetch; this is a safety net in case
            // the dropdown opens before that completes or data went stale.
            await store.refreshIfNeeded()
        }
        .onReceive(tickTimer) { tick = $0 }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Claude Usage")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
            Spacer()
            if store.isFetchingQuota {
                ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
            } else {
                Button {
                    Task { await store.refreshQuota() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Re-fetch /usage")
            }
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private var content: some View {
        if !store.displayMetrics.isEmpty {
            // Re-evaluate on every tick so relative times stay fresh.
            let _ = tick
            VStack(spacing: 16) {
                ForEach(Array(store.displayMetrics.enumerated()), id: \.element.id) { index, metric in
                    QuotaRow(metric: metric)
                    if index < store.displayMetrics.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
            .padding(.vertical, 4)
        } else if store.isFetchingQuota {
            loadingState
        } else if let err = store.quotaError {
            errorState(err)
        } else {
            emptyState
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.7)
            Text("Fetching usage…")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Spawning `claude` to query /usage. Takes ~6 s.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Couldn't fetch quota")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            Text(message)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await store.refreshQuota() }
            } label: {
                Text("Try again")
                    .font(.system(size: 11, design: .monospaced))
            }
            .controlSize(.small)
            .disabled(store.isFetchingQuota)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No quota data yet.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Button {
                Task { await store.refreshQuota() }
            } label: {
                Text("Fetch /usage")
                    .font(.system(size: 11, design: .monospaced))
            }
            .controlSize(.small)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let loaded = store.quotaLoadedAt {
                let _ = tick // refresh "N min ago" along with the rest
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
