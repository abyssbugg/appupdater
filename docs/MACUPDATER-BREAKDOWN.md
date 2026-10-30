# Breakdown: macOS App Updates + MacUpdater — for building our own updater

> **Status: pre-build analysis (written 2026-10-26) — the product has since been BUILT;**
> this file remains the reference for MacUpdater's mechanics and the original design. §3.4's
> open decisions were all answered — the binding versions are AGENTS.md's LOCKED decisions
> (which supersede README-era wording, e.g. notarization is abandoned). Working name: **AppUpdater** (hybrid:
> MacUpdater engine + Updatest source strategy). All conclusions below are grounded in evidence
> gathered from the shipped app (`/Applications/MacUpdater.app` v3.5.0/17599, arm64 Mach-O,
> SHA-256 `e45dfe7db90b…1e870`), its runtime artifacts, internet endpoints, and REA/Hopper
> decompilation. Provenance is marked per section.
>
> Secondary sample: `/Applications/Updatest.app` v3.0.0 (`app.updatest.Updatest`) — a current
> competitor showing the 2026 "best practice" source mix.

---

## 1. What MacUpdater is (pieces, end to end)

MacUpdater = **scanner** (find apps) + **version oracle** (find newest version per app from 4
source tiers) + **installer** (download → verify → backup → swap in place) + **scheduler/UI**
(menubar, notifications, ignore lists) + **privilege machinery** (root XPC daemon for
password-less installs) + **self-update** (classic Sparkle).

### 1.1 Process/binary inventory (observed)

| Piece | Path | Role (evidence) |
|---|---|---|
| Main app | `Contents/MacOS/MacUpdater` (5.9 MB Obj-C, 721 classes, 14,918 methods) | UI + scan + update engine |
| Privileged helper | `Contents/Resources/com.corecode.MacUpdaterPrivilegedInstallHelperTool2` | root launchd daemon, does installs |
| Unprivileged worker | `Contents/Resources/installHelperTool` | same install code path, no root |
| Web installer engine | `Contents/Resources/macupdater_install` | standalone installer for downloaded web apps / website install (references `AppInstallHelper.m`, `AppUpdateOperation.m`) |
| CLI client | `Contents/Resources/macupdater_client` | remote control: `list`, `scan`, `update`, `--selfupdate` |
| Relaunch helper | `Contents/Resources/MacUpdaterInstallHelper.app` | tiny app, owns `macupdater://` URL scheme — relaunch after replace |
| Crash reporter | `Contents/Resources/CrashHelper.app` | crash reporting |

### 1.2 Persistence footprint (observed from live system)

- `~/Library/Application Support/MacUpdater/MacUpdater.log` — unified event log
- `~/Library/Application Support/MacUpdater/savedAppInfo3.plist` — array of per-app records
- `~/Library/Application Support/MacUpdater/persistentCache.dict` — NSKeyedArchiver cache
- `~/Library/Application Support/MacUpdater/{NewDownloadBackups,OldAppBackups}/` — backup dirs
- `defaults domain com.corecode.MacUpdater` — prefs incl. `AutoUpdateEnabled`, scan history
- `/Library/LaunchDaemons/com.corecode.MacUpdaterPrivilegedInstallHelperTool2.plist` (helper)
- Server-facing cron-like behavior: scheduled scans, `<AppPath>` cache + 12h threshold

### 1.3 Per-app data model (observed in `savedAppInfo3.plist`)

```
bid  bundle identifier        p   install path            n   app name
v    installed version        sv  Info shortVersion       bv  Info bundleVersion
nb/nv/ns/nn such-approved    ct  last checked version    hu  has update flag
ig   ignore key "bid|installedVersion|newestVersion"      st  state
ut   "update type" enum       mi  "multi install" flag    su  support tier flag
id   installed date           nd  newest-version date     bb  backup path
```

### 1.4 Scan pipeline (class names + decompiled strings from
`+[AppScanHelper scanAppAtPath:allowSendingOrCaching:configFile:error:]`)

Per app:
1. Resolve/validate: not alias, not symlink, not wine/platypus/web-shortcut pseudo-app
   ("ScanApp: return ignoring bzg/nativifier/wine/platypus app"), skip TestFlight betas,
   skip "cracked game with damaged version info", skip `com.apple.InstallAssistant`.
2. Read Info.plist (`InfoPlistHelper.dictionaryWithInfoPlistOfApp:…`) with fixups:
   bundle-id fixups (`CCDidFixupBID`), version fixups (`CCDidFixupVersion`),
   code-signature extraction (binary-search + `SecStaticCode` variants), executable dates.
