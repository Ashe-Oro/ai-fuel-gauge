# AI Fuel Gauge

A tiny native macOS menu bar app that shows your **Claude Code** and **OpenAI Codex** session and weekly quotas as a fuel gauge: used vs. remaining, with reset times. No analytics, no model breakdown, no historical charts — just "how close am I to my limit, on either service."

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange) ![License](https://img.shields.io/badge/License-MIT-green)

## What it shows

Grouped by service, big colored percentage + bar + reset countdown for each metric:

**Claude Code**
- **Session · 5h** — your rolling 5-hour quota
- **Weekly · all models** — your 7-day quota
- **Weekly · Sonnet** — appears only if your plan exposes a Sonnet-only limit

**Codex**
- **Session · 5h** — your rolling 5-hour quota (Codex `primary` window)
- **Weekly** — your weekly quota (Codex `secondary` window)

The menu bar label shows the **worst-of-all** percentage across both services, e.g. `📊 41%` — green under 60%, amber 60–85%, red over 85%.

## Install

You need only **Xcode Command Line Tools** — no full Xcode required.

```bash
git clone https://github.com/Ashe-Oro/ai-fuel-gauge.git
cd ai-fuel-gauge
./build.sh release
open "build/Claude Usage.app"
```

Drag `build/Claude Usage.app` into `/Applications` to keep it permanent.

## How it works

The two services expose usage data very differently, so we use a different mechanism for each — but the user-facing UI is uniform.

### Claude Code

There's no public API for the per-account Claude Code quota. The only way to read it is by running the `claude` CLI and asking for `/usage`:

1. On launch, the bundled [`fetch-quota.exp`](ClaudeUsageWidget/Resources/fetch-quota.exp) script spawns `claude` under a pty (needed because `claude` falls back to print mode without a TTY).
2. The script waits for the `/usage` panel to render, sends `/exit`, and captures the output.
3. A Swift parser ([`QuotaFetcher.swift`](ClaudeUsageWidget/Sources/Services/QuotaFetcher.swift)) strips ANSI, locates the three section markers, and extracts the percentages and reset times.

### OpenAI Codex

Codex ships an official documented JSON-RPC app server. Much cleaner:

1. Spawn `codex app-server --listen stdio://`.
2. Send `initialize` (JSON-RPC handshake), then `account/rateLimits/read`.
3. Decode the response — `primary` (5-hour window) and `secondary` (weekly window) come back with `usedPercent`, `resetsAt` (unix seconds), and `windowDurationMins`.
4. No TUI scraping, no expect script.

See [`CodexFetcher.swift`](ClaudeUsageWidget/Sources/Services/CodexFetcher.swift).

### Refresh strategy

Both services are fetched on app launch, then every 20 minutes in the background. The dropdown auto-refreshes if data is older than 15 minutes when you open it. There's a manual refresh button in the header.

## Why not [eylonshm/claude-meter](https://github.com/eylonshm/claude-meter)?

This project started as a re-implementation of that one with a different safety stance:

| Decision | claude-meter | ai-fuel-gauge |
|---|---|---|
| `--dangerously-skip-permissions` flag | Yes, every refresh | **Never** |
| Refresh interval | 10 min | 20 min |
| Auto-launch at login | On by default | Off |
| Persistent debug log on disk | Yes | No |
| Codex support | No | Yes |
| Lines of Swift | ~2500 | ~900 |

## Safety stance

- The app is **not sandboxed** (it needs to spawn `claude` and `codex` outside the sandbox).
- It spawns `claude` once on launch + every 20 min while running, without the dangerous flag. The bundled expect script is ~30 lines and only sends `/usage` then `/exit`.
- It spawns `codex app-server` for ~1 second per refresh, exchanges two JSON messages, then exits.
- No log files. No telemetry. No network calls of its own (both subprocesses talk to their respective vendors).
- The whole codebase fits in your head. Read [QuotaFetcher.swift](ClaudeUsageWidget/Sources/Services/QuotaFetcher.swift), [CodexFetcher.swift](ClaudeUsageWidget/Sources/Services/CodexFetcher.swift), and [fetch-quota.exp](ClaudeUsageWidget/Resources/fetch-quota.exp) to see exactly what it does.

If any of this trips your security model, don't run it — the README is the contract.

## Requirements

- macOS 14 (Sonoma) or later
- For Claude Code metrics: [Claude Code CLI](https://claude.ai/code) installed (`claude` on `$PATH` or in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`)
- For Codex metrics: [OpenAI Codex CLI](https://openai.com/codex/) installed (`codex` in similar paths)
- `/usr/bin/expect` (ships with macOS)

Either CLI being missing is fine — the corresponding section will show an error and the other service will work normally.

## Project layout

```
ClaudeUsageWidget/
├── Resources/
│   └── fetch-quota.exp                # 30-line expect script for Claude TUI
└── Sources/
    ├── App/
    │   └── ClaudeUsageWidgetApp.swift  # @main, MenuBarExtra, label
    ├── Models/
    │   └── UsageModels.swift           # QuotaData, CodexRateLimits, QuotaMetric
    ├── Services/
    │   ├── QuotaFetcher.swift          # Claude: expect + TUI parser
    │   ├── CodexFetcher.swift          # Codex: app-server JSON-RPC
    │   └── UsageStore.swift            # @MainActor store + timer
    └── Views/
        ├── Components.swift            # QuotaRow, CapsuleFill
        └── MenuBarDropdown.swift       # Grouped-by-service UI
```

## License

MIT. See [LICENSE](LICENSE).
