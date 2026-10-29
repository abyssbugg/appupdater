# Project Rules (ALWAYS LOAD)

You are working in the **AppUpdater** project. This file is the canonical continuity contract for every coding-agent session started in this directory, whatever the agent (Claude, Grok, Codex, ZCode, droid, or other). Read it fully before acting — **together with `CLAUDE.md`, which holds the binding Operating protocol (HOW to work)**. Treat locked decisions as ground truth. If a request conflicts with them, flag the conflict and wait.

**CRITICAL: You must open and read the contents of `CLAUDE.md` before writing any code.**

**Full work history (verbatim):** `docs/archive/AGENT_LOG.md`. Completed entries retire there; this file stays lean.

---

## Project identity

| Field | Value |
|---|---|
| **Name** | **`AppUpdater`** |
| **Local path** | `/Users/datamatics/dev/appupdater` |
| **Canonical remote** | `github.com/abyssbugg/appupdater` (PRIVATE — created 2026-10-26; source of truth for pull/push) |
| **Live surfaces** | none yet (planned: signed/notarized macOS app; self-updates via Sparkle appcast; no owner-operated server required for v1) |
| **Phase** | prototype (code build starting; analysis phase complete) |
| **Owner intent** | hybrid macOS app updater combining MacUpdater's execution engine (scan, one-click install, backups, privileged install path, scheduler) with Updatest's serverless source strategy (public cask index, app's own Sparkle appcast, GitHub/Electron, App Store lookup). For the owner AND public release. |

---

## Non-negotiable decisions (LOCKED)

1. **Project name is `AppUpdater`.** Bundle ID proposal `io.appupdater.AppUpdater` (adjustable only before first signed release). Owner accepted 2026-10-26.
2. **Scope BOTH:** app updates *other* installed apps AND self-updates via Sparkle. Locked 2026-10-26.
3. **Architecture HYBRID:** MacUpdater execution engine + Updatest source strategy, one app. Locked 2026-10-26.
4. **Mac App Store apps BOTH modes:** inform-only display AND a force-update path including MAS→vendor-download replacement. Locked 2026-10-26.
5. **Audience BOTH:** private use and public release → build code-signable/notarizable from day one; zero hard dependency on an owner-operated server; public data sources first. Locked 2026-10-26.
6. **Security floor:** HTTPS-only downloads; SHA-256 (or EdDSA-signed artifact) verification before replace; EdDSA (`SUPublicEDKey`) for our own updates; root operations only via SMAppService-style daemon (never `AuthorizationExecuteWithPrivileges`). Locked 2026-10-26. **Auth-touching code gets a threat-model review before implementation (CLAUDE.md §7).**
7. **Not building UI before scan/update pipeline core is real.** Engine-first phase order. Locked 2026-10-26.
8. **Stack freeze:** Swift 6.4, Xcode 27 project toolchain, SwiftPM dependency management; app dependency: **Sparkle 2** (self-update only); UI: SwiftUI window + AppKit menu-bar shell (LSUIElement); **deployment target macOS 15.0**. Locked 2026-10-26 (owner answering 4-question gate).
9. **Signing mode:** personal-use ad-hoc signing for local builds AND for public GitHub Releases distribution (v0.1.0 published 2026-10-27 with the Gatekeeper first-launch caveat documented in its notes). **Notarization explicitly ABANDONED for now — owner directive 2026-10-27** ("let's forget and abandon notarization for now"); no distribution claims beyond the documented unsigned-app caveat. Developer ID/notarization becomes relevant only if the owner later enrolls (optional, not planned). Locked 2026-10-26; amended by owner 2026-10-27.
10. **Parallel-work discipline (owner-directed):** use git worktrees + subagents to cover independent lanes and never let the privileged-helper path slow core progress — but strictly per CLAUDE.md §5: phases sequential, lanes parallel, non-overlapping file ownership, verified-before-done. No unprofessional race-to-clone. Locked 2026-10-26.
11. **Manual-over-builtin (gap sprint):** a per-app manual pin (`manual_sources.json`, github repo or cask token) is an owner attestation — the engine consults ONLY the pinned source for that app; built-ins are never queried for it and a pin's throw is recorded verbatim with NO silent builtin fallback. The pin's claim still passes the standard strictly-greater gate at resolve time, so a pin never manufactures an update the installed version refutes. Locked 2026-10-27.
12. **Electron claims stance:** Electron-derived claims (app-update.yml / asar / latest-mac.yml) are least-trusted (`.unknown`): consulted only when NO cask/sparkle/mas/github candidate exists for the app AND only when strictly newer than the installed version (equal/older — e.g. vendor republish, "0.0.0" probes — never surfaces). Installs from them stay out of scope (SHA-512-only upstreams): info + manual staging only. Locked 2026-10-27.

14. **Auto-apply consent boundary (AMENDED 2026-10-28, owner hybrid decision):** the app's DEFAULT remains click-driven — nothing auto-applies unless the owner opts in. Opt-in per-app auto-apply is now authorized with MacUpdater's safety gates, for USER-SPACE updates only (zip/dmg via the existing verified install chain): a global master switch (default OFF) AND per-app opt-in (default OFF) must both be on; PKG/privileged paths are NEVER auto-applied (staged owner commands only, unchanged); every auto-apply produces full verbatim receipts; all of MacUpdater's exclusion gates apply (battery, offline, running-app quit flow — reused unchanged). This amends the earlier "never auto-applies" boundary; the older docs phrase it as the pre-amendment rule.
13. **FS events = inventory re-scan only:** an FSEvent on a scan root may refresh the installed-apps list; it NEVER triggers source checks, notifications, schedule mutation, or installs. The scheduled engine stream remains the ONLY automatic check path. Locked 2026-10-27.

Add locks as they are decided. Remove a lock only when the owner supersedes it in writing here and in `docs/archive/AGENT_LOG.md`.

---

## Operating protocol (HOW to work — BINDING, lives in `CLAUDE.md`)

The full operating protocol lives in **`CLAUDE.md`** and is binding for every session, every agent: sequential-thinking decomposition before code, deliberate tool selection, comprehension before change, no bug-on-bug patching, phase-sequential / subagent-parallel execution, the verification gate, and honest reporting.

**CRITICAL: You must open and read the contents of `CLAUDE.md` before writing any code.** This file (AGENTS.md) is the WHAT — locked facts, gotchas, open items; CLAUDE.md is the HOW.

---

## Product model (what we build)

```
User → AppUpdater.app (menu-bar app + window, LSUIElement)
     → ScanEngine (enumerate /Applications + custom folders, Info.plist with fixups)
     → SourceStrategy (MAS receipt+iTunes lookup → cask JSON index → app's own Sparkle
       appcast → GitHub releases → [opt-in, later: Electron endpoints / vendor scrape])
     → VersionOracle (Sparkle-style comparator + special cases)
     → Installer (download HTTPS → verify SHA-256/EdDSA → backup DMG/ZIP → quit-running-app
       flow → atomic swap JMSUPlainInstaller-style → relaunch → post-scan)
     → Optional privileged daemon (SMAppService, phase 2) for PKGs + password-less installs
     → Self-update (Sparkle 2 appcast + EdDSA signing in release pipeline)
```

- Product class: macOS maintenance/update manager. Reference products: MacUpdater 3, Updatest 3.
- Honest boundary: shows truthful newest-version data from live public sources; no fake "success"; apps we cannot verify are labeled unknown, never guessed.
- Deep architecture + field evidence: `docs/MACUPDATER-BREAKDOWN.md`.

## Out of scope

- No vendor-specific autoupdater interference list hacks in v1 (Adobe/BattleNet-style built-in updaters are skipped, not fought).
- No scraping tier in v1 (deferred until public sources exhausted).
- No iOS/iPadOS support; macOS only.

---

## Continuity rules for every new session in this folder

When the user says "continue" / resumes work here:

1. **Assume this AGENTS.md + `docs/` are ground truth.**
2. Restate locked decisions briefly only if the user seems lost — do not re-litigate them.
3. Honor every LOCKED item. Flag any request that would break one.
4. Ship engineering; the owner owns product-source and vendor decisions called out as locked.
5. Keep this file current: when decisions change, update it; when work completes, retire its entry to `docs/archive/AGENT_LOG.md`; promote any new durable gotcha into the ledger below. Never delete history silently.
6. Before major architecture changes, update `docs/MACUPDATER-BREAKDOWN.md` (or successor arch doc) and record the decision here.

Resume = open an agent in the **Local path** above and say "continue". Pull first — once a remote exists, it is the source of truth; local clones are mirrors.

---

## Docs map (in-repo)

| Area | Files |
|---|---|
| **Ops / env** | Hardware/toolchain facts: this file §Verification gate + `docs/archive/AGENT_LOG.md` device section |
| **Architecture / contracts** | `docs/MACUPDATER-BREAKDOWN.md` (§3 combined design; evidence-annotated) |
| **Data / pipelines** | Source endpoints + schemas documented inside MACUPDATER-BREAKDOWN §1–2 |
| **Policy** | Locked decisions above; security floor; CLAUDE.md protocol |
| **History** | `docs/archive/` (superseded planning docs + **AGENT_LOG.md** = full work log) |
| **Human status** | `README.md` |

Point at files that exist. A missing doc is a gap to flag, not a file to invent mid-task.

---

## Verification gate

The standing gate CLAUDE.md §6 requires. Copy-paste commands only. **All lines below have live evidence from the most recent session (2026-10-27 audit: every line re-run independently on main as-is — 227 tests / 20 suites green, swiftlint 0 error-severity hits, bundle assembled + strict-signed + plutil-OK + live launch clean-quit + 0 crash reports, refusals byte-identical, and the Sparkle EdDSA chain re-proven BOTH ways: recorded zip deterministic-signature match + verify exit=0, and today's rebuilt bundle fresh-signed verify exit=0 / tamper exit=1. Full verbatim log: docs/evidence/audit-2026-10-27.txt).**

```
swift build                                    # PROVEN exit=0 (close-out union)
swift test                                     # PROVEN 227 tests / 20 suites, exit=0 (×3 back-to-back stability runs)
                                               # PLUS: 2 CONCURRENT full swift test runs both green, 0 failures (flake-proof protocol)
swiftlint lint                                 # PROVEN 0 error-severity hits (lint gate REAL: swiftlint 0.65.1, calibrated .swiftlint.yml)
Scripts/make-app.sh release                    # PROVEN "Assembled: build/AppUpdater.app"
codesign -v --strict build/AppUpdater.app      # PROVEN OK (adhoc)
plutil -lint build/AppUpdater.app/Contents/Info.plist   # PROVEN OK
launch: open build/AppUpdater.app && pgrep -fl 'AppUpdater$'   # PROVEN launch observed; FIRST-EVER schedule fire honest: schedule.json written with lastFireWasCatchUp=false, lastFireAt set, appsChecked=82; clean quit; 0 crash reports
swift run appupdater-cli scan                  # PROVEN 82 apps inventoried from real /Applications (docs/evidence/phase4-scan.json)
swift run appupdater-cli check --apps MacUpdater,AdGuard,Chrome,Ghostty   # PROVEN honest verdicts (Ghostty=update 1.3.1, MacUpdater=current, Chrome=current via the new cask alias table, AdGuard=unknown honest pkg-cask refusal) (docs/evidence/phase4-check.json)
swift run appupdater-cli install --apps Ghostty --out docs/evidence/phase4-installplan.json   # PROVEN real 9-step dmg plan, applied:false (dry-run)
swift run appupdater-cli install --apps MacUpdater --apply   # PROVEN honest refusal exit=3 (verdict 'current'); --apps DoesNotExist123 --apply → exit=2; refusal runs write no output file — exit precedes any artifact by design
Scripts/make-app.sh release (Phase 5)          # PROVEN Sparkle.framework embedded + rpath + SUFeedURL/SUPublicEDKey/SUEnableAutomaticChecks=false; app+framework strict-sign valid; live launch with Sparkle engine: no crash, clean quit
sign_update --verify (Phase 5)                 # PROVEN exit=0 on the signed artifact (docs/evidence/phase5-sparkle-verify.txt); tampered signature → exit 1; generate_appcast independently derived the SAME signature (docs/evidence/phase5-appcast.xml)
```

- swiftlint IS NOW INSTALLED and calibrated (`.swiftlint.yml`): style = warnings; the ERROR column is force_cast / force_try / force_unwrapping — **0 errors proven**. The old "not installed" debt line is retired.
- `install --apply` on a REAL app with an accepted plan is the owner-run destructive boundary: the autonomous gate proves refusal paths + dry-run only; full apply execution is proven in hermetic real-disk fixture tests (`InstallCoordinatorTests`, temp workspaces, never /Applications, user's real Trash never touched).
- A change is done when every line of this gate has evidence from this session. Anything skipped is **unverified**.

---

## Gotcha ledger (read before touching the matching area)

```
- **"Sourcery" is a NAME COLLISION — this project means Sourcery AI (2026-10-27)** — the brew formula `sourcery` (Krzysztof Zabłocki's Swift code-generation tool) is NOT what the owner asked for: the owner's tool is **Sourcery AI**, the code-security/review SaaS, integrated via its MCP server (`sourcery_list_findings` / `sourcery_security_snapshot` / SAST-IaC-secrets-dependency findings). The wrong tool was installed 2026-10-26 (config + empty templates dir committed), caught and removed 2026-10-27 (owner uninstalled the brew binary; `.sourcery.yml` + `Scripts/SourceryTemplates/` deleted). Never `brew install sourcery` in this repo; the MCP tools are the integration surface. Evidence: `docs/RELEASE-PLUMBING.md §4` correction block.
- **CircleCI macOS: resource-class names move fast (2026-10-27)** — `macos.m1.medium(.gen1)` classes hit END OF LIFE 2026-02-16, Intel classes were removed mid-2024, and current macOS classes are BARE names without the `macos.` prefix (`m4pro.medium`, `m4pro.large`); `macos.m4pro.medium` is itself invalid. The scheduler's 0s rejection says "…not available for your project… if the pricing plan does not support macos use" — GENERIC BOILERPLATE that misleads toward plan debugging while the real cause is a retired class name. Hosted Xcode pins also age: 16.4.0 ships Swift tools 6.1, which fails Package.swift's `swift-tools-version:6.3.0` — pin `xcode: 27.2.0` (Swift 6.4.2, macOS 26.6.2, classes m4pro.medium/large). Also: `circleci run trigger` is NOT supported for GitHub-App projects (UI/trigger-event runs only). Evidence: runs #1–#6 verbatim messages in docs/evidence/audit-2026-10-27.txt; first green = "Test run with 227 tests in 20 suites passed" on commit `1bab61b`.
- **Sparkle 2 integration facts (Phase 5)** — (1) `SPUUpdater.checkForUpdates()` is NILARY in the Swift 2.x bindings — the ObjC-style `checkForUpdates(nil)` fails to compile ("argument passed to call that takes no arguments"). (2) SwiftPM-linked `Sparkle.framework` binaries carry NO usable `@executable_path` rpath: `make-app.sh` must `install_name_tool -add_rpath @executable_path/../Frameworks` BEFORE signing (adding an rpath invalidates an existing signature). (3) The first keychain-backed `sign_update` blocks on a SecurityAgent prompt — headless runs hang until "Always Allow" is clicked (or the pipeline switches to `--ed-key-file` with a protected key file outside the repo). Evidence: Phase 5 close, `Scripts/make-app.sh`, `docs/RELEASE-PLUMBING.md §1b`.
- **Async-stream snapshot tests: "side effect happened" ≠ "snapshot arrived"** — `waitUntil(fireCount == N)` proves the fire SEAM returned, but the post-fire snapshot is emitted to the AsyncStream and consumed by a SEPARATE collector task; reading `collector.states.last` immediately wins that race under parallel-suite CPU load (observed once in the wild: `normalTickFireRecordsListAndCount` read the stale policy-load snapshot — `lastFireAt = epoch−1min`, nil count/catchUp — and failed; passed on rerun + isolated). Fix: wait for the SNAPSHOT ARRIVAL (`waitUntil(run.collector.states.count >= N)`) before any read — the pattern `snapshotsYieldInitialAndPostFire` already used. Applied to all 7 read-sites in `ScheduleEngineTests.swift`; proven ×3 back-to-back + 2 concurrent full runs green. Evidence: close-out 2026-10-26.
- **Shared fixed temp roots in test suites = cross-process fixture collision (the Phase-4 flake)** — suites whose `init()` wipes a hardcoded `temporaryDirectory/appupdater-<name>` delete ANOTHER concurrent `swift test` runner's fixtures mid-flight (`hdiutil attach failed`, `bundle.zip: No such file`); passes in isolation, fails only under parallel runners. Root-cause evidence: overlap observed during 4-lane fan-out (`ps` samples in listvm's gate). Fix: make the suite root name unique per PROCESS (`private static let …appendingPathComponent("appupdater-<name>-\(UUID().uuidString)")` — static = computed once per process, per-test wipe semantics kept), then prove with `swift test` ×3 back-to-back AND two concurrent full runs, all green. Never name a wiped test root a constant. Evidence: Phase 4 reconciliation, `DeployTests`/`IntegrationTests`/`InstallCoordinatorTests`/`RuleStoreTests`.
- **`OSLogMessage` `'+'` interpolation-concatenation forbidden** — appending two message literals with `+` fails to compile on this SDK (OSLogMessage is not `String` Combineable). Fix: single literal, or two log calls / string building outside the logger macro. Evidence: Phase 4 rules lane (`RuleStore.swift` logging).
- **`FileHandle.write` needs the `contents:` label on this SDK** — `handle.write(data)` is rejected; write as `handle.write(contentsOf: data)`. Evidence: Phase 4 rules lane (atomic save).
- **`replaceItemAt` has no `originalItemURL` parameter on this SDK** — the API surface is smaller than older docs suggest; stage-then-swap with `FileManager.replaceItemAt(_:)`/`moveItem` without the original-item argument. Evidence: Phase 4 rules lane (rules.json atomic save).
- **`FileManager.trashItem` takes an `NSURL?` inout on this SDK** — `URL?` fails with "cannot convert value of type 'URL?' to expected argument type 'NSURL?'". Fix: `var destination: NSURL?` then `(destination as URL?)?.path`. Evidence: Phase 3 close, `InstallCoordinator.trashDisposition`.
- **Binary HTTP fixtures need a Data-native URLProtocol** — String-based stubs (like IntegrationTests') round-trip arbitrary bytes through UTF-8 and silently corrupt dmg payloads; anything binary must stub `Data` bodies + Content-Length directly. Evidence-by-design: `ApplyStubURLProtocol` in `InstallCoordinatorTests.swift` (Phase 3 close).
- **Ternary loses contextual `@MainActor @Sendable` in Swift 6.4** — `let f: T = cond ? closureA : closureB` fails with "converting non-Sendable function value". Fix: declare the constant, assign by explicit branches so each literal gets the declared type. Evidence: `fakeTerminator` in `InstallCoordinatorTests.swift` (Phase 3 close).
- **SwiftPM error output on Xcode 27-beta** — the real diagnostic hides under a giant "Failed frontend command" echo; `tail`/pipe truncation loses it. Symptom: build "fails" with no visible error line, repeated confusion. Fix: `swift build > log 2>&1; grep "error:" log`. Evidence: Phase 1 debugging round-trip.
- **XCTest discovery broken on this toolchain** — Xcode 27.0 beta / Swift 6.4: `swift test` logs "Test Suite passed" with **0 tests collected**; exit code lies green. Symptom: silent gap in coverage. Fix: write tests with Swift Testing (`import Testing`, `@Test`, `#expect`) and require a nonzero test count in gate output; also note Swift Testing does not re-export Foundation (tests need their own `import Foundation`). Evidence: `/tmp`-captured logs Phase 1; `Tests/AppUpdaterCoreTests/ScaffoldSanityTests.swift`.
- **Cross-surface edits in the app shell** — `AppUpdaterApp.swift` (scenes) and view/state files drift silently: removing `AppState.requestMainWindow()` while the scene still called it produced a misleading key-path error (`has no dynamic member … using key path`), NOT a "missing function" error. Fix: after changing AppState's surface, grep the app target for stale call sites; prefer `@Environment(\.openWindow)` + `openWindow(id:)` over any notification relay for menu-bar → main-window opening (macOS 15). Evidence: `Sources/AppUpdaterApp/AppUpdaterApp.swift`.
- **URLProtocol stub API shrunk in macOS 27 SDK** — `URLProtocol:didCompleteWith:` no longer ships; stub completion must use `client?.urlProtocolDidFinishLoading(self)`. Symptom: ported stub boilerplate fails/warns oddly in tests. Fix: finish with `urlProtocolDidFinishLoading`. Evidence: `Tests/AppUpdaterCoreTests/MASSourceTests.swift` (lane mas, commit `79389fb`).
- **`ditto` has no listing verb** — `ditto -l` does not exist on any macOS (man page itself prescribes `unzip -l <archive>` for PKZip listing). Fix: create/extract with ditto, LIST with `/usr/bin/unzip -l`. Evidence: lane backup `35b3f5f` (Backup.swift, verified live).
- **CryptoKit alias gap on this SDK** — `CryptoKit.Insecure.SHA256` does not resolve under Xcode 27-beta ('SHA256' is not a member type of enum 'CryptoKit.Insecure'); use top-level `SHA256` (same hash; the alias is gone/deprecated). Evidence: lane download `8813768` (Checksum.swift, probed standalone).
- **URLProtocol stubs need a no-op `stopLoading()` override** — custom URLProtocol classes without `override func stopLoading() {}` crash test teardown (`*** -stopLoading only defined for abstract class`, signal 6, whole run dies). Symptom: tests green, then CFNetwork teardown kills the runner. Fix: implement the empty override in every stub. Evidence: lane cask commit `a350fde`, `CaskSourceTests.swift`.
- **Swift 6.4 nitpicks** — public inits can't default-reference internal static members (add a second convenience init); static members referenced from instance context need explicit `Self.`; `Unicode.Scalar` has no `isLetter` (use `CharacterSet.alphanumerics`). Evidence: lane cask `a350fde`.
- **SPM scratch path quirk on this machine** — Xcode-beta toolchain writes intermediates to `.build/out/*` but final products remain at the standard `.build/<config>/AppUpdaterApp`; `Scripts/make-app.sh` relies on the standard path. If a future Xcode drop moves products, make-app.sh is the first thing to check. Evidence: Phase 1 assembly.
```

---

## Current open items

- [x] **Phase 3 (Installer) — DONE** 2026-10-26: 4 lanes (`download/backup/deploy/quitlaunch`) merged + coordinator wiring (`InstallPlanner` pure planner, `InstallCoordinator` executor composition, CLI `install` dry-run + honest `--apply`), 137 tests / 13 suites green, real-disk end-to-end (zip + dmg, backup round-trip, hijack refusal, no leftover mounts), live CLI refusals evidenced. Details + evidence: BUILD-PLAN Phase 3 block, `docs/evidence/phase3-*.json`.
- [x] **Phase 4 (Scheduler + UI) — DONE** 2026-10-26: 4 lanes (`scheduler/rules/menudata/listvm`) merged; coordinator wiring (`ScheduleFileStore`, AppState orchestrator w/ engine stream + real VM seams via SeamRouter, MenuBarView/MainWindowView/ScheduleSettingsView, dynamic menu title); live-evidence fixes (first-ever fire = NORMAL fire; cross-process fixture flake root-caused + fixed + concurrency-proven). 196 tests / 18 suites, CLI + bundle + live-launch gates green, `docs/evidence/phase4-*.json`. Details: BUILD-PLAN Phase 4 block.
- [x] **Phase 4 deferred items — CLOSED 2026-10-26:** local notifications + distributed-notification scriptability landed via `lane/notifications` (merged `22956ee`); contract notes recorded in AGENT_LOG (removal-only diffs → noChange; `wasCatchUp` honestly `"unknown"` in the distributed payload until posting moves behind the snapshot emit; settings toggle via explicit `Binding` + internal setter preserving `private(set)`; UUID identifiers per fire ⇒ no app-side dedupe in System Settings, consequence documented).
- [x] **Phase 5 (Self-update, Sparkle 2) — DONE 2026-10-26:** Sparkle 2.10.1 pinned via SwiftPM; app wiring (`SelfUpdateCoordinator` + menu action; auto-checks OFF); bundle embed + rpath + nested signing; EdDSA chain proven end-to-end (`sign_update --verify` exit 0, tamper exit 1, `generate_appcast` identical signature); key in login keychain (private half NEVER in repo), public key committed as make-app.sh default; runbook `docs/RELEASE-PLUMBING.md §1b`. No update server exists yet (owner hosts the appcast; feed URL env-overridable).
- [x] **Cask alias table (token mapping) — DONE 2026-10-26** via `lane/caskalias` (merged): `CaskAliases` built-in table, 14 live-verified tokens (chrome→google-chrome etc.), alias retry ONLY after a primary-token 404, documented refusals (bionic→lm-studio-bionic name-collision trap; tailscale→tailscale-app pkg-only). Live proof: Chrome verdict `unknown → current` in the refreshed evidence run.
- [x] **Non-default Sparkle channels — DONE 2026-10-26** via `lane/channels` (merged): `InstalledApp.suDefaultChannel` captured from Info.plist; `SparkleSource.selectAdmissible` implements Sparkle's exact-match channel semantics (declared channel joins default; case-sensitive; empty declaration = no declaration). Non-declaring apps unchanged (AdGuard nightly still honest-unknown).
- [x] **Backup retention wiring — DONE 2026-10-26** via `lane/retention` (merged): `InstallCoordinator.retentionKeep` (default 3, init-validated ≥1) prunes best-effort AFTER a fully green apply; prune failure = receipt note, never an abort; refusals never prune; `InstallOutcome.retentionNote` additive Codable field.
- [x] **swiftlint installed + calibrated — DONE 2026-10-26**: 0.65.1 via brew; `.swiftlint.yml` (style=warnings; force_cast/force_try/force_unwrapping=errors; tests excluded where the rule supports it); all 15 baseline force-unwraps fixed at root cause (AppcastParser unwrap-once, CLI errLine helper, test `#require`s), 0 errors proven. See `docs/RELEASE-PLUMBING.md §3`.
- [x] **Stack freeze** — Swift 6.4 / Xcode 27 / SwiftPM / Sparkle 2 / SwiftUI+AppKit shell / deployment target **macOS 15.0**. Owner sign-off 2026-10-26 (LOCKED decision 8).
- [x] **Canonical remote** — `abyssbugg/appupdater` private repo created + pushed 2026-10-26 (LOCKED table above).
- [x] **v1 source set** — cask JSON index + app's own Sparkle appcast + MAS (iTunes lookup) + GitHub optional-flag; Electron/scrape deferred. Evidence: live samples in `docs/evidence/`.
- [x] **Release v0.1.0 PUBLISHED — DONE 2026-10-27:** https://github.com/abyssbugg/appupdater/releases/tag/v0.1.0 (asset byte-verified against the signed build; EdDSA signature verify exit 0); feed `appcast.xml` committed at repo root and verified LIVE (HTTP 200); released build carries the live feed URL + embedded public key, auto-checks off. Receipts: `docs/RELEASE-PLUMBING.md §2b`. Next releases: `Scripts/make-release.sh <version> <build> <notes>` (shellcheck-clean, guards: build must advance vs feed sparkle:version, no duplicate tag, clean tree; `--check` dry-run validated).
- [x] **CI pipeline first green run — DONE 2026-10-27** (hosted, CircleCI-on-GitHub-App): run #6 on branch `ci/macos-fix` commit `1bab61b` — workflow `build-and-test` SUCCEEDED with "Test run with 227 tests in 20 suites passed" (verbatim match with the local gate) + lint correctness gate; merged to main `249e627`. Root cause of the earlier 0s rejections was retired resource-class names (see gotcha ledger), NOT the plan. GitHub Actions remains account-blocked (billing), workflow disabled (`disabled_manually`), and stays the fallback note in `docs/RELEASE-PLUMBING.md §5`. CodeRabbit/Codacy/Verity App bindings all confirmed the same day; Verity Standard v1 uploaded (project `5fd1fbd6-e317-4760-975d-3418a962648d`).
- [x] **Review/quality toolchain — mostly DONE 2026-10-27:** CircleCI (definition + trigger + FIRST GREEN RUN, merged to main), CodeRabbit (App installed + repo Connected; CLI path intact), Codacy (App installed + dashboard live), Verity (project registered from the owner's Abyssbugg Chrome session; Standard v1 pushed; knowledge_spec v2 filled + pushed via `9b5a537`; memory 14 nodes; git-moment gate commit,push ON; formal off — Lean absent), Sourcery = **Sourcery AI** (the security/review SaaS via its MCP server — NOT the brew codegen tool, which was a name-collision misinstall, uninstalled by the owner; `.sourcery.yml` + `Scripts/SourceryTemplates/` removed same day; findings APIs need the repo connected in Sourcery's dashboard if they return empty). Full state: `docs/RELEASE-PLUMBING.md §4`.
- [x] **Staged-PKG owner command (GAP #11 staging half) — DONE 2026-10-28 (`94bfd25`):** `.pkg`
  downloads + verifies on the UNCHANGED security floor (HTTPS + sha256, refusals exit 3; xar!
  magic gate) into PERSISTENT staging (`staging/staged-pkg/apply-<uuid>/` — survives the run,
  outside the per-apply workspace cleanup), then stages the owner-run
  `sudo installer -pkg "<path>" -target /` in `InstallOutcome.stagedCommand` (plan template +
  stderr print; stdout stays pure JSON). AppUpdater NEVER executes installer(8); no backup/
  deploy/swap/relaunch/postScan/retention on the pkg path. Gate: **446 tests / 34 suites,
  swiftlint 0**. Daemon half (password-free installs) parked per
  `docs/threat-model/PRIVILEGED-HELPER-REVIEW.md` §5b (awaiting owner sign-off + Developer ID).
- [x] **Gap-closure sprint (GAP-ANALYSIS Tier 1) — DONE 2026-10-27:** all six competitor gaps closed — #1 whole-index cask (`2e2dec2`, alias-free artifact matching; CaskAliases retired to fallback), #2 manual per-app sources (`1e53589`+`5381b7d`+`52d9d9a`, manual-over-builtin seam + sheet), #3 GitHub Releases (`ae7132e`, ETag harvest + pinned-init), #4 Electron (`59f0438` + oracle amendment `5d82814`), #17 FSEvents monitor (`a25094a`, scan-only), #18 custom scan locations (`66a0399` + glue `818678d`). Six lane worktrees + subagents, sole ownership, never pushed; full gate in main after every merge: **352 tests / 27 suites, swiftlint errors 0** (was 227/20). Live-network matrix through the real CLI (cmux, Hex Fiend, Chrome, Notion, Capy, Linear, Orca, Superset, GooeyPi, Traycer — update/current/gate/no-fall-through/harvest cases all exercised; whole-index cache 19,280,921 B + weak-ETag verbatim on disk). New locks 11–13. Evidence: `docs/evidence/gap-sprint-2026-10-27.txt`; details: BUILD-PLAN Phase 8; AGENT_LOG same-day entry. Deferred honestly: manual-pin live e2e (hermetic seam tests cover), network-volume bookmark live check. Tier 2 gaps: DONE same cycle (next item).

- [x] **Tier-2 gap sprint — DONE 2026-10-28 (5 worktree lanes + subagents, 2-slot concurrency pipeline):** actionable notifications (pure planner: exactly-one-stageable-app fires gain Open/Stage actions, consent boundary intact, passive summary preserved byte-for-byte), appcast delta parsing (SparkleDelta model verified against pinned Sparkle 2.10.1 source; exposed honestly, never installed), TM-aware backup (seam probe + exclusion xattr, never fails), Sparkle feed derivation (AppCenter/Hockey/DevMate from embedded frameworks; engine seam attempts derived feeds ONLY for apps with no declared feed, capped at 3, provenance on every claim; live sanity: The Unarchiver → updates.devmate.com/com.macpaw.site.theunarchiver.xml), scheduling depth (offline deferral gate + quiet-hours window, battery-skip semantics, additive Codable), MAS→cask adopt staging (LOCKED decision 4: refusal matrix R1–R5 + paid-MAS warning, `brew install --cask --adopt [--force]` STAGED never executed, CLI --adopt/--force consent discipline). Merges: notify-actions `4507c4a`, delta-backup `611372d`, feedderive `c94afc4`+`62f5c6f`, sched-depth `e9ef369`+`c2dc933`, brew-adopt `7cb1970`+`6c782a6`. Union gates after every merge; **446 tests / 34 suites, swiftlint 0 errors** (was 357/27). Live evidence: adopt dry-run on AdGuard records honest `not-mac-app-store`; check matrix AdGuard=unknown/Chrome=current/Ghostty=update 1.4.0/MacUpdater=current/The Unarchiver=update (`docs/evidence/tier2-check.json`). Honest leftovers: store-level ambiguity surfacing for adopt (gate tested, store resolves ties internally), per-weekday scheduling (deferred from scope), manual-pin live e2e (carried).

- [x] **Wave-2 gap sprint — DONE 2026-10-28 (3 lanes, one inherited mid-flight from the owner's session):** pkg-claim sourcing (`6481dba`, GAP #11's last mile: pkg-only casks match via strictly-gated derived-name evidence, uniqueness demanded), brew CLI remainder (`281fa8b`, GAP #2: pin watching, read-only brew doctor probe, formulae whole-index), security panel (`24fcecd`+`ff44d0e`, GAP #19: codesign/Gatekeeper/hardened-runtime inspection, CI-hermetic parse tests), deep candidate filtering (`43016bb`, GAP #14: InstallBuilder/Electron-wrong-arch/installer-bundle signals, 44 tests), storefront logic (`361c68a`, GAP #10: Setapp info-only, iOS-on-Mac, exclusion codes; 8 root-cause fixes to dead WIP), proxy subsystem (`badd914`, GAP #20: settings store + nine-key URLSession bridge + env passthrough + keychain + SCDynamicStore monitor — delivery rebuilt on SetDispatchQueue after the SDK-audit discovery). Dead OpenCode lanes finished in place per protocol §5. Union: **661 tests / 61 suites, swiftlint 0 errors**; CI green (`25443a2`). Evidence: `docs/evidence/tier2-check.json` + live adopt/check runs. Remaining known gaps: #22 hybrid auto-apply (decision locked), #25 Terminal typing, #13 vendor watch, #24 signed rules, #26 polish, dormant helper build, crowd data (permanent no-server).

- [x] **Wave-3 sprint — DONE 2026-10-28 (3 lanes, decision-14 surfaces live):** auto-apply core (`c42866f`+wiring `a711637`: 12-reason fail-closed gate, opt-in defaults, user-space-only enforcement, serialized runs, verbatim receipts incl. additive planningNote), Terminal typing (`6ad08c2`+wiring `a711637`: Terminal.app/iTerm2 dialects, adversarial quoting matrix, per-use consent click layer via NSAppleScript, CopyPaste default), vendor watch + signed rule packs (`bf99923`+merge `cc18730`: staged `open` + honest post-install watch; EdDSA-signed file-based rule packs over canonical bytes), polish (`8772e8d`+merge `1bbf53f`: dock badge + display mode with honest relaunch note, exactly-once welcome tour live-proven both ways, SettingsMigration service proven on the real machine; AppState split for lint). Union: **786 tests / 67 suites, swiftlint 0 errors**; CI green (`1bbf53f`). Remaining backlog: dormant helper build ONLY (auth-touching — frozen pending owner signature on docs/threat-model/PRIVILEGED-HELPER-REVIEW.md); crowd data + APNs are structural no-gos (no server).

- [x] **2026-10-29 coordinator audit — LOCAL-ONLY violation found + fixed; backlog corrected:** the audit above falsified this section's "dormant helper ONLY" backlog claim — it missed two real items. (1) **Local-only violation:** `docs/reverse/` (owner-local teardowns) had been committed in `4507c4a` and pushed to the public repo; untracked forward (`ba953a2`, gate 786/67 + lint 0, CI verified) + .gitignore rule; files remain on disk. **Purge EXECUTED same day (owner decision):** filter-repo stripped docs/reverse from all history, force-pushed (main + v0.1.0 + ci/macos-fix), local resynced — 0 commits touch the path on any ref, locally and (modulo GitHub SHA-cache) remotely; old→new map at `docs/HISTORY-PURGE-MAP.md`. Guard lesson: before pushing any docs-touching commit, check `git ls-files docs/reverse/` (empty = safe). (2) **Coordinator glue is UNWIRED:** symbol-level audit of app+CLI (2026-10-29) shows 0 references for SecInspector/SecReport, Storefront/SetappSupport/IOSAppOnMac, CandidateFilter, SystemProxyMonitor/ProxyConfiguration, BrewPinWatcher/BrewDoctor/BrewFormulaIndexStore — the wave-1/2 engines are built and tested but not surfaced in the app UI or CLI (AutoApply + Terminal typing ARE wired via `a711637`→rewritten per map). **§6 SIGNED (2026-10-29):** owner authorized the dormant privileged-helper build (built + tested, activation fail-closed pending Developer ID + explicit activation) — recorded in docs/threat-model/PRIVILEGED-HELPER-REVIEW.md §6. Remaining backlog: dormant helper build (now AUTHORIZED) + coordinator glue wiring.

- [x] **UI/UX parity sprint — DONE 2026-10-29 (post-audit, owner-directed):** live audit vs Updatest (screenshots + a11y trees in ~/.zcode/ui-audit-20261029/FINDINGS.md) found two P0s + parity gaps; fixed: (1) **auto-check default ON** — `RuleKind.noAutoCheck` added as the explicit per-app opt-out, `RuleDecision.autoCheck` now defaults true, `setAutoCheck(false)` persists `.noAutoCheck` (legacy `.autoCheck` opt-IN markers still honored; the app was inert out of the box before — scheduled fires "checked" nothing while the UI claimed "All N apps up to date"); auto-APPLY consent (LOCKED decision 14) untouched and still default-OFF. (2) **Honest verdict labels** — window subtitle + menu header distinguish pending / "N apps ready — run a check" / "No updates found — K of M checked" / "All N up to date"; MenuData renders "(inventoried N apps — no checks ran)" when a fire consulted no sources. (3) **Single Quit** in the status menu (dup removed). (4) **Storefront card renders user sentences only** — the engine's provenance note (internal doc citations) never renders in UI. (5) Accessibility labels on all toolbar controls. Tests updated to the new contract: **839 / 71 green, lint 0**.
- [x] **Glue wiring — DONE 2026-10-29 (dead OpenCode lane finished in place per protocol §5, EPIPE-killed finisher completed by coordinator):** all five wave engines surfaced in BOTH surfaces — security (`security <app-path>` CLI mode + SecurityPanelCard), storefront/Setapp/iOS-on-Mac (annotations in CLI reports + security card), candidate deep-filter signals (install planning), proxy (ProxySession adopts persisted settings into the app's URLSession; ProxySettingsSheet + `proxy show`), brew (BrewPinsSheet + `brew-pins`/`brew-doctor`/`brew-index`). Dead draft GlueModes.swift deleted (unused parallel generation); parseCli + glue runners extracted for lint; AppState Decision-14 surfaces moved to AppState+Decision14.swift. Union: **839 tests / 71 suites, swiftlint 0 errors**; CI green (`7c0c9f1`). BACKLOG NOW EMPTY of buildable items: the shipped product is the complete hybrid (MacUpdater engine + Updatest strategy + our stricter security floor); deferred-by-design only: helper ACTIVATION (needs Apple Developer ID enrollment + explicit owner activation — code shipped dormant), crowd data + APNs (no-server), notarization (enrollment).
- [ ] **Apple Developer Program enrollment** — owner confirmed "personal use for now" 2026-10-26. Until enrolled: local dev-class signing (`Spike0 Signing`) only; **no distribution claims**. When enrolled: Developer ID App + Installer certs, notarization joins the release pipeline. Evidence: `security find-identity -v -p codesigning`.
- [ ] **Privileged helper** — owner directed parallel coverage via worktrees/subagents (LOCKED decision 10): may run as its own concurrent lane, but is auth-touching ⇒ **threat-model review before any implementation** (CLAUDE.md §7). Landed value shows with PKG/hard cases; not a v1 blocker either way. Gate deliverable drafted: `docs/threat-model/PRIVILEGED-HELPER-REVIEW.md` — **AWAITING OWNER SIGN-OFF; no implementation may start before it is approved.**

---

## First response pattern when user continues

1. Confirm the **Name**, the LOCKED decisions in one short pass, and the current phase.
2. Point to open items and ship work — no product lectures.
3. Proceed engineering; owner owns the decisions marked locked.
