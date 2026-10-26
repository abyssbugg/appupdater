# Release plumbing — codesigning runbook + release checklist (Phase 6)

> Status: living document. Every claim below is either PROVEN (with the
> command + session date) or an UNVERIFIED placeholder explicitly marked. No
> invented green.

## 1. Signing runbook (current reality)

- Current identity: **ad-hoc** (`codesign -s -`) — PROVEN every session by the
  standing gate `codesign -v --strict build/AppUpdater.app`. This is legal for
  personal use on this machine; it makes NO distribution claim.
- A dev-class identity (`Spike0 Signing`) exists in the keychain per the
  Phase-1 note; NOT used by `Scripts/make-app.sh` today (adhoc by design —
  switching identities is a deliberate owner decision, not a default).
- **UNVERIFIED / future:** Developer ID App + Installer certificates, hardened
  runtime + entitlements pass, notarization (stapled), Sparkle EdDSA as a
  SEPARATE key material (never the codesign identity). All of this becomes
  possible only after Apple Developer Program enrollment (open item) — the
  runbook for those steps gets written at that enrollment, not before, to
  avoid inventing steps against the wrong tools.

## 2. Release checklist (per release, incl. self-updates)

1. Full gate on main is green THIS session (AGENTS.md → Verification gate —
   build / full test suite / bundle / sign / plutil / live launch / CLI
   evidence, all with current-session output).
2. `swiftlint` gate green (see §3 policy).
3. Version bump lands as a COMMIT, never a drift: `CFBundleShortVersionString`
   and `CFBundleVersion` come from ONE source record in `Scripts/make-app.sh`
   (verify before release: single source, single place).
4. Bundle assembled by `Scripts/make-app.sh release`; ad-hoc/identity per §1
   decision recorded in the release notes verbatim.
5. Self-update artifact: Sparkle appcast regeneration + EdDSA signature
   verified via the Sparkle release tools pinned to the Package's Sparkle
   version (Phase 5 ALREADY PROVED the sign/verify pipeline; repeat per
   release and file the output as release evidence).
6. Tag `v<version>` on the release commit; push tag + release notes.
7. Post-release: record the receipts (test count, evidence file names, tag) in
   `docs/archive/AGENT_LOG.md` (newest on top).

## 3. swiftlint policy (Phase 6 gate line)

- Tool install: `brew install swiftlint` — PROVEN installed 2026-10-26 (swiftlint
  0.65.1 via Homebrew; the standing open item is closed). The gate line becomes
  real from now on.
- Calibrated config (`.swiftlint.yml`, decisions recorded 2026-10-26): style
  rules stay Warnings; the ERROR column is force_cast / force_try
  (Tests excluded — fail-fast fixtures are their purpose) and
  force_unwrapping in shipping code (syntax rule: no `excluded` key support,
  so test-file hits get ROOT-CAUSE source fixes at merge, not config tricks).
  Thresholds: cyclomatic_complexity warn 10 / error 50 (the CLI dispatcher's
  linear 30-case switch is a documented exception), function_body_length
  warn 160 / error 400, type_body_length warn 300 / error 600.
- Baseline on main at config-creation (PROVEN by run): force_unwrapping 15 =
  11 SHIPPING-code sites (Main.swift 7, MenuData 1, AppcastParser 3) + 4
  test-file sites (DownloadTests 1, SparkleSourceTests 2, InstallCoordinatorTests 1).
  Coordinator fixed NOW: Main.swift 7 (single `errLine` helper; CLI behaviors
  re-proven byte-identical: refusal exit 2 + exit 3 stderr texts + usage,
  Application-Support dir untouched), MenuData 1 (UTC clock → pure integer
  math), DownloadTests 1 (→ `#require`), plus RuleStore's count-zero site
  (`!isEmpty`). Queued for the post-merge pass: AppcastParser 3, the 3
  lane-owned test sites (SparkleSourceTests 2 + InstallCoordinatorTests 1) —
  root-cause fixes, not config tricks. Separate rule: 3 identifier-name hits
  in SparkleSourceTests (self-documenting date fixtures; rename at the same
  post-merge pass). All remaining style hits
  (static_over_final_class 12, data-conversion preferences 15, large_tuple)
  are Warnings and stay visible, never hidden.
- Scope: run on CHANGED sources per session/release (full-codebase strict mode
  is NOT the goal; the repo carries deliberate long doc-comment headers that
  satisfy honesty rules — keep `line_length` warning-only with sensible
  limits, style rules stay warnings, correctness-relevant lints (force_cast,
  force_try, force_unwrapping in shipping code) are ERRORS).
- A release that introduces new `force_*` errors is BLOCKED (this is the
  lint gate bite).

## 4. CI pipeline (Phase 6 gate line)

- `.github/workflows/ci.yml` committed: macOS hosted runner, `swift build`
  + `swift test` + swiftlint presence-annotated step (fails honest when the
  runner lacks the tool — pinned availability note lives in the file).
- **UNVERIFIED until first live run (recorded honestly):** which Xcode the
  hosted runner picks by default, and whether Xcode 27-beta (the locked local
  toolchain) is simultaneously available there. First CI run must print
  `swift --version` / selected Xcode as its evidence line; if the runner's
  toolchain differs from local, the workflow still must pass SPEC tests —
  any behavioral difference becomes an AGENTS.md gotcha entry, not silence.
