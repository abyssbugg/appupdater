# AGENT_LOG.md — full work history (chronological, verbatim-style)

Convention: newest entries on top. Entries move here from AGENTS.md when work completes.
Honesty standard (CLAUDE.md §7) applies to this log: confirmed / suspected / unverified are labeled.

---

## 2026-10-26 — Phase 1 (Scaffold) COMPLETE — full gate green

**Where:** `~/dev/appupdater`, branch `main`.

**Confirmed (all with live command evidence, this session):**
1. SwiftPM scaffold: Package.swift (`platforms: macOS 15`, targets `AppUpdaterCore` lib + `AppUpdaterApp` exec + `AppUpdaterCoreTests`), models (`InstalledApp`, `UpdateInfo`, `SourceKind`, `UpdateConfidence`), protocols (`UpdateSource`, `AppScanner`), app shell with TWO surfaces: `MenuBarExtra` (menu-bar) + `Window(id: "main")` (normal window) — owner requirement honored in the same bundle.
2. Gate results: `swift build` exit 0 · `swift test` exit 0 with 2 tests/1 suite (Swift Testing) · `Scripts/make-app.sh release` → `Assembled: build/AppUpdater.app` · `codesign -v --strict` OK (adhoc) · `plutil -lint` OK · launched live (pid observed, zero crash reports, clean quit).
3. Build errors fixed en route (real diagnostics recovered from log-file after frontend-command truncation): missing `import AppUpdaterCore` in AppState; stale `requestMainWindow` call in App scene → replaced with `@Environment(\.openWindow)` + `openWindow(id: "main")`; dead notification relay removed.
4. XCTest discovery broken on Xcode 27.0 beta (0 tests collected, green lie) → migrated tests to Swift Testing. Recorded in gotcha ledger.

**Phase 1 status: DONE and verified.** Next: Phase 2 lanes (scanner, cask, sparkle, MAS, version oracle) as parallel worktrees + subagents per BUILD-PLAN.

---

## 2026-10-26 — Analysis phase complete → project folder established; build phase opened

**Where it happened:** investigation was performed in `/Users/datamatics/Downloads/findinggs` (incidental download folder);
all project artifacts were then relocated to `/Users/datamatics/dev/appupdater` by owner request. The findinggs folder is dead to this project.

**Work done (confirmed, evidence cited):**

1. **MacUpdater 3.5.0 reverse-engineered** (shipped binary `/Applications/MacUpdater.app`, arm64 Mach-O, SHA-256 `e45dfe7db90b0539fa7a6cb04d4ed3dbf9119f32b031c33476f9d781b827e870`), using REA/Hopper. Recovery included:
   - Full Objective-C class + method map (721 classes, 14,918 methods; extract of the 29 pipeline classes preserved in tool evidence).
   - Batch decompile evidence `ev_4fa650406a555035d6d27a2ca743cc64c36a49bf8673f4daa8f8a5627d00d148` covering: `JMSUPlainInstaller`, `PrivilegedInstallHelper`, `AppUpdateHelper.updateApp…`, `SparkleFeedParser.downloadFeedURL`, `CaskHelper.downloadCaskfileFromURL`, `AppstoreFixupHelper._getNewestVersionOfApp`, `CGIInfoHelper.receiveInfoForApp`, `AppQuitHelper.sendQuitEvent`.
   - `scanAppAtPath` pseudocode 3.3 MB (surface strings captured; full text exceeded transport — one unresolved limit, noted honestly).
   - REA session could not be cleanly closed at the very end (`cleanup_incomplete` guard; temp dir `/tmp/rea-*` removed manually by shell). Analysis conclusions unaffected; noted in case the guard bites future sessions.
2. **Live-system evidence mined:** MacUpdater runtime log (~1 MB), `savedAppInfo3.plist` schema, defaults, launchd plists, install/uninstall shell scripts, vendored `readability.js` + `inject.js`, CLI grammar of `macupdater_client`.
3. **Endpoint catalog verified live:** `itunes.apple.com/lookup`, Sparkle appcasts (per-app `SUFeedURL`), `macupdater.net/cgi-bin/*receive.cgi` family, `macupdater-backend.com` private cask mirrors, plus vendor-specific feeds (GitHub API, App Center, DevMate, Firefox AUS…). Cask JSON API sample fetched: `docs/evidence/ff.json` (`formulae.brew.sh/api/cask/firefox.json` — 9.4 KB dict incl. `version`, `sha256`, `artifacts[].app`, `quit`).
4. **Second reference app analyzed (strings-level):** Updatest.app 3.0.0 — modern source mix verified from its binary strings: `formulae.brew.sh/api/cask.json` (full index), aggregated Sparkle feeds, GitHub, Electron, `itunes lookup`, `api.updatest.network`; confidence-labeled update categories (Unverified/LowConfidence/Incompatible).
5. **Deliverable written:** `docs/MACUPDATER-BREAKDOWN.md` (architecture, mechanics, source tiers, combined design §3, open questions). Reference samples in `docs/evidence/`.

**Owner decisions locked (verbatim-conversation):** AppUpdater name·= my proposal accepted; scope = both (other apps + self-update); architecture = hybrid MacUpdater+Updatest; MAS = both modes; audience = private + public.

**Environment facts (verified live, macOS 27.2 / Xcode 27.0 beta / Swift 6.4):**
- Signing identity in keychain: 1 only — `Spike0 Signing` (dev-class, NOT Developer ID).
- `gh` authenticated as `abyssbugg`; local `git init` performed at project folder creation.
- `swiftlint` not installed (must be added before the lint gate is real).

**Open at close of day:** stack-freeze sign-off, Developer ID enrollment, helper phase timing, remote visibility, v1 source-set sign-off (see AGENTS.md open items).

---

## 2026-10-25/26 — (earlier session) investigation started; key finding

User goal stated; MacUpdater located in `/Applications`; log-derived scan/update flow captured
(Sparkle-feed-first scan with cask fallthrough; privileged helper path observed live:
"update needs auth, and helper installed, using priviledgedhelpertool").
Full detail of this window is merged into the 2026-10-26 entry above (same investigation run).
