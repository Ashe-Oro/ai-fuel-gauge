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

/// The text shown next to the menu bar clock. Picks the worst-of-all
/// quota percentages across both Claude Code and Codex. Falls back to
/// "—" while the first fetch is in flight; "!" if every fetch failed.
private struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
            Text(label)
        }
    }

    private var iconName: String {
        if store.worstOverall == nil, allFailed {
            return "exclamationmark.triangle.fill"
        }
        return "chart.bar.fill"
    }

    private var label: String {
        if let worst = store.worstOverall {
            return "\(worst.percent)%"
        }
        return allFailed ? "!" : "—"
    }

    private var allFailed: Bool {
        store.claudeError != nil && store.codexError != nil
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
