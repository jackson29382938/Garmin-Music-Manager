import Foundation

/// Deterministic, collision-resistant cache file naming for converted audio.
///
/// The previous scheme keyed the cache file only on the source's base filename
/// (`"<stem>-b<bitrate>-<rate>-converted.m4a"`). Two different sources that
/// share a filename — e.g. `01 Intro.flac` from two different albums — mapped to
/// the same cache file, so with reuse enabled the second conversion could return
/// the first track's audio and send the wrong file to the watch. Folding a
/// stable digest of the source identity (absolute path + size + modification
/// time) and the encode parameters into the name makes cache reuse safe.
public enum ConversionCacheNaming {
    /// Builds the cache file name (including extension) for a converted track.
    /// - Parameters:
    ///   - sourcePath: Absolute path of the source audio file.
    ///   - sourceSizeBytes: Size of the source file in bytes.
    ///   - sourceModifiedEpoch: Source modification time as whole seconds since 1970.
    ///   - bitrateKbps: Target AAC bitrate.
    ///   - sampleRateTag: Short tag for the sample rate (`"src"`, `"44100"`, `"48000"`).
    ///   - fileExtension: Output extension (default `m4a`).
    public static func cacheFileName(
        sourcePath: String,
        sourceSizeBytes: Int64,
        sourceModifiedEpoch: Int64,
        bitrateKbps: Int,
        sampleRateTag: String,
        fileExtension: String = "m4a"
    ) -> String {
        let stem = sanitizedStem(from: sourcePath)
        let identity = "\(sourcePath)|\(sourceSizeBytes)|\(sourceModifiedEpoch)|b\(bitrateKbps)|\(sampleRateTag)"
        let digest = StableStringHash.hexDigest(of: identity)
        return "\(stem)-\(digest)-b\(bitrateKbps)-\(sampleRateTag)-converted.\(fileExtension)"
    }

    private static func sanitizedStem(from sourcePath: String) -> String {
        let base = (sourcePath as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = stem
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "track" : cleaned
    }
}

/// Small dependency-free FNV-1a 64-bit string hash for deterministic cache keys.
/// This is **not** cryptographic; it only disambiguates cache files. Swift's
/// built-in `Hasher` is seeded per process, so it cannot be used for names that
/// must stay stable across launches and platforms.
public enum StableStringHash {
    public static func hexDigest(of string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(hash, radix: 16)
    }
}
