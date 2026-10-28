// SeamRouter.swift — the init-scoped capture bridge between AppState and the
// ListViewModel seams. MOVED VERBATIM from AppState.swift (GAP #26 polish
// lane): the file_length gate (error at 1000 lines) required extracting the
// two self-contained types from the coordinator. Behavior, ordering
// guarantees and docs unchanged; access widened private/fileprivate →
// internal for the move ONLY (same module, app target — no caller outside).

import Foundation
import AppUpdaterCore

/// Honest refusal reasons surfaced from direct actions and the seam bridge
/// (moved out of AppState's nesting WITH the bridge — this is the error
/// vocabulary both sides of the bridge speak; unqualified references from
/// AppState still resolve to this module-internal top-level type).
enum ActionFailure: Error, CustomStringConvertible {
    case ignoreVersionNeedsClaim
    case wiringNotComplete

    var description: String {
        switch self {
        case .ignoreVersionNeedsClaim:
            return "ignore-version needs the claimed version — refresh the list first"
        case .wiringNotComplete:
            return "app state not fully initialized yet — the call failed honestly, try again after launch"
        }
    }
}

/// Capture bridge for the init-scoped closures: on this toolchain a
/// closure may not capture a partially-initialized `self` (definite-init
/// is enforced even for weak captures), so the two VM seams bind THIS
/// router — a fully-initialized `@MainActor` object created BEFORE any
/// closure exists. The router holds a weak owner, assigned by init's
/// final statement (self fully initialized by then). A bridge call
/// arriving before that assignment throws honestly, never crashes.
/// (Closures INSIDE methods keep plain weak-self captures — method
/// bodies are not analyzed against init's definite-init state.)
@MainActor
final class SeamRouter: Sendable {
    weak var owner: AppState?

    func refreshRows() async throws -> [AppRow] {
        guard let owner else { throw ActionFailure.wiringNotComplete }
        return try await owner.pipelineRows()
    }

    func mutateRule(
        _ kind: RuleKind, _ bundleID: String, _ version: String?
    ) async throws -> [AppRow] {
        guard let owner else { throw ActionFailure.wiringNotComplete }
        return try await owner.applyRule(kind, bundleID, version)
    }

    /// The list VM wired to THIS router's seams. Called from AppState.init
    /// while `self` (the router) is already fully constructed — so the
    /// init-scoped closures capture ONLY the router (no AppState `self` —
    /// the definite-init rule never engages). The router is captured
    /// STRONGLY, exactly as the original static factory did: AppState owns
    /// both the VM and the router for their whole lifetime, so no cycle and
    /// no early release exists.
    func makeListViewModel() -> ListViewModel {
        ListViewModel(
            refreshSource: { try await self.refreshRows() },
            ruleMutator: { kind, bundleID, version in
                try await self.mutateRule(kind, bundleID, version)
            })
    }
}
