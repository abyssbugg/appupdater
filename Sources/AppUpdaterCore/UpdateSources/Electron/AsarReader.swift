// AsarReader — parses Electron's `app.asar` archive format in place to recover
// a file's bytes (Updatest's AsarReader recipe, UPDATEST-FINDINGS §3.7 +
// GAP-ANALYSIS #4). Read-ONLY: this reader opens the INSTALLED app's archive
// for reading and never writes, moves, or modifies anything.
//
// HEADER LAYOUT — empirically verified, not assumed:
//
//   The public asar spec (github.com/electron/asar, `lib/disk.js` +
//   Chromium pickles) was cross-checked against REAL installed apps on this
//   machine before coding (READ-ONLY probes, 2026-10-27; full byte table in
//   the lane evidence file `docs/evidence/gap-electron-source-2026-10-27.txt`).
//   Observed on /Applications/Claude.app/Contents/Resources/app.asar
//   (64,068,475 bytes) and re-confirmed by slicing `/package.json` out of it:
//
//     offset    bytes                  meaning
//     ------    -------------------    ----------------------------------------
//     [0..4)    04 00 00 00            size-pickle payload = u32 4 (constant)
//     [4..8)    u32 LE  H              header pickle BUFFER length (bytes at
//                                      [8 .. 8+H)); first file data starts
//                                      exactly at `8 + H`
//     [8..12)   u32 LE  S              header pickle PAYLOAD size; S = 4 + align4(J)
//     [12..16)  u32 LE  J              JSON header byte length
//     [16..16+J) `{"files": …`          JSON header (UTF-8, no BOM observed)
//     [16+J..16+align4(J)) zero pad    pickle 4-byte alignment padding
//     [data_base=8+H          …)        file data — all `offset` values in the
//                                      header are RELATIVE TO THIS BASE
//
//   Sanity cross-checks from the observed sample (J = 188458, align4(J) =
//   188460): S = 4 + 188460 = 188464 = 0x2E030 ✓, H = 4 + S = 188468 = 0x2E034
//   ✓, data_base = 8 + 188468 = 188476 = 16 + align4(J) ✓ — both derivations of
//   the data base agree, and a fetched slice at data_base + offset proved REAL
//   content (`/package.json` → `{"main": ".vite/build/index.pre.js", …}` of
//   Claude Desktop 4.29.0). Real-world offsets agree with the spec assumption;
//   the reader below codes what was observed.
//
// JSON HEADER SHAPE (public asar spec):
//   {"files": { "<dir>": {"files": {…}}, "<file>": {"size": 1121,
//               "offset": "47385950", "integrity": {…}} , …}}
//   - `offset` is a STRING of decimal digits in the observed samples (the
//     reader accepts String or Int — the spec allows both encodings).
//   - Entries marked `"unpacked": true` have NO offset: their bytes live beside
//     the asar in `app.asar.unpacked/`. v1 does not read unpacked companions —
//     such a file is treated as absent (honest nil), documented limitation.
//   - Directory entries have `"files"` only; file entries have size+offset.
//
// Size guards protect the regex scan and memory: the header is read in a
// bounded slice, and extracted main files are capped (see constants) —
// anything larger is treated as unusable rather than loaded wholesale.

import Foundation

/// A resolved `app.asar` archive: its parsed JSON header tree plus the byte
/// offset where the archive's file data begins (per the verified layout above).
struct AsarArchive {
    /// Root `files` dictionary of the JSON header (JSONSerialization tree —
    /// values are [String: Any] / String / NSNumber per the public spec).
    let rootFiles: [String: Any]
    /// Byte offset in the archive where `offset`-relative file data starts.
    /// Empirically `8 + H` (see the file header): verified real-bundle.
    let dataBase: Int
}

enum AsarReader {
    /// Guard: header sizes larger than this are treated as corrupt/unusable
    /// rather than read (real Electron headers observed: ~188KB; 64MB is a
    /// generous corrupt-detection bound, not a real cap).
    private static let maxHeaderBytes = 64 * 1024 * 1024

    /// Guard: a main bundle (package.json `main` file) larger than this is not
    /// scanned for update URLs. Observed main.js sizes: ~1MB (Claude Desktop).
    /// 16MB protects the regex engine; larger files are skipped honestly rather
    /// than truncated silently — see `readMember`.
    static let maxScannedFileBytes = 16 * 1024 * 1024

