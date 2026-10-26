// CaskAliases — minimal built-in table of VERIFIED cask-token aliases.
//
// WHY THIS EXISTS (owner-delegated decision, 2026-10-26): the slug policy
// derives a candidate token from the installed app NAME (`CaskMatching.
// candidateToken`), but several casks are published under a token the name
// never produces (Phase 2 live run: installed app "Chrome" derived "chrome",
// which 404s — the real cask token is "google-chrome"). Rather than guessing,
// CaskSource consults this table ONCE after the primary token provably 404s.
//
// KEY/VALUE SEMANTICS:
//   key   = the DERIVED token — exactly `CaskMatching.candidateToken(from:)`
//           output, i.e. what the primary lookup would fetch on the
//           single-cask endpoint. Chosen over the raw app name because the
//           fallback fires in TOKEN space at the fetch site (the app name is
//           already consumed by the derivation; hooking here means every
//           entry is defined against the same normalize-and-slugify step the
//           primary request uses).
//   value = the cask token to RETRY ONCE (verified live to exist).
//
// GROW POLICY (binding — an alias enters ONLY if ALL of these hold):
//   1. Live verification in the session that adds the entry, using the same
//      endpoint CaskSource fetches:
//        - the DERIVED token answers 404 on
//          https://formulae.brew.sh/api/cask/<derived>.json, and
//        - the TARGET token answers 200 with a JSON document whose `token`
//          field equals the target requested and whose `version` is present.
//      The verification date is cited per entry below.
//   2. No guesses: the target must carry an app artifact matching the
//      installed app's name or /path/Basename (case-insensitive, ".app"
//      dropped) — i.e. `CaskMatching.caskMatchesInstalledApp` accepts it at
//      runtime. The table records vendor-identity evidence per entry.
//   3. No name-collision writes: a cask that merely installs an app with the
//      SAME artifact name but a DIFFERENT vendor is refused even though the
//      runtime artifact check alone would (wrongly) accept it. Documented
//      refusals:
//        * "bionic" → cask `lm-studio-bionic` REFUSED (2026-10-26): the
//          live index offers LM Studio's "Bionic.app" (lmstudio.ai
//          installers) for a derived miss, but the installed bundle is
//          `ai.elementlabs.bionic` — a different app that just shares the
//          artifact name.
//        * "tailscale" → cask `tailscale-app` REFUSED (2026-10-26): the cask
//          ships a `.pkg` and publishes NO app artifact, so the artifact
//          validation would decline it anyway; entering it would only add a
//          pointless second fetch that changes no verdict.
//   4. Size is deliberately capped (≤ 15 in this tranche): small and auditable
//      beats broad and shaky. Growth appends entries under this policy.
//   5. Duplicate keys in a Swift dictionary literal collapse silently; the
//      test suite pins the table's exact size, so a lost entry fails loudly.
//
// WHY CaskSource falls back AFTER a 404 instead of rewriting up front: the
// primary behavior must stay observable and honest — a correctly derived
// token wins without a second fetch, and any substitution is logged at the
// moment it happens. Pre-emptive rewriting would mask future improvements to
// the derivation and double the cost of every successful lookup.

import Foundation

public enum CaskAliases {
    /// Derived token (miss) → verified cask token (retry once after 404).
    /// Every entry below was live-verified on 2026-10-26 in the lane's
    /// worktree session: derived token 404'd, target returned 200 with a
    /// document whose `token` == target and a present `version` (proof
    /// captures under /tmp/lanecask_verify/, report-quoted).
    public static let table: [String: String] = [
        // Chrome — REQUIRED entry. Live: chrome.json 404; google-chrome.json
        // 200 (token "google-chrome", version 156.0.8078.48, artifact
        // "Google Chrome.app", installed /Applications/Google Chrome.app).
        "chrome": "google-chrome",

        // VS Code — installed name "Code" at /Applications/Visual Studio
        // Code.app; artifact "Visual Studio Code.app"; homepage
        // code.visualstudio.com. Live: code.json 404; target 200 (1.143.1).
        "code": "visual-studio-code",

        // Brave — installed name "Brave" at /Applications/Brave Browser.app;
        // artifact "Brave Browser.app"; homepage brave.com. Live: brave.json
        // 404; target 200 (1.98.60.0).
        "brave": "brave-browser",

        // Ollama — installed Ollama.app (bundle github.com/ollama); cask
        // renamed to ollama-app, homepage ollama.com, artifact "Ollama.app".
        // Live: ollama.json 404; target 200 (0.40.11).
        "ollama": "ollama-app",

        // GitHub Copilot — installed GitHub Copilot.app; artifact and cask
        // name "GitHub Copilot"; homepage github.com/github/app. Live:
        // github-copilot.json 404; target 200 (1.1.32).
        "github-copilot": "github-copilot-app",

        // Signal Beta — installed Signal Beta.app; artifact and cask name
        // "Signal Beta"; homepage signal.org. Live: signal-beta.json 404;
        // target 200 ("signal@beta", 8.33.0-beta.1).
        "signal-beta": "signal@beta",

        // Cline — installed Cline.app; artifact "Cline.app", cask name
        // ["Cline", "Cline Desktop"], homepage cline.bot. Live: cline.json
        // 404; target 200 (0.0.49).
        "cline": "cline-app",

        // T3 Code (Nightly) — installed T3 Code (Nightly).app; artifact
        // "T3 Code (Nightly).app"; homepage t3.codes. Live: t3-code-nightly
        // .json 404; target 200 ("t3-code@nightly", 0.1.3-nightly.20261026).
        "t3-code-nightly": "t3-code@nightly",

        // Manus Studio — installed Manus Studio.app; cask `manus` publishes
        // artifact "Manus Studio.app", homepage manus.im/desktop. Live:
        // manus-studio.json 404; target 200 (2.0.11).
        "manus-studio": "manus",

        // Amp — installed Amp.app with bundle id com.ampcode.amp.macos; cask
        // amp-app homepage ampcode.com, artifact "Amp.app". Live: amp.json
        // 404; target 200 (1.0,920).
        "amp": "amp-app",

        // Cue — installed Cue.app with bundle id ai.manus.agents; cask
        // manus-cue homepage cue.im, artifact "Cue.app". Live: cue.json 404;
        // target 200 (1.1.4).
        "cue": "manus-cue",

        // Hermes — installed Hermes.app with bundle id
        // com.nousresearch.hermes; cask hermes-desktop homepage
        // hermes-agent.nousresearch.com, artifact "Hermes.app". Live:
        // hermes.json 404; target 200 (0.21.2,088d292d364f).
        "hermes": "hermes-desktop",

        // Devin — installed Devin.app with bundle id
        // com.exafunction.windsurf (Windsurf-built Devin Desktop, devin.ai);
        // cask devin-desktop artifact "Devin.app". Live: devin.json 404;
        // target 200 (3.11.216,d70b4713dfeaf856a4d8a35b35eac0c86e07af07).
        "devin": "devin-desktop",

        // CleanMyMac 5 CLI — installed CleanMyMac_5_CLI.app with bundle id
        // com.macpaw.CleanMyMac5.CLI; cask cleanmymac-cli (MacPaw) publishes
        // the exactly-matching artifact "CleanMyMac_5_CLI.app". Live:
        // cleanmymac-5-cli.json 404; target 200 (1.0.0).
        "cleanmymac-5-cli": "cleanmymac-cli",
    ]
}
