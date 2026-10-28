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

## Phase 4 — Scheduler + UI surface — ✅ DONE (2026-10-26, gates proven; deferred notifications + open-item lanes CLOSED in the follow-up close-out, same day)
Gate status: scheduled fires + missed-scan catch-up + per-app auto-check rules + BOTH UI surfaces
(menu-bar + window) live on the real machine. LOCKED boundaries restated in code: auto rules govern
CHECKS + NOTIFICATIONS ONLY — auto-apply is never released; "Install Now" stages the exact owner-run
CLI command (pasteboard + verbatim text) and the app itself executes nothing. Real `install --apply`
stays the per-app owner CLI action (consent boundary, unchanged from Phase 3).
**Close-out addendum (2026-10-26, later session):** the deferred notifications item + the three
tracked open-item lanes (caskalias / channels / retention) all merged; union 227 tests / 20 suites
×3 back-to-back + ×2 concurrent, lint 0 errors, live-launch + CLI gates re-proven. Full evidence
narrative: `docs/archive/AGENT_LOG.md` close-out entry.
- ✅ **Frozen interchange types** — `Model/ScheduleStore.swift` (coordinator-owned, committed BEFORE
  lanes dispatched): SchedulePolicy (interval / skipOnBattery / onWakeCatchUp, floor+off clamped by
  `RuleStore.clamped`) / ScheduleState (lastFireAt, appsChecked, wasCatchUp, error) / ScheduleSnapshot /
  AppRow / IgnoreRule / RuleKind / RuleDecision.
- ✅ **L1 scheduler engine** (`Schedule/ScheduleEngine.swift`, lane `1755a5c`, merge `57110a0`):
  framework-pure loop (no AppKit, no persistence — a TRIGGER, not a store/filter), injected clock +
  on-wake seam, battery skip via IOKit (suppresses catch-up, never corrupts the grid), catch-up fires
  exactly once per missed persisted slot, policy captured once per stream (change ⇒ restart).
  **Live-evidence fix at reconciliation:** a FIRST-EVER fire (persisted `lastFireAt == nil`, nothing
  missed) now fires IMMEDIATELY as a NORMAL fire (`lastFireWasCatchUp = false`) instead of wearing a
  phantom "wake catch-up" label the app had printed after a fresh launch.
- ✅ **L2 rules store** (`Schedule/RuleStore.swift`, lane `d92567f`, merge `9c48fcc`):
  ignoreBundle / ignoreVersion / setAutoCheck with honest persistence (read-only env never creates
  anything; missing → absent truth; garbage → defaults + documented log line; next save replaces it;
  atomic staging writes; JSONEngine `.prettyPrinted`/`.sortedKeys` round-trip).
- ✅ **L3 menu-bar data** (`UI/MenuData.swift`, lane `87599b3`, merge `ebd97b6`): PURE transform
  (rows, snapshot, now) → headline / pending / schedule sections + counts, deterministic (same inputs
  ⇒ equal data). Refuses to guess the "up to date" classification — coordinator-owned answer: only
  `verdict == "current"` rows count (rule-muted claims excluded).
- ✅ **L4 window list VM** (`UI/ListViewModel.swift`, lane `2bf27de`, merge `80b700b`): `@Observable`
  state machine (Observation-only, no SwiftUI), single pipeline order (query → filter → sort), stats,
  selection. **Merge-time promotion (recorded):** the seam-injected init went `internal` → `public`
  because the app shell lives OUTSIDE core (no `@testable`) and the class doc's own MERGE REQUIREMENT
  names exactly this wiring from outside.
