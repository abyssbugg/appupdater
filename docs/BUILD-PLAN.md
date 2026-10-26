# Build Plan — AppUpdater (hybrid: MacUpdater engine + Updatest sources)

> Phase-gated per CLAUDE.md §5: phases sequential + verified; lanes within a phase parallel
> (git worktrees + subagents, non-overlapping file ownership). Every phase ends when its gate
> has live evidence, then commits + pushes to `origin/main` or a PR.

Target toolchain (LOCKED): Swift 6.4, Xcode 27-beta, SwiftPM, Sparkle 2 (self-update only),
SwiftUI window + AppKit menu-bar shell, **deployment target macOS 15.0**.

Reference implementation knowledge: `docs/MACUPDATER-BREAKDOWN.md` (mechanics with evidence).
Sources v1: cask JSON index, per-app Sparkle appcast, MAS iTunes lookup, GitHub (optional flag).

---

## Phase 1 — Scaffold (green build gate)
Gate: `swift build` green · `.app` bundle assembles · launches without crash log
- SwiftPM workspace `AppUpdater/` with targets: `AppUpdaterCore` (engine), `AppUpdaterApp`
  (menu-bar+window shell), `appupdater-cli` (scriptable surface later).
- App shell lives early but displays a stub list — no fake behavior (Honest boundary).
- CI runbook locally documented (Actions added in Phase 6).

## Phase 2 — Scanner + SourceStrategy (truth engine) — ✅ DONE 2026-10-26
Gate (met): scan your `/Applications` → JSON report of updates found, 0 false "success" claims.
Evidence: `docs/evidence/phase2-scan.json` (82 apps) + `docs/evidence/phase2-check.json` (verdict mix update/current/unknown, no fakes); full suite **82 tests / 7 suites green** at merge.
Lanes (parallel, DONE):
- ✅ **A. Scanner/AppInfo** — `Sources/AppUpdaterCore/Scan/` (enumeration, Info.plist fixups, MAS receipt detection, SUFeedURL capture)
- ✅ **B. CaskSource** — `Sources/AppUpdaterCore/UpdateSources/Cask/` (single-cask fetch + tolerant decode + honest artifact validation)
- ✅ **C. SparkleSource** — `Sources/AppUpdaterCore/UpdateSources/Sparkle/` (appcast parse, default-channel policy, EdDSA-shape confidence)
- ✅ **D. MASSource** — `Sources/AppUpdaterCore/UpdateSources/MAS/` (iTunes lookup, MAS-only guard, country=us)
- ✅ **E. VersionOracle** — `Sources/AppUpdaterCore/Versioning/` (Sparkle-style comparator + locked precedence resolver)
- ✅ **Integration** — `Sources/AppUpdaterCore/Engine/UpdateCheckEngine.swift` + `Sources/appupdater-cli/` + `Tests/AppUpdaterCoreTests/IntegrationTests.swift`
Deferred (tracked in AGENTS.md open items): cask token alias table (chrome→google-chrome), non-default Sparkle channels opt-in.

