# Claude Fuel Gauge

A tiny native macOS menu bar app that shows your Claude Code session and weekly quotas as a fuel gauge: used vs. remaining, with reset times. No analytics, no model breakdown, no historical charts — just "how close am I to my limit."

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange) ![License](https://img.shields.io/badge/License-MIT-green)

## What it shows

- **Session · 5h** — your rolling 5-hour quota, big colored percentage + bar + reset countdown
- **Weekly · all models** — your 7-day quota, same treatment
- **Weekly · Sonnet** — appears only if your plan exposes a Sonnet-only limit
- Menu bar label shows the worst-of-three percentage, e.g. `📊 24%`

Color thresholds: green under 60%, amber 60–85%, red over 85%.

## Install

### Build from source (the only option right now)

You need only **Xcode Command Line Tools** — no full Xcode required.

```bash
git clone https://github.com/Ashe-Oro/claude-fuel-gauge.git
cd claude-fuel-gauge
./build.sh release
open "build/Claude Usage.app"
```

To keep it permanent, drag `build/Claude Usage.app` into `/Applications`.

## How it works

There's no public API for the per-account Claude Code quota — the only way to read it is by running the `claude` CLI and asking for `/usage`. This app does that:

1. On launch, it spawns the bundled [`fetch-quota.exp`](ClaudeUsageWidget/Resources/fetch-quota.exp) script.
2. The script runs `claude` under a pty (needed because `claude` falls back to print mode without a TTY), waits for the `/usage` panel to render, sends `/exit`, and captures the output.
3. A Swift parser extracts the three percentages and reset times and renders them.

Subsequent refreshes happen every 20 minutes in the background, or whenever you click the menu bar icon if data is stale.

## Why not [eylonshm/claude-meter](https://github.com/eylonshm/claude-meter)?

This project started as a re-implementation of that one with a different safety stance:

| Decision | claude-meter | ai-fuel-gauge |
|---|---|---|
| `--dangerously-skip-permissions` flag | Yes, every refresh | **Never** |
| Refresh interval | 10 min (configurable) | 20 min |
| Auto-launch at login | On by default | Off |
| Persistent debug log on disk | Yes | No |
| Model breakdown / lifetime stats UI | Yes | No (out of scope) |
| Lines of Swift | ~2500 | ~700 |

`/usage` is a slash command that doesn't invoke tool use, so `--dangerously-skip-permissions` was never necessary for this use case — claude-meter passed it defensively. We don't.

## Safety stance

- The app is **not sandboxed** (it needs to spawn `claude` outside the sandbox and read `~/.claude/`).
- It spawns `claude` once on launch + every 20 min while running, without the dangerous flag. The bundled expect script is ~30 lines and only sends `/usage` then `/exit`.
- It writes no log files. No telemetry. No network calls of its own.
- The whole codebase fits in your head — read [QuotaFetcher.swift](ClaudeUsageWidget/Sources/Services/QuotaFetcher.swift) and [fetch-quota.exp](ClaudeUsageWidget/Resources/fetch-quota.exp) to see exactly what it does.

If any of this trips your security model, don't run it — the README is the contract.

## Requirements

- macOS 14 (Sonoma) or later
- [Claude Code CLI](https://claude.ai/code) installed (`claude` on `$PATH` or in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`)
- `/usr/bin/expect` (ships with macOS)

## Project layout

```
ClaudeUsageWidget/
├── Resources/
│   ├── ClaudeUsageWidget.entitlements
│   └── fetch-quota.exp        # The 30-line expect script
└── Sources/
    ├── App/
    │   └── ClaudeUsageWidgetApp.swift     # @main, MenuBarExtra, label
    ├── Models/
    │   └── UsageModels.swift               # QuotaData, QuotaMetric
    ├── Services/
    │   ├── QuotaFetcher.swift              # Spawns expect, parses TUI
    │   └── UsageStore.swift                # @MainActor store + timer
    └── Views/
        ├── Components.swift                # QuotaRow, CapsuleFill
        └── MenuBarDropdown.swift           # The dropdown UI
```

## License

MIT. See [LICENSE](LICENSE).
