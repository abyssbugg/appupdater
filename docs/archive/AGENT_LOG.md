# AGENT_LOG.md — full work history (chronological, verbatim-style)

Convention: newest entries on top. Entries move here from AGENTS.md when work completes.
Honesty standard (CLAUDE.md §7) applies to this log: confirmed / suspected / unverified are labeled.

---

## 2026-10-29 — LIVE-TEST FINDINGS FIXED: invisible install refusals + Warp-class URLs + stale "Stage" labels + lying pill

**Owner report (live-testing the new build):** "apps that had new update does have the
update button but install button something is wrong." Reproduced by code-read + CLI dry
plan (the app itself never wrote staging/backups — every click was refused before the
coordinator, and the refusal was rendered NOWHERE the user could see). Four confirmed
defects, all fixed:

1. **Refusals were invisible.** `errorBanner` is an overlay on `listColumn` ONLY; the
   row Install click calls `showDetails`, navigating to the detail pane — which had no
   error surface at all (planner refusals also never populate `lastInstallOutcome`, so
   the card kept its neutral text). Plus `errorDismissed` reset only on
   `list.lastError` changes, never on `actionError` — one dismissed banner suppressed
   every future refusal. FIX: scoped `lastInstallError`/`lastInstallErrorBundleID`
   published; the installCard renders the refusal inline (red, in the pane the click
   opens); `onChange(of: actionError)` also resets the dismissal.
2. **Warp-class URLs refused with a cryptic reason.** Warp's cask claim is
   `https://app.warp.dev/download/brew?version=…&package=dmg` — `pathExtension` is
   EMPTY → "extension '.' is not installable" (an installable dmg!). FIX (engine,
   InstallPlanner.kind): when the path has NO extension, query values are consulted
   for a dmg/zip/pkg hint, including values that carry the artifact name
   (`file=Foo.dmg`); a non-empty unusable extension never falls back; a wrong hint
   still fails the security floor (HTTPS + sha256 + artifact magic) on the bytes.
   Honest refusal message rewritten for the extensionless case. +4 planner tests
   (843 total / 71 suites).
3. **Stale "Stage" labels now lied in the other direction.** Since the clicked-install
   fix the menu + notification actions REALLY install — but still said
   "Stage Install: X" / "Stage Install Command". Labels now honest: "Install X" /
   "Install Update"; MenuDataTests expectations updated (+2 notification doc comments).
4. **The pill lied on rows with no Install button.** `StatusPill` rendered "Update"
   unconditionally while the button required `updateAvailable && !isMacAppStore` —
   ignored and Store rows showed "Update" with no affordance. FIX: ignored rows show
   an "Ignored" pill (new VerdictStyle case); Store rows get a small "App Store"
   pointer button opening the detail card's explanation (MenuData parity); disabled
   in-flight buttons explain "Another install is running" in their tooltip.

Verified engines-side: CLI dry plan for Warp now yields `kind: dmg`. Gate: **843 tests /
71 suites, swiftlint 0**. Files: InstallPlanner.swift (+tests), AppState(+Install none —
state fields in AppState.swift), MainWindowView.swift, MenuBarView none, MenuData.swift
(label string only), notification action title.

---

## 2026-10-29 — OWNER-REPORTED BUG FIXED: clicked installs never installed anything (now they do)

**Confirmed (owner report + code read):** "I can't update any of the apps that say an
update is available." Root cause: `requestInstall` — the ONLY install affordance (rows,
detail card, menu, notifications) — NEVER installed anything. It built a
`swift run appupdater-cli install … --apply` STRING, copied it to the clipboard, and
displayed it; the detail card even said "the app never applies installs itself." The real
verified chain (InstallPlanner → InstallCoordinator: download → HTTPS + SHA-256 +
artifact-magic → backup → quit → swap → postScan) existed and was proven (CLI --apply,
auto-apply) but was never wired to a click. (A parallel session's transcript about this
same gap described fixes that landed as `1231519`; the findings.md it promised was never
written — verified nonexistent on disk.)

**Fix (consent-faithful):** the click IS the consent — `requestInstall` now runs that
exact in-process sequence (new `AppState+Install.swift` → `performClickedInstall`,
mirroring the CLI line-for-line including its guards and `relaunchRequested: false`). A
green user-space apply publishes the verbatim outcome (Installed ✓ + post-scan version +
backup note in the detail card); a green .pkg staging surfaces the owner-run command
exactly as before (clipboard + display; installer(8) still never executed by this app).
Serialized one-at-a-time (buttons disable + progress); refusals/aborts honest via
`actionError` + the receipt. The staged-CLI-string builder is removed as dead code — the
app now does what it used to ask the owner to type.

Gate: **839 tests / 71 suites, swiftlint 0 errors**; CI verified per push. No new tests —
the glue is thin and the underlying chain is the fully-tested coordinator surface the CLI
and auto-apply already exercise.

---

## 2026-10-29 — FINAL BACKLOG CLOSED: dormant helper (§6 signed) + glue wiring + post-close polish