3. **Source resolution, in practice:**
   - MAS (App Store) test → iTunes lookup `https://itunes.apple.com/lookup?bundleId=%@`
     (`getMASUpdateinfo:*`, `AppstoreFixupHelper._getNewestVersionOfApp:`)
   - Sparkle feeds (`SparkleFeedDetectionHelper.getSparkleFeedsForApp:` — Info.plist
     `SUFeedURL` plus more), parsed by `SparkleFeedParser` (spoofs
     `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)` UA; handles `newestItemForAnyOS`
     vs `ForCurrentOS`); on feed failure → "fallthrough to cask"
   - **DB tier** (`UpdateInfoDB`): `macupdater.net/cgi-bin/*receive.cgi` family —
     `receive.cgi`, `receive_array.cgi`, `receive_date.cgi`, `receive_name.cgi`,
     `submit2.cgi`, `extract_text` (server-side scraping!); backend logs
     `pymysql.err.OperationalError` → Python/MySQL
   - **Cask tier** (`UpdateInfoCask` + `CaskHelper`): caskfiles from CoreCode's private
     mirrors `https://macupdater-backend.com/files/casks_automatic…/%@.rb` and
     `casks_manual…/%@.rb` — i.e. they HOARD + PATCH Homebrew-cask `.rb` files and parse
     with their own Ruby-stanza parser (`getAppBVFromCaskfile:`, `getSHA256FromCaskfile:`,
     `getInstallPathFromCaskfile:` variants, variant stanzas)
   - **Webview scrape tier** (`readability.js`, `inject.js`,
     `content-blocker-cookie-notices.json.lzma`, server `extract_text`) — Tier-3 fallback
   - (Extra vendor feeds seen in strings/log: App Center `api.appcenter.ms/.../sparkle/apps/%@`,
     DevMate `updates.devmate.com/%@.xml`, GitHub `api.github.com/repos/…` + releases.atom,
     vendor-specific: Firefox AUS, Blizzard, Office update history, Blackmagic…)
4. Cache everything (12h full-scan threshold; manual rescan throttled by license tier).
5. Report unknowns to server: `sendMissingVersionReport:`, `sendSparkleReport:`,
   `sendElectronReport:`, `sendIconReport:`, `collectErrorEvent:` (crowd-sourced DB upkeep).

### 1.5 Update pipeline (decompiled `AppUpdateOperation`, `AppUpdateHelper`,
`PrivilegedInstallHelper`, `JMSUPlainInstaller` strings)

1. `runPreUpdateChecks`: `checkForMajorUpgrade` (bundle-id change = major),
   `checkForMASOverwrite` (replace MAS app with vendor download), `ensureAppIsntRunning`
   (`AppQuitHelper` → AppleScript quit → terminate → force-kill; handles App Translocation),
   LibreOffice language dialog, multilingual confirm (`isInteractive` + delegate).
2. Download (`HTTPDownloader`, custom `User-Agent` + `Referer`) with
   `SecurityDisallowHTTPConnections` policy (refuses `http://` targets).
3. Verify: SHA-256 from caskfile (`SHA256ChecksumForFileAtPath:` +
   `SecurityDisallowUnexpectedChecksum`); Sparkle items carry `downloadSignatureDSA`.
4. Type/extract by extension + magic number: `.zip/.dmg/.tbz/.tgz/.pkg`,
   double-compressed archives handled; too many candidate `.app` → error;
   `depends_on requires newer OS` → drop update.
