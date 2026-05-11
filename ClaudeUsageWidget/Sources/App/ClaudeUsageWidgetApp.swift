import SwiftUI

@main
struct ClaudeUsageWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = UsageStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarDropdown()
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The text shown next to the menu bar clock. Picks the worst-of-three
/// quota percentages and colors it by threshold. Falls back to "—" while
/// the first fetch is in flight and to "!" if the fetch failed.
private struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        if let worst = worstMetric {
            HStack(spacing: 3) {
                Image(systemName: "chart.bar.fill")
                Text("\(worst.percent)%")
            }
        } else if store.quotaError != nil {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("!")
            }
        } else {
            HStack(spacing: 3) {
                Image(systemName: "chart.bar.fill")
                Text("—")
            }
        }
    }

    private var worstMetric: QuotaMetric? {
        store.displayMetrics.max(by: { $0.percent < $1.percent })
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Kick off the first quota fetch and start the background refresh timer
        // so the dropdown has data the first time the user clicks it.
        Task { @MainActor in
            UsageStore.shared.start()
        }
    }
}
