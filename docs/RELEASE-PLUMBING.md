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
  runtime + entitlements pass, notarization (stapled). All of this becomes
  possible only after Apple Developer Program enrollment (open item) — the
  runbook for those steps gets written at that enrollment, not before, to
  avoid inventing steps against the wrong tools.

## 1b. Sparkle EdDSA runbook (self-update signature chain) — PROVEN 2026-10-26

Key material: **EdDSA (Ed25519) appcast signing is SEPARATE from code signing**
and never substitutes for it. The PRIVATE half lives ONLY in the owner's login
keychain (created by Sparkle's `generate_keys`; never exported into the repo).
The PUBLIC half is not secret and is committed as the default in
`Scripts/make-app.sh` (`SUPublicEDKey`, env-overridable).

All commands use the Sparkle 2.10.1 CLI pinned by Package.swift:
`.build/artifacts/sparkle/Sparkle/bin/{generate_keys,sign_update,generate_appcast}`
(present after `swift package resolve`).

Per-release pipeline (each step PROVEN this session — evidence:
`docs/evidence/phase5-sparkle-verify.txt`, `docs/evidence/phase5-appcast.xml`):

1. `Scripts/make-app.sh release` — assembles the bundle with
   `Sparkle.framework` embedded (+ rpath + nested adhoc signing) and bakes
   `SUFeedURL` + `SUPublicEDKey` + `SUEnableAutomaticChecks=false`.
2. `ditto -c -k --keepParent build/AppUpdater.app <staging>/AppUpdater-<ver>.zip`.
3. `sign_update -p <zip>` → prints the `sparkle:edSignature` for the item.
4. `sign_update --verify <zip> <signature>` → **exit 0**; a one-character
   mutation of the signature → **exit 1, "failed to pass signing verification"**
   (tamper rejection proven, not assumed).
5. `generate_appcast <staging-dir>` → writes `<AppName>-appcast.xml` with
   sizes/versions + the EdDSA signature it derives itself (it reproduced the
   exact signature from step 3 — a second, independent verification path).

Operational fact (PROVEN): the first keychain-backed `sign_update` invocation
blocks on a SecurityAgent "Always Allow" prompt for the Sparkle signing key —
one-time per tool per ACL; granted 2026-10-26 on this machine. Headless/CI
hosts must either pre-provision that ACL or switch the pipeline to
`--ed-key-file` with a protected key file OUTSIDE the repo.

Boundaries: `SUFeedURL` defaults to `https://releases.appupdater.invalid/…`
(`.invalid` never resolves → checks fail honestly); automatic checks are
hard-off; the app installs an update ONLY when the appcast item carries a
signature verifying against the embedded public key.

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

## 4. CI + review/quality toolchain (2026-10-26 batch: CircleCI, CodeRabbit, Codacy, Verity, Sourcery)

State per tool — every line PROVEN or an explicit owner-step placeholder:

**CircleCI** (replaces the account-blocked GitHub Actions pipeline, §5):
- CLI authenticated (OAuth approved 2026-10-26, account `humannbaby@gmail.com`,
  org "Weanime Inc" `c4abbd1e-575a-4c6f-bd26-0f94346ff563`).
- `.circleci/config.yml` committed and VALIDATED locally
  (`circleci config validate` → valid): macOS job (pinned Xcode — first run is
  the authority on the exact hosted version; adjust the pin from the error's
  list if needed), toolchain-evidence step, `swift build`, nonzero-test-count
  test gate, swiftlint correctness gate, SPM caching.
- **UNVERIFIED — owner web step:** the repo→CircleCI binding. The org has no
  GitHub App connection for `abyssbugg/appupdater` (proven: `project get` →
  "Project not found"). Fix: app.circleci.com → Weanime Inc → Project Setup →
  connect GitHub (authorize as the `abyssbugg` GitHub account) → create the
  project for the repo. The committed config is picked up automatically on the
  next push; macOS execution then proves or names the plan constraint (Free
  plan macOS availability will surface on the first run, honestly).

**CodeRabbit** (AI code review):
- CLI authenticated (2026-10-26; plan Advanced, seat assigned).
- `.coderabbit.yaml` committed: chill profile, evidence/archive paths excluded,
  path instructions encoding the repo's honesty contract (no forced unwraps in
  Sources/, honest verdicts, Swift Testing only, per-process test roots).