    /// Opens the archive at `asarPath` and parses its header. Returns nil when
    /// the file cannot be opened, the magic constants/plausibility sizes fail,
    /// or the JSON header does not decode to a files tree — never throws.
    static func open(asarPath: String) -> AsarArchive? {
        guard let file = FileHandle(forReadingAtPath: asarPath) else { return nil }
        defer { try? file.close() }

        guard let first16 = try? file.read(upToCount: 16), first16.count == 16 else { return nil }
        let constants = first16.withUnsafeBytes { raw -> [UInt32] in
            let pointer = raw.bindMemory(to: UInt32.self)
            return [pointer[0], pointer[1], pointer[2], pointer[3]]
        }
        // [0..4): the size-pickle constant `4` is REQUIRED by the observed
        // layout (verified real-bundle header above). Anything else is not the
        // format this reader was designed/verified against.
        let payloadSizeConstant = constants[0]
        let headerBufferLength = Int(constants[1])
        let headerPayloadSize = Int(constants[2])
        let jsonLength = Int(constants[3])
        guard payloadSizeConstant == 4, headerBufferLength > 0, jsonLength > 0 else { return nil }
        guard headerBufferLength <= maxHeaderBytes, jsonLength <= headerBufferLength else { return nil }
        // Pickle payload consistency: S is part of the verified layout and must
        // at least contain the string-length prefix (4 bytes) + JSON. Real
        // sample: S = 4 + align4(J) ✓. Kept as a soft plausibility check.
        guard headerPayloadSize >= jsonLength + 1, headerPayloadSize <= headerBufferLength else { return nil }

        guard let jsonHeader = try? file.read(upToCount: jsonLength) else { return nil }
        guard jsonHeader.count == jsonLength else { return nil }

        let dataBase = 8 + headerBufferLength // verified: = 16 + align4(J) on the real sample
        guard let tree = try? JSONSerialization.jsonObject(with: jsonHeader) as? [String: Any] else {
            return nil
        }
        guard let rootFiles = tree["files"] as? [String: Any] else { return nil }
        return AsarArchive(rootFiles: rootFiles, dataBase: dataBase)
    }

    /// Read `package.json` out of the archive (its canonical location is the
    /// root of the files tree). Implementation detail of the updater-source
    /// recipe: "main" stars in this file's `main` key.
    static func packageJsonData(in archive: AsarArchive, asarPath: String) -> Data? {
        readMember(["package.json"], in: archive, asarPath: asarPath)
    }

    /// Reads one member by PATH SEGMENTS (e.g. ["out", "vs", "code",
    /// "electron-main", "main.js"]) — resolves through the `files` tree exactly
    /// as the asar spec prescribes. Returns nil for:
    ///   - any missing segment / non-file node,
    ///   - `"unpacked": true` members (live in app.asar.unpacked/ — v1 skips,
    ///     documented),
    ///   - members whose size exceeds `maxScannedFileBytes`.
    /// Bytes are read with a bounded FileHandle seek+read (never the whole
    /// archive — real asars reach hundreds of MB).
    static func readMember(_ segments: [String], in archive: AsarArchive, asarPath: String) -> Data? {
        guard let node = node(at: segments, in: archive.rootFiles) else { return nil }
        guard let offset = integer(node["offset"]), let size = integer(node["size"]) else {
            return nil // unpacked/symlink/link members carry no offset — absent for v1
        }
        guard offset >= 0, size > 0, size <= maxScannedFileBytes else { return nil }

        let absoluteDataOffset = archive.dataBase + offset
        guard let file = FileHandle(forReadingAtPath: asarPath) else { return nil }
        defer { try? file.close() }

        // Bound against the archive's real size (toctou-tolerant: a short read
        // below fails through the nil path, never a crash).
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: asarPath),
              let total = attributes[.size] as? Int,
              absoluteDataOffset + size <= total else { return nil }

        guard (try? file.seek(toOffset: UInt64(absoluteDataOffset))) != nil else { return nil }
        guard let data = try? file.read(upToCount: size), data.count == size else { return nil }
        return data
    }

    /// Resolves a path through the header's `files` tree (last segment is the
    /// member; earlier segments are directories).
    static func node(at segments: [String], in root: [String: Any]) -> [String: Any]? {
        var level = root
        var resolvedNode: [String: Any]?
        for (index, segment) in segments.enumerated() {
            guard let child = level[segment] as? [String: Any] else { return nil }
            resolvedNode = child
            if index < segments.count - 1 {
                guard let children = child["files"] as? [String: Any] else { return nil }
                level = children
            }
        }
        return resolvedNode
    }

    /// Header `offset`/`size` fields arrive as JSON strings of decimal digits
    /// in real archives ("offset": "47385950"); the spec also allows numbers.
    /// Accept both; anything else is absent-by-honesty.
    static func integer(_ any: Any?) -> Int? {
        if let number = any as? Int { return number > .min && number <= Int.max ? number : nil }
        if let number = any as? NSNumber { return number.intValue }
        if let text = any as? String {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return Int(trimmed)
        }
        return nil
    }
}