**Dormant privileged helper (§6 signed → built, `0ea737f`, coordinator lane):** HelperProtocol
(versioned Codable IPC contract, typed refusal vocabulary, verbatim receipt fields, coder
seam), HelperInstallService (launchd template + SMAppService registration plan as pure DATA
— ServiceManagement never imported, no process can be spawned from this module),
HelperActivationGate (fail-closed matrix: two persisted consent switches default OFF + app
Developer-ID + helper Developer-ID; dev-class "Spike0 Signing" identity tested to be
REFUSED; every allow/refusal emits a full receipt). Built strictly more dormant than §6's
letter (no live registrar/probe — post-enrollment wiring). Gate: 829/70 (+43/+3), CI green
verbatim.

**Glue wiring (`e95edd9`+`7c0c9f1`, finished in place after the OpenCode dispatch died on
the free-usage limit — same inherited-finish pattern as wave 2; coordinator post-hoc audit
2026-10-29 CONFIRMS correctness):** all five wave engines surfaced in BOTH surfaces —
security (`security <app-path>` CLI + SecurityPanelCard), storefront/Setapp/iOS-on-Mac
(annotations in CLI reports + security card), candidate deep-filter signals (install
planning), proxy (ProxySession adopts persisted settings into the app's URLSession;
ProxySettingsSheet + read-only `proxy show` — deliberately NO `proxy set` in CLI), brew
(BrewPinsSheet + `brew-pins`/`brew-doctor`/`brew-index`). Frozen engines untouched (the
commit's only Core-area file is its own new test file). Dead draft GlueModes.swift removed;
parseCli + glue runners extracted for lint.

**Post-close polish (owner session, `23c739b`+`d92d8e9`+`1231519`, coordinator-audited):**
NSApplication materialization fix before the launch display-state policy; honest verdicts
end to end + auto-check default ON with explicit `.noAutoCheck` opt-out (read-only source
lookups only — auto-APPLY consent stays a separate, still-default-OFF boundary; legacy
persisted-file compatibility kept); actionable rows — one-click Stage Install that STAGES
the owner-run command and never executes it (fixes staged-command matching for app names
containing spaces via `lastInstallBundleID`).

**Final union: 839 tests / 71 suites, swiftlint 0 errors.** Local verbatim on `1231519`:
"✔ Test run with 839 tests in 71 suites passed"; CI `27e584d9` verbatim: "✔ Test run with
839 tests in 71 suites passed after 17.646 seconds." + "no lint errors".

**Heading correction:** the sibling 2026-10-29 violation entry above was titled "owner
purge decision pending" when recorded mid-day; the purge was EXECUTED the same day (owner
decision) — see its body + docs/HISTORY-PURGE-MAP.md.

**Deferred-by-design (NOT open work):** helper ACTIVATION (needs Apple Developer ID
enrollment + explicit owner activation; dormant code shipped), crowd data + APNs (locked
no-server rule), notarization/distribution (enrollment). Optional owner follow-up: a GitHub
support ticket to expire cached views of pre-purge commit SHAs.

---

## 2026-10-29 — LOCAL-ONLY violation found + fixed + PURGED (coordinator audit; owner decision executed same day)

**Confirmed (repo state, public remote):** owner asked for a full review of the inherited
wave-2/3 work. The audit found `docs/reverse/` (GAP-ANALYSIS.md, MACUPDATER-FINDINGS.md,
UPDATEST-FINDINGS.md — LOCAL-ONLY per owner decision, per their own headers) TRACKED in git
and pushed to the PUBLIC repo (github.com/abyssbugg/appupdater, HTTP 200 verified). Exactly
one commit touches the path: `4507c4a` (Tier-2 notify-actions integration, 2026-10-27). The
violation survived five gate cycles because the gate checked tests/lint/CI only — it never
checked `git ls-files` for local-only paths.

**Fix shipped (`ba953a2`):** `git rm -r --cached docs/reverse` + `docs/reverse/` rule in
.gitignore (accidental re-add now impossible without `git add -f`); all three files remain
on disk, untouched. Gate after fix: **786 tests / 67 suites passed, swiftlint 0 errors.**

**Purge EXECUTED (owner decision, same day 2026-10-29):** owner chose full history purge.
`git filter-repo` 2.47.0 stripped docs/reverse from a fresh mirror clone (124 commits
preserved; 0 touch the path post-rewrite; `refs/pull/1/head` verified clean + GitHub-managed,
left untouched) and force-pushed main + `v0.1.0` + `ci/macos-fix`. Local repo resynced
(reset --hard + reflog expire + gc; stale local branch `lane/autoapply` deleted — it still
carried the old chain). Old→new map committed: **docs/HISTORY-PURGE-MAP.md** (34 rewritten
hashes; docs citing old hashes resolve through the map; commit messages were auto-updated
by filter-repo). Honest caveats: GitHub may serve cached views of old commit SHAs until a
support purge is filed — owner may file one with GitHub; any pre-purge clone/fork keeps the
blobs. Related exposure, flagged for the same decision:
`docs/MACUPDATER-BREAKDOWN.md` (committed by design since day one as a deliverable) also
contains MacUpdater internals — same exposure class, different lock scope.