- A local committed-range review is the standing proof command:
  `coderabbit review --committed --base-commit <ref> --agent` (first run
  launched against the Phase-5 range; result filed with the session evidence).
- **Owner web step (one click):** install the CodeRabbit GitHub App on
  `abyssbugg/appupdater` at coderabbit.ai to enable automatic PR reviews.

**Codacy** (cloud static analysis):
- `codacy.yml` committed (exclusions aligned with .gitignore; swiftlint engine
  enabled, inheriting `.swiftlint.yml` — no second divergent rule set).
- **Owner web step:** install the Codacy GitHub App on the repo at codacy.com.

**Verity** (AI quality gate on agent-written changes):
- Fully initialized (owner answered the init questions: gate on agent stop,
  balanced intensity, telemetry off). Hooks wired via `.claude/settings.json`.
- `.verity/standard.yaml` — base Standard derived by the CLI, PLUS five
  owner-approved custom patterns distilled from the repo's own contract:
  honest-verdicts (critical), no-auto-apply (critical), swift-testing-only
  (high), per-process-test-roots (high), no-force-unwrap-in-sources (high).
- `.codacy/codacy.config.json` written + VALIDATED (validate-patterns: Trivy
  4/4) — Trivy-only static set (secrets, malicious packages, critical/high
  vulns) because the installed adapters have NO Swift linter; Swift lint
  correctness remains swiftlint's job (CI + local gate), and the AI review
  layer covers Swift semantics. This division is deliberate, not a gap.
- `VERITY.md` at repo root.
- **PENDING owner action:** uploads are FORBIDDEN until the Verity GitHub App
  is authorized for `abyssbugg/appupdater`. The device-flow login was
  completed under a DIFFERENT GitHub account than the repo owner — re-run
  `verity login --force` and authorize AS `abyssbugg` (or grant the Verity App
  access to the repo from the abyssbugg GitHub settings), then
  `verity standard push` + `verity config push` + `verity memory seed`.
  Until then Verity runs local-only (gate works, no cloud history).

**Sourcery** (Swift metaprogramming/codegen):
- 2.3.0 installed via brew; `.sourcery.yml` committed (sources: Sources,
  templates: Scripts/SourceryTemplates, output parked in gitignored .build).
- PROVEN run: full-tree scan finished clean (0.05s) with ZERO templates —
  deliberate: no boilerplate repetition exists to justify generated code yet
  (Scripts/SourceryTemplates/README.md). Add a template only when a real
  repetition appears.

## 5. CI pipeline (Phase 6 gate line — GitHub Actions)

- `.github/workflows/ci.yml` committed: macOS hosted runner, `swift build`
  + `swift test` + swiftlint presence-annotated step (fails honest when the
  runner lacks the tool — pinned availability note lives in the file).
- **UNVERIFIED — blocked at the ACCOUNT level (diagnosed by elimination, 2026-10-26):**
  every GitHub Actions run on this repo fails `startup_failure` at 0s — before
  any job or log exists. Eliminated by evidence: the workflow file is valid
  (actionlint clean + YAML parse OK), the failure reproduces on BOTH
  `macos-latest` and explicit `macos-15` labels, AND on a minimal 5-line
  `ubuntu-latest` echo probe on a side branch (probe PR #1, closed after the
  diagnosis). Repo Actions are enabled (`allowed_actions: all`) and the repo
  is not disabled. Remaining cause class: **account/billing** — hosted-runner
  usage on this private repo (free plan) requires a payment method / spending
  confirmation in GitHub Settings → Billing; that is owner-only (web UI).
  OWNER FIX PATH: github.com → Settings → Billing and plans → add/confirm a
  payment method (or set a spending limit), then re-run any workflow; the next
  run's first live output must print `swift --version` as the toolchain
  evidence line (if the runner's Xcode differs from the locked local 27-beta,
  any behavioral divergence becomes a gotcha-ledger entry, not a silent waiver).
