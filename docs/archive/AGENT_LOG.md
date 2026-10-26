# AGENT_LOG.md — full work history (chronological, verbatim-style)

Convention: newest entries on top. Entries move here from AGENTS.md when work completes.
Honesty standard (CLAUDE.md §7) applies to this log: confirmed / suspected / unverified are labeled.

---

## 2026-10-26 — Phase 4 (Scheduler + UI surface) COMPLETE — engine + rules + both UI surfaces live; notifications honestly deferred

**Confirmed (live evidence, this session):**
1. **4 parallel lanes merged sequentially** into main: rules `d92567f`→`9c48fcc`, menudata `87599b3`→`ebd97b6`, listvm `2bf27de`→`80b700b`, scheduler `1755a5c`→`57110a0`; frozen interchange types committed BEFORE dispatch (`Model/ScheduleStore.swift`, coordinator-owned, untouched by lanes). Union gate on merged main before wiring: 190 tests / 17 suites.
2. **Cross-process fixture flake root-caused + FIXED (strongest-single lesson of the phase):** four suites' `init()` handlers wiped FIXED shared temp roots (`/tmp/appupdater-lanedeploy` etc.) — one concurrent `swift test` runner deleted another's live fixtures mid-flight (symptoms during lane fan-out: `hdiutil attach failed`, `bundle.zip: No such file`; passes in isolation, breaks only under parallel runners). Fix applied at all four sites (`DeployTests`, `InstallCoordinatorTests`, `IntegrationTests`, `RuleStoreTests`): per-PROCESS unique root names (`private static let …-\(UUID().uuidString)` — static = computed once per process; per-test wipe semantics kept). `DownloadTests` re-verified safe (shared parent never wiped; per-test UUID children). **Proof protocol now codified in the gotcha ledger:** `swift test` ×3 back-to-back green + TWO CONCURRENT full runs both green, 0 failures.
3. **Coordinator pick-up (recorded):** schedule.json persistence was deliberately absent from lane rules' delivery scope — coordinator built `ScheduleFileStore.swift` (+6 honest tests: defaults-on-missing creates nothing, verbatim round-trip, garbage→defaults+next-save-replaces, load clamps via `RuleStore.clamped`, full state round-trip, impossible-path honest throw), mirroring RuleStore's contract exactly (atomic staging, read-only envs never create, documented unparseable log line).
4. **Coordinator decision at merge (recorded):** `ListViewModel`'s seam-injected init `internal` → `public` — the app shell lives OUTSIDE the core module (cannot use `@testable`) and the VM's own class doc names exactly this wiring as the merge requirement. Signature unchanged.
5. **Live-evidence fix in the engine (first-ever fire):** after wiring, a REAL fresh launch recorded `lastFireWasCatchUp: true` on the schedule's first fire — dishonest (nothing had ever been missed; the menu would print "wake catch-up for a missed slot"). Root cause: with a nil anchor, the loop's derived `nextFire(nil) == now` slot is due BY CONSTRUCTION, so the catch-up branch swallowed it. Fix: an `anchor == nil` branch fires IMMEDIATELY as a NORMAL fire (`isCatchUp: false`), unconditioned by `onWakeCatchUp`; persisted-anchor paths untouched (both `onWakeCatchUp: false` engine tests start from a persisted overdue anchor, unaffected). **Re-proven live:** rebuilt bundle, deleted schedule.json, relaunched → `lastFireWasCatchUp: false`, `lastFireAt` set, appsChecked=82 (real /Applications scan fired autonomously), no error, clean quit, 0 crash reports.
6. **App-shell wiring (coordinator-authored):** `AppState.swift` = orchestrator engine stream lifecycle (load schedule.json → publish → run stream → persist EVERY snapshot; applied policy = clamp → save → restart, policy fixed per stream) + real refresh/rule seams for the VM + honest count semantics (`ids == nil` fire = scan-only inventory refresh, ZERO source lookups in v1, returns the inventory count; with ids = targeted checks returning the targeted count) + manual Check Now does NOT touch ScheduleState (scheduled fires only) + `requestInstall` stages the owner-run CLI command (pasteboard + verbatim text, nothing executes). **New toolchain workaround banked as a pattern:** this Swift 6.4 build refuses init-scoped closures capturing even a WEAK partially-initialized `self` —solved with a nested `@MainActor SeamRouter` created before any closure exists, owner assigned as init's final statement; static factory `makeListViewModel(router:)` keeps closures self-free; method-body weak-self captures remain fine.
7. **UI surfaces (both owner-required, both live):** `MenuBarView` renders MenuData sections + coordinator-owned "current" count (verdict=="current" rows ONLY — MenuData's refuse-to-guess contract preserved) + schedule lines + honest MAS/Store note and the Install-Now-stages-CLI-command note; `MainWindowView` = search/sort/filter/selection list, detail pane (bundle ID/path/version/verdict+claim, rules section with autoCheck toggle + Remove All Rules + CLI-command staging), honest error banner (no alert API); `ScheduleSettingsView` = interval picker Off/15/30/60/120/240/480 + battery/catch-up toggles + nearest-snap draft loading (Apply re-clamps); dynamic menu-bar title shows the pending count ONLY when nonzero.
8. **Gates:** build 0; `swift test` 196 tests / 18 suites exit 0 (190 + 6 ScheduleFileStoreTests) — ×3 stability runs post-fix + definitive close-out run + the 2 concurrent greens of item 2; CLI live runs re-verified as phase4 evidence (`scan` 82 apps; `check` Ghostty=update 1.3.1 / MacUpdater=current / AdGuard/Chrome=unknown — verdict honesty unchanged from Phase 3; `install --apps Ghostty` → real 9-step dmg plan, applied:false; refusals re-proven: zero-match → exit 2, current-verdict → exit 3, Application Support dir UNCHANGED by both); `make-app.sh release` + codesign strict + plutil OK; live launch q.e.d. in item 5.
9. **Honest open items (NOT claimed done):** local notifications and the distributed-notification scriptability surface were scheduled INSIDE Phase 4 but remain unwired — surfaced in BUILD-PLAN Phase 4 block + AGENTS.md open items; they carry forward rather than ride the completion claim. Backup retention wiring also stays parked (Phase 4 product decision pending owner input).

**Phase 4 status: DONE and verified (excluding the deferred notifications items, which remain OPEN on the clock).** Next: Phase 5 (Self-update, Sparkle 2) per BUILD-PLAN when the owner resumes.

---

## 2026-10-26 — Phase 3 (Installer) COMPLETE — coordinator wiring + real-disk end-to-end green

**Confirmed (live evidence, this session):**
1. **4 parallel lanes merged sequentially** into main: download `79f8f8a` / backup `146299f` / deploy `a10cc38` / quitlaunch `8207142` (lane commits `8813768`, `35b3f5f`, `6eeb8e7`, `e8bfde4`); union gate on main before coordinator wiring: build 0 + 129 tests / 12 suites.
2. **Coordinator wiring executed at merge (lane J, main repo):** frozen `InstallModels` shapes unchanged (no lane needed a contract change) · `InstallCoordinator` composes the four executors into the locked 9-step order with receipts + abort-at-first-failure, adds the INDEPENDENT sha256 re-verify (`Checksum.sha256Hex` — second opinion over staged bytes), independent zip-magic re-check, old-copy Trash disposition (default `trashItem`, injectable; failed disposition is recorded, never downgrades a green swap), per-apply `apply-<uuid>` staging workspace removed on every outcome (backupsRoot never touched by cleanup), postScan = direct Info.plist read + finalInstalledShortVersion.
3. **CLI `install` went truthful-everywhere:** dry-run plans (Ghostty live → real 9-step dmg plan, `applied:false`); `--apply` now runs the REAL executor chain for exactly one --apps match (`--relaunch` opt-in); refusal exits (no claim → 3, plan rejected/floor → 3, target discipline → 2) touch NOTHING — `~/Library/Application Support/AppUpdater` verified absent after refusal runs. Real-app applies remain owner-run only.
4. **Full gate on merged main: 137 tests / 13 suites exit 0** (coordinator tests: real-disk zip + dmg end-to-end v1→v2, byte-equal backup restore round-trip, injected-disposition recorded old copy, post-download-mutation caught by independent verify, identity-hijack refusal preserving v1 with retained green receipts, quit-timeout abort before deploy, relaunch opener called exactly once at the victim path, InstallOutcome Codable round-trip; no `/Applications` contact, no real-Trash contact, dmg test asserts the `.dmgmount-` prefix in no `hdiutil info` line).
5. **Bundle/sign/launch gate:** `make-app.sh release` assembled; `codesign -v --strict` OK; `plutil -lint` OK; app launched live + cleanly quit; 0 crash reports.
6. Banked gotchas: `FileManager.trashItem` needs `NSURL?` inout (URL? fails); binary HTTP fixtures need a Data-native URLProtocol (String-based stubs corrupt dmg bytes); ternary loses contextual `@MainActor @Sendable` in Swift 6.4 (assign by explicit branches) — all in AGENTS.md ledger.
7. Honest notes: backup retention (`keepLatest`) landed but is deliberately NOT wired into apply (Phase 4 product decision — no silent backup deletion); postScan failing on a green swap still aborts AT postScan (verification wouldn't vouch — receipts show both truths).

**Phase 3 status: DONE and verified.** Next: Phase 4 lanes (scheduler / ignore-rules + list store / menu-bar live data / window list UI) after the coordinator commits the frozen `Model/ScheduleStore.swift` contract.

---

## 2026-10-26 — Phase 2 (Scanner + SourceStrategy) COMPLETE — engine + CLI gate green

**Confirmed (live evidence, this session):**
1. Five parallel lanes built in isolated worktrees and merged sequentially (`lane/version→scanner→cask→sparkle→mas`, commits `408412d…416f75b`); each lane gate-verified in its own worktree, then a union gate: version 36 + scanner 12 + cask 10 + sparkle 9 + mas 6 + scaffold 2 = 69…77 baseline, final full-suite **82 tests / 7 suites** after integration tests & fixes.
2. **Comparator swap at integration** (planned seam): removed SparkleSource's temporary lane-local comparator; selection now goes through `VersionOracle` (Lane E). Sparkle lane's pinned comparator cases re-run against the real comparator in `SparkleSourceTests.selectionUsesVersionOracleComparator`.
3. **Integration layer built:** `UpdateCheckEngine` (precedence-ordered sources, honest per-source failure capture, resolve via VersionOracle, deterministic input order) + `appupdater-cli` (`scan` = inventory no-network; `check` = live lookups cask→sparkle→mas with machine-readable verdicts. `UpdateCheck.verdict` made an encoded field after the live run showed JSON silently dropping the computed property.
4. **Live /Applications gate:** scan = 82 apps honest inventory (`docs/evidence/phase2-scan.json`); check run (`docs/evidence/phase2-check.json`): Ghostty = update (cask 1.3.1 beats unparseable locally-built version string), MacUpdater = current (cask 3.5.0 == installed, no inflated claim), AdGuard = unknown (cask installs via `.pkg`, no app artifact — match declined honestly; its feed is also a non-default channel), Chrome = unknown (name→token `chrome` 404; real alias `google-chrome` needs later-phase alias tables). Zero false "update" claims across the run.
5. Integration test fixes during this phase (all root-caused): `artifacts` shape used object-directive form `[{"app":...}]`; `sparkle:edSignature` is an enclosure ATTRIBUTE in Sparkle feeds (element form parsed as absent); Swift 6.4 struct deinit not allowed → recycled per-run temp dir; `URL!` IUO member poisons parameter sites; static access from instance methods must be `Self.`-qualified.

**Phase 2 status: DONE and verified.** Next: Phase 3 installer (dry-run/apply split, atomic swap, backups) per BUILD-PLAN.

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