## Phase 3 — Installer (plain user-space, atomic swap) — ✅ DONE (2026-10-26, all gates proven)
Gate status: dry-run plan + honest-refusal CLI verified live on the dev machine; the FULL apply path
(download → verify×2 → backup → quit → deploy → swap → postScan) proven end-to-end on REAL disk in
hermetic fixture workspaces (backup byte-equal round-trip, identity-hijack refusal, no leftover
mounts) — applying to real third-party apps stays an explicit owner CLI action.
- ✅ **Frozen interchange types** — `Installer/InstallModels.swift` (coordinator-owned): InstallKind / InstallStep (9 locked) / InstallPlan / StepReceipt / InstallOutcome / BackupReceipt / DownloadedUpdate / DeployedBundle + honest `InstallerError`.
- ✅ **F. Download+Verify** (`Installer/Download.swift` 221L + `Checksum.swift`): HTTPS-only, hash-while-write (1 MiB chunks), Content-Length cross-check, zip PK magic, sha-less refusal = documented MISSing-EdDSA boundary (Phase 5).
- ✅ **G. Backup** (`Installer/Backup.swift`): ditto ZIP `<backupsRoot>/<sanitizedBundleID>/<isotoken>-<name>.zip`, same-second collision suffixes, unzip -l listing verification + byte-size checks, `keepLatest(_:)` name-token retention, restoreHint.
- ✅ **H. Deploy+Swap** (`Installer/Deploy.swift` + `JMSU.swift`): zip ditto-extract / dmg hdiutil attach→ditto-out→detach-on-every-path; JMSU swap with documented divergences (no chown [root-only], probe-first quarantine release, root-mtime preservation, old copy retained at `~~~appupdater-old~~~`); identity-hijack guard BEFORE any rename; hard rollback on move-in failure.
- ✅ **I. Quit+Relaunch** (`Installer/AppQuit.swift`): `RunningRef` value seams (NSRunningApplication never crosses a seam), graceful-only terminate + absence poll (200 ms), timeout is the honest error, relaunch via NSWorkspace.openApplication; force escalation documented as a Phase-7 lane topic.
- ✅ **J. Coordinator** (`Installer/InstallPlanner.swift` pure + `Installer/InstallCoordinator.swift` + `Tests/InstallCoordinatorTests.swift`): receipts per ATTEMPTED step, abort-at-first-failure, INDEPENDENT sha256 re-verify (defense in depth), old-copy Trash disposition (injectable; default trashItem), per-apply staging workspace hygiene, postScan = direct Info.plist read; CLI `install` (dry-run plans + `--apply` real executor wiring; target discipline: exactly one --apps match; refusal exits touch nothing).
Evidence (this session): • merged main = `79f8f8a`/`146299f`/`a10cc38`/`8207142` + lane commits `8813768`/`35b3f5f`/`6eeb8e7`/`e8bfde4` • `swift test` 137 tests / 13 suites exit 0 (incl. real-disk zip+dmg apply with dmg-mount leak assert) • live /Applications runs: `docs/evidence/phase3-scan.json` (82 apps), `phase3-check.json` (Ghostty=update, MacUpdater=current, AdGuard/Chrome=unknown), `phase3-installplan.json` (Ghostty → real 9-step dmg plan) • honest refusals: `--apply` zero-match → exit 2; current-verdict → exit 3; `~/Library/Application Support/AppUpdater` verified ABSENT after both (refusals create nothing) • bundle/sign/launch gate green.

## Phase 4 — Scheduler + UI surface (OPENED 2026-10-26)
Gate: scheduled scan triggers on timer + missed-scan catch-up; list/filter/ignore; auto-update rules
- Idle/energy-aware scheduling; per-app/per-version ignore; menu-bar + window live data;
  notifications; distributed notification for scriptability (custom names documented).
- Lane split (4 parallel worktree lanes per protocol §5): L1 scheduler engine (Timer/catch-up seams),
  L2 ignore-rules + list store, L3 menu-bar live data wiring, L4 window list UI. Shared models are
  coordinator-owned: `Model/ScheduleStore.swift` frozen contract BEFORE lanes dispatch.

## Phase 5 — Self-update (Sparkle 2)
Gate: appcast + EdDSA-signed artifact verified by sparkle CLI; signed by available identity
(personal-use signed; notarization slot documented for future).

## Phase 6 — Engineering hygiene + release plumbing
Gate: swiftlint (install pending) + tests + CI pipeline + release checklist
- Manual codesigning runbook; distribution channel placeholder (later Developer ID).

## Phase 7 (parallel lane, threat-model-reviewed) — Privileged helper
Gate: threat-model review doc approved by owner BEFORE code; SMAppService daemon; PKG path;
password-less installs; FDA/MDM notes like the data model. Owner-directed lane: may run
in a worktree concurrently with earlier phases while core lanes progress; considered part of the
product only after its review gate.