- ✅ **Coordinator wiring at merge:** `Schedule/ScheduleFileStore.swift` + 6 tests — schedule.json
  persistence EXISTS now (lane 2 deliberately left it unbuilt; coordinator picked it up, mirroring
  RuleStore's honesty contract verbatim; payload = the frozen `ScheduleSnapshot`, load re-clamps); 
  `AppState.swift` orchestrator (engine stream lifecycle persisting every snapshot, honest count
  semantics: `ids == nil` fire = scan-only inventory refresh, ZERO source lookups, returns inventory
  count; with ids = targeted checks returning the targeted count; manual Check Now refreshes the list
  but NEVER touches ScheduleState — scheduled fires only); `SeamRouter` nested bridge documented as the
  workaround for this toolchain's rule that init-scoped closures cannot capture even a weak
  partially-initialized `self`; `MenuBarView` / `MainWindowView` (search/sort/filter/selection,
  detail pane with rules incl. autoCheck toggle + Remove All Rules + CLI-command staging, honest
  error banner — no alert API) / `ScheduleSettingsView` (interval picker Off/15/30/60/120/240/480 +
  toggles, nearest-snap draft loading, Apply clamps → persists → restarts the stream); dynamic
  menu-bar title shows the pending count ONLY when nonzero.
- ✅ **Cross-process fixture flake root-caused + FIXED** (reconciliation): suites wiping a FIXED
  shared temp root in `init()` erased a CONCURRENT `swift test` runner's fixtures mid-flight
  (observed during 4-lane fan-out: `hdiutil attach failed`, `bundle.zip: No such file`). All four
  sites (`DeployTests`, `InstallCoordinatorTests`, `IntegrationTests`, `RuleStoreTests`) now use a
  per-PROCESS unique root (static UUID name, per-test wipe kept); `DownloadTests` verified safe.
  Proof: `swift test` ×3 back-to-back green AND two CONCURRENT full runs both green, 0 failures.
- ✅ **Evidence (this session):** lane + merge commits above onto local main • `swift test` 196 tests /
  18 suites exit 0 (190 previous + 6 `ScheduleFileStoreTests`; run ×4 total incl. the definitive
  close-out run, + 2 concurrent green) • live /Applications runs: `docs/evidence/phase4-scan.json`
  (82 apps), `phase4-check.json` (Ghostty=update 1.3.1, MacUpdater=current, AdGuard/Chrome=unknown —
  verdict honesty unchanged), `phase4-installplan.json` (Ghostty → real 9-step dmg plan,
  `applied: false`) • refusals re-proven: `--apps DoesNotExist123 --apply` → exit 2, `--apps
  MacUpdater --apply` → exit 3 (verdict `current`, no newer claim), `~/Library/Application
  Support/AppUpdater` unchanged by both (refusal exits write no output file — exit precedes any
  artifact by design) • bundle/sign/launch gate green
  (make-app release, codesign strict OK, plutil OK) • LIVE APP: fresh launch with schedule.json
  deleted → first-ever fire recorded `lastFireWasCatchUp: false`, `lastFireAt` set, appsChecked=82,
  no error, app scanned the REAL /Applications (82 apps) autonomously; clean quit; 0 crash reports.
- ⬜ **OPEN within this phase (honest, not claimed done):** local notifications and the
  distributed-notification surface for scriptability are NOT implemented (no scheduler-triggered
  banner exists; the distributed custom-name feature likewise). These were scheduled inside Phase 4
  but remain undone now that the engine/UI gates are green — they carry forward as named open items
  in AGENTS.md and stay on the clock; no part of the completion claim above covers them.

## Phase 5 — Self-update (Sparkle 2) — ✅ DONE (2026-10-26, gate proven)
Gate: appcast + EdDSA-signed artifact verified by sparkle CLI; signed by available identity
(personal-use signed; notarization slot documented for future).
Gate status: **MET with live evidence.** Sparkle 2.10.1 pinned via SwiftPM (exact version;
`AppUpdaterCore` stays dependency-free; only the app target depends on Sparkle).
- App wiring: `SelfUpdateCoordinator` (`SPUStandardUpdaterController`, long-lived) + menu-bar
  "Check for Self-Update…" action; automatic checks hard-off (`SUEnableAutomaticChecks=false` —
  no hidden network); `SUFeedURL` defaults to an honest `.invalid` placeholder (checks fail with
  unreachable-host, never fake success); `SUPublicEDKey` baked in.
- Bundle: `Sparkle.framework` embedded by `make-app.sh` (+ `@executable_path/../Frameworks` rpath
  added pre-sign; nested adhoc signing order framework→app); app + framework both strict-sign-valid;
  live launch with the Sparkle engine running: no crash, clean quit, 0 crash reports.
- Signature chain PROVEN (`docs/evidence/phase5-sparkle-verify.txt`, `phase5-appcast.xml`):
  `sign_update -p` signature → `sign_update --verify` exit 0 → tampered signature exit 1
  ("failed to pass signing verification") → `generate_appcast` independently derived the IDENTICAL
  signature. Private key: login keychain only (never in repo); public key committed by design.
- Runbook: `docs/RELEASE-PLUMBING.md §1b` (per-release pipeline + keychain-ACL operational fact +
  CI note). Full suite stayed green through the integration (227 tests / 20 suites, lint 0 errors).
- Honest boundary: no update SERVER exists yet (owner hosts the appcast when ready; feed URL is
  env-overridable); notarization remains the documented future slot until Apple Developer enrollment.

## Phase 6 — Engineering hygiene + release plumbing
Gate: swiftlint (install pending) + tests + CI pipeline + release checklist
- Manual codesigning runbook; distribution channel placeholder (later Developer ID).

## Phase 7 (parallel lane, threat-model-reviewed) — Privileged helper
Gate: threat-model review doc approved by owner BEFORE code; SMAppService daemon; PKG path;
password-less installs; FDA/MDM notes like the data model. Owner-directed lane: may run
in a worktree concurrently with earlier phases while core lanes progress; considered part of the
product only after its review gate.

## Phase 8 — Competitor gap closure (GAP-ANALYSIS Tier 1) — ✅ DONE 2026-10-27
Gate: 352 tests / 27 suites + swiftlint 0 errors in main after EVERY merge; live-network
evidence per gap in `docs/evidence/gap-sprint-2026-10-27.txt`. Method: six lane worktrees +
subagents (sole file ownership), coordinator-owned shared-file glue, ff-merge after rebase.
- **#1 Whole-index cask** (`2e2dec2`): ETag-cached `cask.json` (~19 MB, decode-before-persist,
  stale-serve on network failure), alias-free artifact matching (token → artifact-name) retiring
  the CaskAliases table; per-token pipeline survives as `CaskDocumentClient` fallback.
