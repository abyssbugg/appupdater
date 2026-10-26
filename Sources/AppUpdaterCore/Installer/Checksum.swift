// Checksum helpers — small, pure, file-scoped primitives for the installer
// lanes. Streaming by design: update artifacts can be hundreds of MB, so
// nothing here ever buffers a whole file in memory (fixed 1 MiB read chunks).
//
// Kept separate from Download.swift so the backup/receipt lanes can reuse the
// same helpers without depending on downloader internals.

import CryptoKit
import Foundation

/// Pure checksum helpers over files on disk.
public enum Checksum {

    /// Fixed read-chunk size (1 MiB) — the streaming budget.
    private static let readChunkSize = 1_048_576

    /// sha256 hex (lowercase) of the bytes of the file at `fileURL`, read in
    /// fixed chunks. Throws when the file cannot be opened mid-stream; the
    /// digest is only produced for a fully readable file.
    public static func sha256Hex(ofFile fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        // NOTE (Xcode 27 beta toolchain): the classic `Insecure.SHA256`
        // spelling no longer resolves on this SDK; `SHA256` here IS the same
        // hash CryptoKit used to also re-expose inside `Insecure` (it was a
        // plain alias of the top-level type).
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: readChunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hexOf(hasher.finalize())
    }

    /// Size on disk in bytes (thoroughly present for regular files; the -1
    /// fallback marks an impossible attribute state rather than faking data).
    public static func byteCount(ofFile fileURL: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? -1
    }

    /// Canonical hex form: every whitespace character removed, letters
    /// lowercased. Digest comparisons are case-insensitive via this
    /// normalization on BOTH sides.
    public static func normalizeHex(_ hex: String) -> String {
        hex.filter { !$0.isWhitespace }.lowercased()
    }

    /// Lowercase hex string of a SHA256 digest.
    static func hexOf(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
