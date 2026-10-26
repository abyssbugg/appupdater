# AppUpdater (name proposal, pending your final call) — Project Home

A **hybrid** macOS app updater for 2026: combines the full-scan / one-click / privileged /
auto-update machinery of **MacUpdater** (deep-dive: [`docs/MACUPDATER-BREAKDOWN.md`](docs/MACUPDATER-BREAKDOWN.md))
with the modern, serverless source strategy of **Updatest** (public Homebrew cask index,
aggregated Sparkle appcasts, GitHub/Electron, App Store lookup).

## Confirmed project decisions (2026-10-26)

1. **Scope: BOTH** — updates *other* apps AND self-updates via Sparkle.
2. **Architecture: HYBRID** — MacUpdater's execution engine + Updatest's source strategy, one app.
3. **Mac App Store apps: BOTH modes** — inform-only display AND a force-update path (including
   MAS→vendor-download replacement, like MacUpdater's `checkForMASOverwrite`).
4. **Audience: private use AND public release** — so: code-signing + notarization from the start,
   no hard dependency on our own server (public data sources first); optional private API later.
5. **Working name: `AppUpdater`** (candidates were AppUpdater / AppUpdate / AppUpdatest).
   - `AppUpdatest` rejected: derivative of "Updatest", bad for a public brand.
   - `AppUpdate` rejected: ambiguous, collides with Android lib naming, weaker brand.
   - `AppUpdater` chosen: descriptive, professional, no dominant macOS product using it.
     Bundle ID proposal: `io.appupdater.AppUpdater`.
6. **Not building yet.** Folder + docs only until design is approved.

## Layout

- `docs/MACUPDATER-BREAKDOWN.md` — evidence-based deep-dive of MacUpdater 3.5 + sparkle/cask/MAS ecosystem + our recommended architecture.
- `docs/evidence/` — captured reference samples (cask JSON API, macupdater DB-tier page).
