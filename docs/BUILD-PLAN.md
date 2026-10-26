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

## Phase 2 — Scanner + SourceStrategy (truth engine)
Gate: scan your `/Applications` → JSON report of updates found, 0 false "success" claims
Lanes (parallel):
- **A. Scanner/AppInfo** — enumerate apps (+ custom folders later), Info.plist fixups
  (bundle-id, version), codesign date (SecStaticCode), MAS receipt detection.
- **B. CaskSource** — download `formulae.brew.sh/api/cask.json` (full index), map artifacts
  ↔ installed apps, extract `version/sha256/url/quit`.
- **C. SparkleSource** — fetch app's own `SUFeedURL` appcast (UA handling like guidance),
  parse items: version/shortVersion/minimumSystemVersion/edSignature/enclosure/rollout/critical.
- **D. MASSource** — iTunes lookup by bundle id + receipt cross-check (inform + replace-MAS
  decision matrix).
- **E. VersionOracle** — Sparkle-style comparator + special cases (Apple builds, dates, suffixes).
Reconciliation order (owner-locked sources v1): cask > sparkle > MAS > GitHub(optional) —
documented in code as precedence with confidence labels like Updatest.

## Phase 3 — Installer (plain user-space, atomic swap)
Gate: dry-run mode executes a REAL low-risk update end-to-end on the dev machine; backup verified
- Download (HTTPS-only policy) → SHA-256 verify → extension/magic detection → backup (ZIP/DMG) →
  quit-running-app flow → atomic swap (Sparkle-plain-installer semantics) → relaunch → post-scan.
- Dry-run/apply separation is a hard interface from day 1.

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
