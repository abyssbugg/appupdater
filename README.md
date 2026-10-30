# AppUpdater

A **hybrid** macOS app updater: MacUpdater's execution engine (scan, one-click verified
install, backups, quit/relaunch, scheduler) combined with Updatest's serverless source
strategy (public Homebrew cask index, each app's own Sparkle appcast, Mac App Store lookup,
GitHub releases, Electron metadata). It also updates itself via Sparkle 2 (EdDSA-signed).

**Status:** built and in owner live-testing. Latest release: **v0.1.0** (2026-10-27,
ad-hoc signed, NOT notarized — Gatekeeper warns on first launch). Swift 6.4 / SwiftPM,
macOS 15.0+. Ground truth for decisions, gate and open items: [`AGENTS.md`](AGENTS.md);
how-to-work protocol: [`CLAUDE.md`](CLAUDE.md).

## Layout

| Path | What |
|---|---|
| `Sources/AppUpdaterCore` | dependency-free engine: scan, sources, version oracle, installer, schedule, auto-apply gate, notifications, … |
| `Sources/AppUpdaterApp` | SwiftUI window + menu-bar shell (LSUIElement), Sparkle self-update |
| `Sources/appupdater-cli` | `scan` / `check` / `install` (dry-run default, `--apply`) / `security` / `brew-*` / `proxy`; JSON on stdout |
| `Tests/AppUpdaterCoreTests` | Swift Testing suite (XCTest discovery is broken on this toolchain) |
| `Scripts/make-app.sh`, `Scripts/make-release.sh` | bundle assembly + signed release pipeline |
| `docs/` | architecture (`MACUPDATER-BREAKDOWN.md`), phase history (`BUILD-PLAN.md`), release runbook, threat model, evidence, full log (`archive/AGENT_LOG.md`) |

## Quick start

```
swift build && swift test
swift run appupdater-cli scan
swift run appupdater-cli check --apps Ghostty
Scripts/make-app.sh release && open build/AppUpdater.app
```

## Security floor

HTTPS-only downloads (including every redirect hop), SHA-256 verification + artifact magic
before anything is replaced, bundle-identifier hijack refusal at swap, zip backup before
swap. PKG installers and `brew --adopt` are never executed — only staged as owner-run
commands. No privileged helper is active (built dormant; activation needs Developer ID).