---

## 2026-10-28 — Staged-PKG owner command SHIPPED (GAP #11 staging half, `94bfd25`)

**Confirmed (gate + hermetic tests):** staged-PKG v1 landed in one commit — `InstallKind.pkg`
+ `InstallStep.stageOwnerCommand` + `InstallPlan.stagedCommand` (template) +
`InstallOutcome.stagedCommand` (real command; both additive optionals, decode-tolerant).
Pkg plan: download → sha256 → xar! magic → stageOwnerCommand; persistent staging
`staging/staged-pkg/apply-<uuid>/` (pkg survives the run — the per-apply workspace cleanup
must never eat the owner's pkg); CLI prints the owner-run `sudo installer -pkg "<path>"
-target /` to stderr, stdout stays pure JSON, exit 0 on green staging. installer(8) is
NEVER executed (consent boundary; §5b recommendation 4 shipped as written). Gate:
**357 tests / 27 suites passed, swiftlint 0 errors** (was 352/27). 5 new tests: pkg planner
shape + security-floor refusals (HTTP pkg, sha256-less pkg), coordinator green staging
(receipt order, persistence, no backup/disposition/retention), wrong-magic abort at
.download (no stagedCommand, nothing staged), downloader xar! happy path. Deploy lane got
an honest unreachable-case guard (pkg never reaches deploy by construction).

**Notes:** docs batch rides separately (BUILD-PLAN Phase 8 addendum, AGENTS.md entry, §5b
ship note); CI verified green per push, verbatim. Fake-pkg fixtures are byte checks
("xar!" prefix), deliberately NOT pkgutil validations — signature review is the owner's
step before running the staged command.

---

## 2026-10-27 — Gap-closure sprint (Tier 1) SHIPPED: all six competitor gaps closed (waves 1+2)

**Confirmed (gates + live evidence; full detail in `docs/evidence/gap-sprint-2026-10-27.txt`):**
1. **Six lanes via worktrees + subagents, sole file ownership each, never pushed; every branch
   rebased + ff-merged; full gate in main after EVERY merge:** github-source `ae7132e` (+28 tests,
   Releases/latest + ETag body-verbatim cache + asset pick), electron-source `59f0438` (+23,
   app-update.yml + read-only asar fallback), cask-index `2e2dec2` (+29, whole-index ETag store +
   alias-free matching), custom-locations `66a0399` (+13, bookmark-backed scan-location store +
   pane), fsevents `a25094a` (+9, debounced monitor, scan-only guard), manual-sources `5381b7d`
   (+18, per-app github/cask pins + sheet). Coordinator-owned core: VersionOracle unknown-branch
   strictly-greater amendment `5d82814` (+1); engine `ManualSourceResolver` seam `1e53589` (+4);
   glue `818678d` + `52d9d9a` (AppState roster + custom roots + FS monitor + sheets + CLI parity).
2. **Final gate: 352 tests / 27 suites passed, swiftlint errors 0** (was 227/20). Every lane proved
   `git status --short` == owned files only; no lane touched Package.swift or shared files.
3. **Live-network matrix through the real CLI binary** (10 apps): cmux (whole-index token match +
   REAL github harvest manaflow-ai/cmux info-only + verbatim sparkle -1011 failure), Hex Fiend
   (token + github DMG pick `Hex_Fiend_2.18.1.dmg`), Chrome (artifact-name 'Google Chrome.app'
   — CaskAliases retirement proven), Notion (cask 7.41.1 > 7.41.0 ⇒ update over an equal electron
   unknown), Capy + GooeyPi + Superset (equal unknown ⇒ current — amendment live), Linear (token
   equal), Orca (STALE cask 1.3.1 vs installed 1.4.242 ⇒ nothing surfaced; fresher unknown NOT
   substituted — no-fall-through live), **Traycer (unknown-only 1.5.1 > 1.4.2 ⇒ UPDATE — the
   unknown lane's win case live)**.
4. **Whole-index cache proven on real disk:** `~/Library/Application Support/AppUpdater/cask.json`
   = 19,280,921 bytes + `cask.json.etag` `W/"6ae1705b-1263419"` (weak ETag verbatim) +
   `github_etag_cache.json` 6,362 B.
5. **New locks 11–13 recorded in AGENTS.md** (manual-over-builtin; electron stance; FS=scan-only).
6. **Honest deferrals:** manual-pin live e2e (no CLI pin verb — the sheet is the owner action;
   hermetic seam tests cover the engine path); network-volume bookmark live check (no volumes
   mounted). Pre-existing flake flagged (NOT sprint-caused): `happyDmgApplyEndToEndNoLeftoverMounts`
   once in 4 runs, hdiutil timing under parallel load, green on rerun, shared file untouched.
   Lane deviations accepted: CaskIndexStore match API internal (CaskRecord visibility); FS
   `kFSEventStreamCreateFlagUseCFTypes` (brief's None+CFArray combo = proven live crash).
7. **Post-close-out (same session):** six lane worktrees + `gap/*` branches REMOVED at owner
   direction (2.1 GB reclaimed; every branch tip equaled its merged commit — nothing unmerged
   lost; sole worktree left is main `751f561`). Reviewer recommendation recorded in
   `docs/threat-model/PRIVILEGED-HELPER-REVIEW.md` §5b: **DEFER the SMAppService daemon**
   (hard-blocked on Developer ID enrollment) and adopt Updatest's no-daemon shape (stage
   owner-run `sudo installer` commands) for any near-term PKG need; graduate to the daemon
   only after enrollment AND an explicit owner want for password-free/MDM installs. Typos in
   the review doc fixed (line 16 corrupted word).

**Watch items unchanged (owner deferred):** v0.1.0-zip-predates-redesign awareness;
`docs/reverse/` stays local-only/uncommitted.

---

**Confirmed (live evidence):**
1. **Release closed out:** `appcast.xml` committed (`3244b29`) — item values re-derived from the SHIPPED artifact (signature re-verified exit 0; release asset downloaded and byte-compared to the signed build; Info.plist read from the downloaded zip). Feed verified LIVE (raw URL → HTTP 200). Both pushes green on CircleCI. Docs: RELEASE-PLUMBING §2b receipts + §2 warning that CFBundleVersion must advance (Sparkle compares build numbers — short-version-only bumps offer nothing).
2. **Owner directive recorded (LOCKED decision 9 amended):** notarization explicitly abandoned for now; public distribution via GitHub Releases accepted with the documented ad-hoc-signing Gatekeeper caveat. Apple Developer enrollment now optional, not planned.
3. **Three caveats structurally fixed:** (a) feed note — the dev build in `build/` already carries the live feed URL (byte-identical to the released zip); nothing to reinstall; (b) Gatekeeper note — inherent to ad-hoc signing without notarization (abandoned by owner decision); the release notes carry the one-time right-click-Open mitigation, nothing further possible honestly; (c) version-bump note — `Scripts/make-release.sh` written (shellcheck CLEAN) with hard guards: build must advance past the feed's `sparkle:version`, no duplicate tag, clean tree, nonzero test count, lint error column empty, asset size verified post-upload, appcast spliced+pushed. Guards validated by dry-run (`--check`): build-advance refusal + clean-tree refusal + duplicate-tag refusal all proven firing; full pipeline path is the same §1b/§2 steps proven individually.
4. **make-app.sh parameterized:** APPUPDATER_VERSION / APPUPDATER_BUILD env knobs (defaults 0.1.0 / 1) via PlistBuddy Set — one source record, per §2 item 3.

---

## 2026-10-27 — v0.1.0 release close-out, part 1: feed committed + receipts recorded (close-out summary above)

**Context:** the owner's parallel session (OpenCode) executed the release pipeline through `gh release create v0.1.0` and stopped before the feed + record. This session independently re-proved everything rather than trusting the transcript, then closed the release out.

**Confirmed (live evidence, this session):**
1. **Release state verified:** `v0.1.0` published (not draft) at https://github.com/abyssbugg/appupdater/releases/tag/v0.1.0 — asset `AppUpdater-0.1.0.zip`, 1,615,042 bytes. Repo public (owner's call, same day) → asset + feed fetch with no authentication.
2. **Signature chain re-proven INDEPENDENTLY on the shipped artifact:** `sign_update -p` re-derived the exact signature from the local zip (matches the release session's); `sign_update --verify` → exit 0; the asset DOWNLOADED from the GitHub release URL is byte-identical (`cmp`) to the signed local build (sha256 `a7276a6694948a422899b4d335f622bab7c60807ef7aa2d1091f9e0b929a09a7`); Info.plist read from the downloaded zip → CFBundleShortVersionString 0.1.0, CFBundleVersion 1, LSMinimumSystemVersion 15.0.
3. **Feed committed + LIVE:** `appcast.xml` at repo root (commit `3244b29`, xmllint-clean), enclosure = the release asset URL (no binary in the tree), `sparkle:hardwareRequirements arm64` honest (no x86_64 slice — Intel not offered), item values from the downloaded artifact. Verified live: `raw.githubusercontent.com/abyssbugg/appupdater/main/appcast.xml` → HTTP 200 serving the XML. The released app's baked `SUFeedURL` points exactly there; auto-checks stay off (manual menu check only).
4. **Runbook hardened (§2):** added the warning that BOTH version strings must advance per release (Sparkle compares CFBundleVersion vs `sparkle:version` — short-version alone offers no update), plus the full v0.1.0 receipts record (§2b) and the next-release delta list.
5. **Repo-content answer to the owner (from the release session, confirmed here):** the tree needs no trimming — 111 curated files (source, tests, scripts, docs, evidence), secrets-scan clean, junk was only the two `.DS_Store` files the release session already removed. The RELEASE itself ships two generated files (zip asset + appcast), not "the repo's files".

**Honest boundaries:** ad-hoc signed, personal-use posture (LOCKED decision 9) — Gatekeeper first-launch caveat documented in the release notes verbatim; Intel Macs intentionally not offered updates; PKG apps still refuse honestly pending the privileged-helper decision (owner-gated threat-model review). The owner's previously installed dev build still points at the `.invalid` placeholder feed — it will not self-update; reinstall from the release once.

---

## 2026-10-27 — Sourcery corrected to Sourcery AI (name collision) — wrong tool's config removed

**Confirmed (owner-directed):** the "Sourcery" the owner asked for is **Sourcery AI** (the code-security/review SaaS, integrated via its MCP server — SAST/IaC/secrets/dependency findings), NOT the brew `sourcery` Swift code-generation tool that was installed on 2026-10-26. The owner uninstalled the brew binary themselves; this session removed the committed `.sourcery.yml` and `Scripts/SourceryTemplates/` and corrected the record (RELEASE-PLUMBING §4 correction block, AGENTS.md toolchain entry, gotcha-ledger collision entry so no future session reinstalls the wrong tool). Nothing else referenced the codegen tool. History preserved: the 2026-10-26 batch entry below still describes what happened then, including the misinstall — never silently deleted.

**Also this session:** Verity knowledge_spec v2 (owner's commit `9b5a537`) re-pushed to the cloud (`verity standard push`, server `created_at 2026-10-27T18:04:30Z` — the backlog line in AGENTS.md is closed); GitHub Actions workflow disabled (runs were failing red on every push while account-blocked; the file stays as the documented fallback).

---

## 2026-10-27 — Toolchain session: hosted macOS CI FIRST GREEN + all four GitHub Apps confirmed + Verity cloud connection completed

**Confirmed (live evidence this session; verbatim in docs/evidence/audit-2026-10-27.txt, end-state in docs/RELEASE-PLUMBING.md §4):**
1. **CircleCI first GREEN hosted macOS run.** Six-run honest iteration on branch `ci/macos-fix` (never silent on main): runs #1–#4 rejected at 0s because all four executor/resource-class forms used RETIRED names (`macos.m1.medium`/`.gen1` = M1 classes EOL 2026-02-16; `macos.x86.medium.gen2` = Intel removed mid-2024; `machine` default "large" = not a macOS class) — the platform's "pricing plan does not support macos use" hint is generic boilerplate, the Performance plan was never the blocker. Run #5 (`m4pro.medium`) scheduled for the first time and failed the honesty gate correctly (hosted Xcode 16.4.0 = Swift 6.1 < Package.swift's tools 6.3.0). Run #6 (`xcode: 27.2.0` + `m4pro.medium`) GREEN: "✔ Test run with 227 tests in 20 suites passed after 15.531 seconds." — verbatim match with the standing local gate — plus toolchain-evidence (Swift 6.4.2 / Xcode 27.2 / macOS 26.6.2) and the lint correctness gate. Merged to main `249e627`; main's every-push CI is the proven config.
2. **Pipeline wiring headless through CLI:** definition `ci` `6d189e51-…` with github_app providers on the REAL repo id `1433959784`, `all-pushes` trigger `31151bfc-…`; API `run trigger` unsupported for GitHub-App projects (verbatim platform message recorded) — UI "Run pipeline" was used exactly once, then the push trigger drove every run.
3. **GitHub Apps confirmed from the owner's Chrome (github.com/settings/installations, @abyssbugg):** CircleCI App (83572274; also proven by construction — its API bound the repo into the pipeline definition), Codacy Production (106886062; dashboard app.codacy.com/gh/abyssbugg/appupdater live), coderabbitai (105861716; workspace lists `appupdater` in Connected repositories), Verity auth (175623405). Sudo-gated scope pages were not poked; scope evidenced product-side by the products listing the repo.
4. **Verity cloud gap CLOSED.** Device-flow authorization completed via the owner's Chrome session as `@abyssbugg` (code E8FA-32EC; two earlier codes expired unused); `verity auth register --project appupdater` → project `5fd1fbd6-e317-4760-975d-3418a962648d` authenticated as `jlpbyakermansart@gmail.com`; `verity standard push` → Standard **v1** (`04f352a6-…`, 4 quality/7 security/5 custom incl. owner-approved patterns); `verity memory seed` → 14 nodes; `verity config git-moments commit,push` gate ON; formal verification stays off (Lean absent — honest). Recorded CLI-surface correction: `config push` (as previously documented) does not exist in 0.34.4 — surviving: `standard push/get/history` + `config service-url|git-moments|formal`. Honest gap: Standard's knowledge_spec metadata (languages/frameworks/build/test) is empty — refine via `.verity/standard.yaml` v2 later.
5. **Local standing gate untouched and unchallenged:** the earlier same-day evidence (227/20 tests, lint 0 errors, bundle/launch/refusal gates) remains the file of record; the hosted run reproduced the test numbers verbatim on Xcode 27.2.

**Owner actions updated:** (1) ~~authorize CircleCI App~~ DONE; (2) ~~CodeRabbit/Codacy installs~~ DONE (confirmed); (3) ~~Verity correct-account binding~~ DONE; (4) Phase 7 signature in docs/threat-model/PRIVILEGED-HELPER-REVIEW.md — STILL PENDING (reviewer may not self-approve); (5) appcast host decision — STILL PENDING (if a hosted appcast is wanted later, the natural pairing: zips on GitHub Releases via `gh release upload`, appcast.xml raw-pinned in-repo — but a release workflow that UPLOADS anything needs an owner go); (6) Apple Developer enrollment — STILL PENDING.
**Unverified / unchanged:** banner visibility + authorization-dialog UI remain owner-observable; GitHub Actions remains blocked (account billing, startup_failure).

---

## 2026-10-27 — Audit session: full standing gate re-proven live + CircleCI pushed to its headless limit

**Confirmed (live evidence, all commands run this session; verbatim log in docs/evidence/audit-2026-10-27.txt):**
1. Full AGENTS.md verification gate re-run independently on main (`9bf6546`, clean tree, local == origin/main): swift build exit=0; swift test → **227 tests / 20 suites, exit=0**; swiftlint → **0 error-severity hits**; `Scripts/make-app.sh release` exit=0; `codesign -v --strict` OK; plutil OK; live launch observed (PID 17295) + clean quit + 0 crash reports before/after; CLI refusals byte-honest (unknown-app exit=2, current-verdict exit=3, exact stderr texts unchanged, no artifacts written on refusal).
2. Sparkle EdDSA chain RE-PROVEN both ways with the artifact located in-repo (`.build/artifacts/sparkle/Sparkle/bin/sign_update` — no external download needed): (K1) the recorded phase-5 zip still validates — `sign_update -p` reproduces the recorded signature byte-for-byte (deterministic EdDSA) and `--verify` vs the recorded signature → exit=0; (K2) today's freshly rebuilt bundle → zip → `sign_update -p` → `--verify` exit=0, one-appended-byte tamper → exit=1.
3. CircleCI: project CREATE + checkout LINK now work headlessly (CLI grew the capability since 2026-10-26): `circleci project create appupdater --org circleci/RHaHLgciJFtxBVetTA2nyg` → project id `0c6d2ca0-20e6-41e4-a7ef-10ff8bd06465`; `circleci project link` → committed `.circleci/info.yml`. Root finding: Weanime Inc is a STANDALONE org (`VCS -`), so the 2026-10-26 "Project not found" diagnosis stays correct for GitHub-slug lookups. Pipeline DEFINITION create remains blocked at providers (origin = Cursor-only, API 400 "no Origin installation") — the single remaining web click is authorize the CircleCI GitHub App as `abyssbugg`; the ready-made pipeline-create/trigger/run command sequence is recorded in docs/RELEASE-PLUMBING.md §4.

**Owner actions (unchanged except item 1 narrowed):** (1) authorize CircleCI GitHub App as `abyssbugg`; (2) CodeRabbit + Codacy App installs; (3) re-run `verity login --force` as `abyssbugg` (uploads stay forbidden until then); (4) Phase 7 decision-box signature in docs/threat-model/PRIVILEGED-HELPER-REVIEW.md; (5) appcast host decision; (6) Apple Developer enrollment.
**Unverified / unchanged:** banner visibility + authorization-dialog UI remain owner-observable; GitHub Actions first green run still blocked at account level.

---

## 2026-10-26 — Toolchain batch: CircleCI + CodeRabbit + Codacy + Verity + Sourcery wired (owner bindings pending where web-UI-only)

**Confirmed (live evidence):**
1. **CircleCI** — CLI authenticated via OAuth (owner approved; account humannbaby@gmail.com, org "Weanime Inc"). `.circleci/config.yml` committed and `circleci config validate` → valid: macOS job with toolchain-evidence step, `swift build`, nonzero-test-count gate (the XCTest-discovery trap), swiftlint correctness gate, SPM cache. Repo→CircleCI binding NOT possible headlessly (proven: `project get` → Project not found; the org has no GitHub App for abyssbugg) — owner web step documented.
2. **CodeRabbit** — CLI authenticated (Advanced plan, seat assigned). `.coderabbit.yaml` committed with path instructions encoding the repo's honesty contract. Local committed-range review of the Phase-5 work launched via `coderabbit review --committed --base-commit af270b1 --agent` (result to be filed as evidence; 7–30 min runtime).
3. **Codacy** — `codacy.yml` committed (exclusions aligned to .gitignore; swiftlint engine inheriting `.swiftlint.yml`, no divergent second rule set). Cloud app install = owner web step.
4. **Verity** — full init run with owner-answered questions (gate on agent stop, balanced intensity, telemetry off). Standard derived by the CLI, then FIVE custom patterns proposed from the repo's own contract and owner-approved (adopt all): honest-verdicts (critical), no-auto-apply (critical), swift-testing-only (high), per-process-test-roots (high), no-force-unwrap-in-sources (high). `.codacy/codacy.config.json` written + validate-patterns PASS (Trivy 4/4 — deliberate Trivy-only static set: installed adapters have no Swift linter; swiftlint owns Swift lint in CI/local, AI review covers Swift semantics). Hooks wired (`.claude/settings.json`), `VERITY.md` written. Uploads FORBIDDEN: the device-flow login was completed under a different GitHub account than the repo owner — owner must re-run `verity login --force` authorizing AS `abyssbugg`, then `verity standard push` + `verity config push` + `verity memory seed`. Local-only mode until then (gate still runs).
5. **Sourcery** — 2.3.0 installed via brew; `.sourcery.yml` committed; full-tree scan proven clean (0.05s) with ZERO templates — deliberate (no boilerplate repetition to justify codegen; documented in Scripts/SourceryTemplates/README.md).

**Honest boundaries:** three services wait on owner web-UI bindings (CircleCI GitHub App connect, CodeRabbit App install, Codacy App install) and Verity waits on the correct-account re-login — all documented with exact fix paths in `docs/RELEASE-PLUMBING.md §4`. Nothing was claimed done that a browser step gates.

---

## 2026-10-26 — CI diagnosed to the account level by elimination; pipeline ready, owner billing action required

**Confirmed (live evidence):** every GitHub Actions run on this repo ends `startup_failure` at 0s — before any job, log, or check-run exists. Eliminated by experiment: (1) workflow file validates clean (actionlint 1.7.12 + YAML parse), (2) failure reproduces identically on `macos-latest` AND explicit `macos-15` (runs 40391581108 / 40398462700 / 40399629148), (3) a minimal 5-line `ubuntu-latest` echo probe on a side branch startup-fails the same way (run 40399992275 + PR #1 event; probe closed and deleted after the diagnosis). Repo Actions enabled with `allowed_actions: all`; repo not disabled. **Remaining cause class: account/billing** — hosted runners on this private repo (free plan) require the owner's payment-method/spending confirmation (web-UI-only). Fix path + re-run instructions documented in `docs/RELEASE-PLUMBING.md §4`. The ci.yml workflow itself is committed and ready; its first green run must print `swift --version` as toolchain evidence.

---

## 2026-10-26 — Phase 5 (Self-update, Sparkle 2) COMPLETE — EdDSA chain proven end-to-end

**Confirmed (live evidence, this session):**
1. **Sparkle 2.10.1 integrated** via SwiftPM (exact pin; latest stable tag verified by `git ls-remote` before pinning). Only the app target depends on Sparkle; `AppUpdaterCore` stays dependency-free (LOCKED decision 8). Build green with the binary xcframework artifact.
2. **App wiring:** `SelfUpdateCoordinator` (long-lived `SPUStandardUpdaterController`) + menu-bar "Check for Self-Update…" action. Automatic checks HARD-OFF (`SUEnableAutomaticChecks=false`) — no hidden network until the owner configures a real feed; `SUFeedURL` defaults to `https://releases.appupdater.invalid/…` (unreachable-host failure = honest, never fake success).
3. **Bundle surgery (make-app.sh):** `Sparkle.framework` embedded from the xcframework artifact; `@executable_path/../Frameworks` rpath added BEFORE signing (the SPM-linked binary carries no usable rpath); nested adhoc signing (framework with `--deep`, then the app). App + framework both `codesign -v --strict` valid; live launch with the Sparkle engine running: no crash, clean quit, 0 crash reports.
4. **EdDSA signature chain PROVEN** (`docs/evidence/phase5-sparkle-verify.txt`, `phase5-appcast.xml`): `generate_keys` created the keypair in the login keychain (private half NEVER in the repo; public key committed as the make-app.sh default — it is not secret); `sign_update -p` signed `build/release/AppUpdater-0.1.0.zip`; `sign_update --verify` → **exit 0**; one-character signature mutation → **exit 1 "failed to pass signing verification"** (tamper rejection with a real exit code, not assumed); `generate_appcast` independently derived the IDENTICAL signature (second verification path) and emitted `appupdater-appcast.xml` with correct version/size/minimumSystemVersion.
5. **Operational fact captured:** the first keychain-backed `sign_update` blocks on a SecurityAgent prompt; granted "Always Allow" once on this machine (headless runs otherwise hang). CI must pre-provision the ACL or use `--ed-key-file` with a protected key file outside the repo. Recorded in `docs/RELEASE-PLUMBING.md §1b` (full per-release runbook, all steps PROVEN).
6. **Full gate through the integration:** 227 tests / 20 suites exit 0; lint 0 error-severity hits. Phase-6 deliverables (runbook §1b, CI workflow) ride the same push.

**Honest boundaries:** no update server exists — the appcast is a locally generated, locally verified artifact; hosting + a real feed URL is an owner decision (env-overridable `APPUPDATER_FEED_URL`); notarization remains a documented future slot until Apple Developer Program enrollment (LOCKED decision 9).

**Next:** Phase 6 (hygiene/release plumbing — lint + runbook now real, CI unverified until first run) and Phase 7 (privileged helper — BLOCKED on owner sign-off of `docs/threat-model/PRIVILEGED-HELPER-REVIEW.md`, locked rule: the reviewer does not self-approve).

---

## 2026-10-26 — Close-out: open-item lanes landed (notifications / caskalias / retention / channels) + lint gate real + scheduler-test flake root-caused

**Context:** the original session (opencode `ses_e8960d549ffeksiNUeRT7Fm6ra`) died on a provider free-limit mid-fan-out after `lane/notifications` merged (`22956ee`). This session resumed per CLAUDE.md §5 ("always `git status` a dead or silent agent's lane before re-dispatching"): two lanes had complete-but-uncommitted WIP in their worktrees (retention: 412 lines / 3 owned files; channels: 310 lines / 5 owned files), one lane was complete-but-unmerged (caskalias `ae3d32b`), and the coordinator's Phase-6 prep was uncommitted on main.

**Confirmed (live evidence, this session):**
1. **lane/caskalias merged** (`ae3d32b` → merge `f549e6e`): `CaskAliases` built-in table — 14 live-verified tokens, alias retry ONLY after primary-token HTTP 404 (same LookupOutcome pipeline), documented refusals (bionic→lm-studio-bionic name-collision; tailscale→tailscale-app pkg-only). **Live proof: Chrome verdict `unknown → current`** in the refreshed evidence run — the tracked Phase-2 debt is closed by behavior, not by claim.
2. **lane/retention finished + merged**: a re-dispatched finisher subagent found the dead agent's WIP complete and coherent (`retentionKeep` default 3, init-validated; prune best-effort at the END of the fully green apply chain; prune failure = `InstallOutcome.retentionNote`, never an abort; refusals never prune; 5 tests incl. legacy-JSON decode). Verified ×2 in-worktree (201/18), committed `5eca666`, merged.
3. **lane/channels finished + merged**: finisher subagent verified the WIP end-to-end (`InstalledApp.suDefaultChannel` capture; `SparkleSource.selectAdmissible` with Sparkle's exact case-sensitive channel semantics + true-channel restore on the winner; 7 tests incl. an exclusion probe and a case-mismatch pin). Gate green ×2 CONCURRENT in-worktree (203/18), committed `329f168`, merged. The subagent independently reproduced and root-caused the scheduler-test flake (see 4) and correctly did NOT touch the file (outside its ownership).
4. **Scheduler-test flake root-caused + FIXED (new gotcha banked):** `ScheduleEngineTests` read `collector.states.last` immediately after `waitUntil(fireCount == N)` — but the post-fire snapshot is emitted to the AsyncStream and consumed by a separate collector task; under parallel-suite CPU load the read won that race and observed the stale policy-load snapshot (observed once: `lastFireAt = epoch−1min`, nil appsChecked/catchUp). Corroborated by two independent observations (coordinator run + channels subagent run). Fix: arrival-waits (`waitUntil(collector.states.count >= N)`) at all 7 read-sites — the pattern `snapshotsYieldInitialAndPostFire` already used. **Proof: ×3 back-to-back full-suite green + 2 CONCURRENT full runs green.**
5. **Lint gate made real and CLEAN:** swiftlint 0.65.1 installed; calibrated `.swiftlint.yml`; the remaining queued errors fixed at root cause — `AppcastParser` unwrap-once selection (no force-unwraps; also fixed the "Integation" typo), `SparkleSourceTests` `#require` release-date unwraps + identifier renames (+ removed one unused epoch fixture), `InstallCoordinatorTests.servedURL` → throwing `#require` (2 call sites updated). **0 error-severity hits proven.**
6. **Union + full gate on merged main:** 227 tests / 20 suites ×3 back-to-back + ×2 concurrent, build exit 0, bundle assembled + adhoc-strict-signed + plist OK, live launch first-ever fire honest (`lastFireWasCatchUp=false`, appsChecked=82), clean quit, 0 crash reports; CLI evidence refreshed (`phase4-scan/check/installplan`); refusals exit 2 / exit 3 as locked.
7. **Coordinator docs:** AGENTS.md gate renewed (lint line now PROVEN 0 errors; old debt line retired), open items closed (Phase-4 deferred notifications, cask aliases, Sparkle channels, retention wiring, swiftlint), threat-model review document awaiting owner sign-off for Phase 7 (`docs/threat-model/PRIVILEGED-HELPER-REVIEW.md`).

**lane/notifications contract notes (propagated from the original session's accepted review):**
- Removal-only diffs → `noChange`; no zero-count summary notifications are posted.
- `wasCatchUp` is honestly `"unknown"` in the distributed payload until posting moves behind the snapshot emit (the fire seam cannot know its own catch-up identity at posting time).
- The settings toggle is wired via an explicit `Binding` + internal setter, preserving the public `private(set)` surface.
- Notification identifiers are per-fire UUIDs ⇒ there is no app-side dedupe in System Settings; the consequence is documented rather than hidden.

**Unverified / carried:**
- Phase 5 (Sparkle 2 self-update) NOT started — phases sequential; it is the next phase after this close-out push.
- Phase 7 privileged helper: implementation blocked on owner sign-off of the threat-model review (locked rule: the reviewer does not self-approve).
- Retention tests seed fixed past dates while fresh backups use the real clock — ordering is unambiguous only while the machine clock is later than the newest seed (subagent-flagged mild brittleness, unchanged).
- `.github/workflows/ci.yml` drafted but never run — hosted-runner Xcode-27 availability UNVERIFIED until first CI execution.

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