- **#2 Manual per-app sources** (`1e53589` seam + `5381b7d` store/sheet + `52d9d9a` wiring):
  github-repo or cask-token pins in `manual_sources.json`; MANUAL-OVER-BUILTIN (lock 11) via
  the engine's `ManualSourceResolver`; SwiftUI sheet + toolbar pin button.
- **#3 GitHub Releases source** (`ae7132e`): `/releases/latest` with body-verbatim ETag cache,
  bounded harvest from the app's own `sparkleFeedURL` (github/raw hosts only), pinned-init for
  manual pins, rate-limit honesty, asset pick dmg>zip / arm64-first, `<name>.sha256` sidecar.
- **#4 Electron source** (`59f0438`): `app-update.yml` + read-only asar fallback; `.unknown`
  lane oracle-gated strictly-newer-only (lock 12); SHA-512-only honesty clause in sourceDetail.
- **#17 FSEvents inventory monitor** (`a25094a`): debounced scan-root monitor; scan-only scope
  guard (lock 13); UseCFTypes deviation approved (brief's None+CFArray = proven live crash).
- **#18 Custom scan locations** (`66a0399`): bookmark-backed `scan_locations.json`,
  /Applications always scanned + customs added, settings pane, CLI parity (custom roots only
  when no `--dir` given).
- **Coordinator core**: VersionOracle unknown-branch strictly-greater amendment (`5d82814`);
  UpdateCheckEngine `ManualSourceResolver` seam (`1e53589`); AppState/MainWindowView/CLI
  integration (`818678d`, `52d9d9a`).
- **Live proof**: real-binary probes cmux / Hex Fiend / Chrome / Notion / Capy / Linear / Orca /
  Superset / GooeyPi / Traycer (update + current + gate + no-fall-through + harvest cases all
  exercised); whole-index cache + weak-ETag verbatim on real disk. Deferred (honest): manual-pin
  live e2e (no CLI pin verb — hermetic seam tests cover), network-volume bookmark live check.
Tier 2 gaps remain queued; the two watch items stay deferred per owner directive.

### Phase 8 addendum — staged-PKG owner command (2026-10-28, `94bfd25`)
GAP #11's STAGING half, shipped with zero standing privilege: `.pkg` joined `InstallKind` as
the staged-owner-command kind. Pkg plan = download → verifySha256 → verifyArtifactMagic
(xar! gate) → stageOwnerCommand — NO backup/quit/deploy/swap/relaunch/postScan/retention.
Security floor unchanged (HTTPS + sha256 still required; refusals exit 3). Verified pkg
bytes land in PERSISTENT staging (`Application Support/staging/staged-pkg/apply-<uuid>/`,
deliberately outside the per-apply workspace cleanup — the pkg must survive the run), and
the REAL owner-run command (`sudo installer -pkg "<path>" -target /`) is recorded in
`InstallOutcome.stagedCommand` (plan carries the `<staged-pkg-path>` template); the CLI
prints it to stderr after green staging (stdout stays pure JSON; exit 0). AppUpdater NEVER
executes installer(8) — the install is always the owner's hand action, matching
PRIVILEGED-HELPER-REVIEW §5b recommendation 4. Gate: 357 tests / 27 suites, swiftlint 0.
The daemon half (password-free installs) stays parked pending owner sign-off + Developer ID.
