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

## Phase 3 — Installer (plain user-space, atomic swap)
Gate: dry-run mode executes a REAL low-risk update end-to-end on the dev machine; backup verified
Split (dry-run/apply is a hard interface from day 1):
- ✅ **Frozen interchange types** — `Sources/AppUpdaterCore/Installer/InstallModels.swift` (InstallKind/Step/Plan/Receipts/Outcome + honest error domain), coordinator-owned
- **F. Download+Verify** (lane/download — in flight): `Installer/Download.swift` + `Checksum.swift` — HTTPS-only, streaming sha256, zip magic, sha-less refusal (EdDSA is Phase 5's)
- **G. Backup** (lane/backup — in flight): `Installer/Backup.swift` — ditto ZIP with integrity verification + retention + restore hint
- **H. Deploy+Swap** (lane/deploy — in flight): `Installer/Deploy.swift` + `JMSU.swift` — hdiutil/ditto deploy, JMSU-style atomic swap: perms-movable → bundle-id identity guard → mtime preserve → move-old-aside rename → move-new-in → rollback on failure; quarantined xattr release documented
- **I. Quit+Relaunch** (lane/quitlaunch — in flight): `Installer/AppQuit.swift` — graceful terminate with provider seams, force-kill never silent, relaunch via NSWorkspace
- **J. Coordinator** (lane = main repo): `Installer/InstallPlanner.swift` (pure; DONE, committed: step order, security-floor refusals, downgrade/MAS/low-confidence warnings — 9 planner tests) + `Installer/InstallCoordinator.swift` (wired at merge) + CLI `install` mode (dry-run live NOW; `--apply` refuses with exit 3 until executor wiring) + real-disk end-to-end integration tests
Real-world destructive boundary (owner-decision note): applying to REAL third-party apps requires the user to run `install --apply` themselves per app; no automation does it silently.

## Phase 4 — Scheduler + UI surface
Gate: scheduled scan triggers on timer + missed-scan catch-up; list/filter/ignore; auto-update rules
- Idle/energy-aware scheduling; per-app/per-version ignore; menu-bar + window live data;
  notifications; distributed notification for scriptability (custom names documented).

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
