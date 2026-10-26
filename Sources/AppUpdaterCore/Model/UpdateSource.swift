import Foundation

/// A version-information source. Implementations are async and safe to call concurrently.
/// Precedence policy (owner-locked v1): cask > sparkle > MAS > github-optional.
public protocol UpdateSource: Sendable {
    static var kind: SourceKind { get }
    func fetchUpdateInfo(for app: InstalledApp) async throws -> UpdateInfo?
}

/// Scanner contract. Lane "scanner" implements the production one.
public protocol AppScanner: Sendable {
    func scan(directoryURLs: [URL]) async throws -> [InstalledApp]
}