5. Backup old app (`BackupHelper`: DMG (hdiutil) default, ZIP optional; keep/erase policy).
6. Install:
   - **Normal user privileges** → `JMSUPlainInstaller.updateAppAtURL:destinationAppURL:
     updateURL:unquarantine:…` (Sparkle-derived): make-permissions-movable fix → release
     quarantine (xattr) → chown to match old app → preserve times → move old app to temp →
     move new app in → final destination; atomically; "broken permissions" reporting.
   - **Needs root / no password prompt** → `PrivilegedInstallHelper` over XPC to
     launchd daemon (`MachServices: com.corecode.MacUpdaterPrivilegedInstallHelperTool2`)
     passing `{oldAppPath, destinationAppPath, newUpdateURLData, unquarantine, type,
     progress}`; helper runs hdiutil + `JMSUPlainInstaller` + PKG via
     `installPKGViaApplesInstaller:`. Registration: SMAppService (user-confirmed) OR
     remote/MDM via bundled `priviledgedHelperTool_install.sh` (writes LaunchDaemons plist
     directly — that's why they need FDA: `[PRIV] helper does everything`).
   - PKG path: Apple's `/usr/sbin/installer` with cask stanza handling
     (`package-will-remove-previous-installations`, …).
7. Post-install: rescan app, relaunch if needed (`LaunchUpdaterHelper`/`MacUpdaterInstallHelper.app`),
   keep download backups (`NewDownloadBackups`), erase old backups, fire notifications,
   NSDistributedNotifications for automation (documented in readme; names not static strings).
8. UI states: `ut` (update type) incl. major-red info button; ignore/snooze per app+version.

### 1.6 Scheduling (decompiled `AdvancedScanHelper`)

`calculateNextScanDate:scheduleIn10Minutes:`, modes: every-N-day / particular day /
every work day / weekend; missed-scan rescheduling; retry counters for skipped scans;
post-scheduled-scan AutoUpdate pass with eligibility (`isEligibleForAutoUpdate`,
per-vendor autoupdater app detection e.g. Adobe/BattleNet/Steinberg — skip those).

### 1.7 Self-update (macupdater updating itself)

Classic Sparkle: `SUFeedURL https://www.corecode.io/macupdater/macupdater3.xml`,
`SUPublicEDKey r4T050IkbHzfuQfEm6f4GzHVbmQfPsuJUKYIiicQl3s=` + legacy `dsa_pub.pem`.
(Streamed feed confirmed in `ConfigFile.m`-class names `JMSU*Unarchiver` — their
in-repo Sparkle is modified "Foreign Code/Sparkle/JMSU*".)

### 1.8 Publication/DB tier (their server side, from URL strings)

- `macupdater.net/cgi-bin/receive*.cgi` family (MySQL-backed Python CGI)
- `macupdater-backend.com/files/casks_automatic|casks_manual…/<cask>.rb` (curated casks)
- `macupdater.net/app_updates/` public mirror: `appinfo/<bid>/index.html` pages with
  `Version String / Release Date / Install App via MacUpdater (#{appdownload_mu_url})
   / Version History` (see `evidence/garage_ua.html`)
- top-N lists (`top-250-mac-apps.html`), weekly change indexes, search page

### 1.9 Known unknowns (not established)

- Contents of `config.json.encr` (encrypted bundle DB snapshot).
- Exact CGI POST payload/protocol details (only method names + error strings).
- NSDistributedNotification names (constructed at runtime).
- `macupdater_install` deeper internals (REA session couldn't reopen after bridge
  timeout; strings-level only — standalone installer semantics well supported though).

---

## 2. The macOS update ecosystem (context for our design)

| System | How it works | What an "updater" can do with it |
|---|---|---|
| **Sparkle** (de-facto standard) | App's Info.plist `SUFeedURL` → RSS/XML appcast; `sparkle:version`, `minimumSystemVersion`, `criticalUpdate`, `phasedRolloutInterval`; enclosure with `sparkle:edSignature` (Ed25519, `sign_update` tool, `SUPublicEDKey` in plist); installer = separate updater XPC + launchd privileged installer; atomic ops; pkg installs need admin auth | Detect version for ~all indie apps **by fetching their own appcast**, no server needed. Also what OUR app uses to self-update. |
| **Mac App Store** | Apps live in `/Applications`, receipt-checked; version truth = iTunes lookup API (`itunes.apple.com/lookup?bundleId=`) | Detect if app is MAS (receipt / mas-token metadata) → either AppStoreForceUpdate (ghost packets) or just inform/open store. Non-MAS `mas` CLI (`mas upgrade`, SIP-limited copies) |
| **Homebrew Cask** | Formulae .rb per app + **public JSON API**: `https://formulae.brew.sh/api/cask/<token>.json` (per-cask) and `/api/cask.json` (full index, incl. token↔bundle-id artifacts, version, url, sha256, `quit` apps) | The cleanest single free data source covering most vendor apps; gives download URL + SHA-256 + install path |
| **GitHub releases** | `api.github.com/repos/<owner>/<repo>/releases` or `/releases/latest`, `releases.atom` | Big slice of dev-tools adopt this; asset matching heuristics needed |
| **Electron autoUpdater** | `update.electronjs.org/<owner>/<repo>/<platform>/<commit-ish>` or generic electron-updater configs (generic providers) | Only works where channel URLs can be derived from the app's metadata at runtime |
| **Vendor web pages** | No standard | Scrape (what MacUpdater does w/ readability + server `extract_text`) — maintenance nightmare; do LAST / opt-in |

**Sources coverage tiers (as used by the field):** cask JSON + Sparkle appcast
aggregates covers most non-MAS apps; MAS covers the store slice; GitHub/Electron cover
recent dev-tools; scraping covers the long tail (Tier 3).

---

## 3. Combining both into one: recommended architecture for OUR updater

Goal-shaped (aligned to what the evidence showed both apps actually need):

### 3.1 Core components
1. **Scanner** — enumerate `/Applications`, `~/Applications`, optional extra folders +
   "other software" (cask/PKG-installed weirdness); build AppInfo records
   (bundle-id, CFBundleVersion/Short, path, arch, codesign date).
2. **Source strategy** (order):
   a. MAS test (receipt + iTunes lookup) → "store" state.
   b. **Cask JSON API** (`api/cask.json` full index, map artifact → installed app by
      bundle-id/path; `quit` + `sha256` + `url` come free). This replaces CoreCode's
      private cask mirror with a public one.
   c. **App's own Sparkle appcast** (`SUFeedURL`) — most up-to-date source for sparkle apps;
      handle EdDSA, OS-requirements, channel tags.
   d. **GitHub releases** API (bundle-id → repo mapping optional, feature-not-default).
   e. (optional, later) web/UI-overseen scrape for the long tail; disabled by default.
3. **Version oracle** — semver-ish comparator identical in spirit to MacUpdater's
   (fork of Sparkle's SUStandardVersionComparator + special cases).
4. **Installer** — Sparkle-style:
   - user-space atomic swap (JMSUPlainInstaller semantics: fix perms → unquarantine →
     chown/mtimes → temp-dir swap → relaunch helper),
   - backups (DMG default, ZIP option, retention policy),
   - quit-running-apps flow,
   - **opt-in root path**: SMAppService daemon (issue #1 above) for `/usr/sbin/installer`
     PKGs and password-less private-home installs; MDM remote-install script (their
     `priviledgedHelperTool_install.sh` teaches the pattern to copy safely).
5. **Scheduler + UI** — menubar (LSUIElement), scheduled scans w/ missed-scan catch-up,
   per-app/per-version ignore; auto-update eligibility rules; DMG/ZIP backup options.
6. **Self-update** — Sparkle 2 (appcast generator + `sign_update` in release pipeline;
   `SKIP_INSTALLER`/plain-installer XPC services).
7. **CLI + scriptable surface** — `list/scan/update` grammar + `update` flags like
   `--force-quit-running-apps`, `--json`, plus `NSDistributedNotifications` for automation
   (upgrade: document our own notification names, they didn't).
8. **Package/install side** — PKG via Apple `installer` (requires the root helper),
   verified SHA-256, preserve-receipts behavior for MAS-converted vendor installs.

### 3.2 Security requirements (from evidence, non-negotiable)
- HTTPS-only downloads (`SecurityDisallowHTTPConnections` behavior).
- SHA-256 (or better, signed artifacts) before replace; refuse unexpected checkums.
- EdDSA (Ed25519) signed artifacts for our app's own updates; keys in repo.
- No v1-style helper; SMAppService/launchd service; least-privilege; never run hdiutil as root.

### 3.3 Risks to design around (from the field evidence)
- **duplicate bundle-id across installs** (MacUpdater has DuplicateCount + policy strings),
- **staged/multi-branch versions** (cask has variant stanzas; readme links to their policy),
- **translocation** (file-op fixups in JMSUPlainInstaller),
- **running apps / Adobe-style per-vendor auto-updaters** (special-case list),
- **major upgrades pricing/licensing** (UT says it's business-relevant),
- **source flakiness** → retries + freshness flags + cache-first UI (12h threshold behavior).

### 3.4 Open decisions BEFORE building (needed from you)
1. Scope: "update other apps" only, or also self-update (Sparkle)? (Assumed: both.)
2. Root helper: include now or defer? (Recommend: defer to phase 2.)
3. Deployment target & Apple Mac App Store apps: inform-only vs force-update via helper?
4. Private usage or public/free for others? (drives DB/CGI-less vs server design)
5. Language/toolchain preference (SwiftUI app + Sparkle 2 assumed).

---

## 4. Evidence index

- REA (Hopper, MacUpdater main binary, arm64): EvId refs for binary_overview
  (`ev_8b40cc80…`), objc classes (`ev_ed6cb5cb…`), batch_decompile of 8 install/flow
  functions (`ev_4fa650…`), scanAppAtPath 3.3 MB pseudocode (too large for transport;
  strings captured).
- Live-artifact ground truth: `/Applications/MacUpdater.app/Contents/**` (Info.plist,
  LaunchDaemons plist, install scripts, readability/readability.js/inject.js, homepages.json),
  `~/Library/Application Support/MacUpdater/**` (log, savedAppInfo3.plist, caches),
  `defaults read com.corecode.MacUpdater`.
- Reference docs: Sparkle publishing/security docs (via context7), Homebrew cask JSON API
  sample (`evidence/ff.json`), macupdater.net DB-tier page sample (`evidence/garage_ua.html`),
  Updatest.app strings (cask-index + sparkle-aggregate + github + electron + MAS).
