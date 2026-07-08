import AVFoundation
import CoreMedia
import Foundation
import GarminMusicCore
import UniformTypeIdentifiers

final class MusicScanner {
    static let supportedAudioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "adts", "wav"
    ]

    static let supportedPlaylistExtensions: Set<String> = [
        "m3u", "m3u8", "wpl", "zpl"
    ]

    static let knownUnsupportedExtensions: Set<String> = [
        "aif", "aiff", "alac", "flac", "m4p", "ogg", "opus", "wma"
    ]

    static var supportedPickerTypes: [UTType] {
        var types: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav]
        for ext in ["aac", "adts", "m4b"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    static var supportedPlaylistPickerTypes: [UTType] {
        ["m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) }
    }

    private let fileManager = FileManager.default

    /// Audio and known-unsupported audio-like files under a folder (not playlist files).
    func findAudioFiles(in folder: URL) -> [URL] {
        enumerateFiles(in: folder) { ext in
            Self.supportedAudioExtensions.contains(ext)
                || Self.knownUnsupportedExtensions.contains(ext)
        }
    }

    /// Playlist files under a folder (`.m3u`, `.m3u8`, etc.).
    func findPlaylistFiles(in folder: URL) -> [URL] {
        enumerateFiles(in: folder) { ext in
            Self.supportedPlaylistExtensions.contains(ext)
        }
    }

    /// Expands folders into audio files and resolves local tracks from playlist files.
    /// - Returns audio URLs ready for `scanFiles`, plus how many playlist files were expanded.
    func expandImportURLs(_ urls: [URL]) -> (audioURLs: [URL], playlistsExpanded: Int) {
        var audioURLs: [URL] = []
        var playlistsExpanded = 0
        var seen = Set<String>()

        func appendAudio(_ url: URL) {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            audioURLs.append(url.standardizedFileURL)
        }

        for url in urls {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                for audio in findAudioFiles(in: url) {
                    appendAudio(audio)
                }
                for playlist in findPlaylistFiles(in: url) {
                    playlistsExpanded += 1
                    if let tracks = try? M3UImporter.localTrackURLs(from: playlist) {
                        tracks.forEach(appendAudio)
                    }
                }
                continue
            }

            let ext = url.pathExtension.lowercased()
            if Self.supportedPlaylistExtensions.contains(ext) {
                playlistsExpanded += 1
                if let tracks = try? M3UImporter.localTrackURLs(from: url) {
                    tracks.forEach(appendAudio)
                }
                continue
            }

            appendAudio(url)
        }

        return (audioURLs, playlistsExpanded)
    }

    func scanFiles(_ urls: [URL]) async -> [AudioTrack] {
        // Never treat playlist files as audio assets.
        let audioOnly = urls.filter { url in
            !Self.supportedPlaylistExtensions.contains(url.pathExtension.lowercased())
        }
        return await withTaskGroup(of: (Int, AudioTrack).self) { group in
            for (index, url) in audioOnly.enumerated() {
                group.addTask {
                    let track = await self.scanFile(url)
                    return (index, track)
                }
            }

            var indexed: [(Int, AudioTrack)] = []
            indexed.reserveCapacity(audioOnly.count)
            for await result in group {
                indexed.append(result)
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    func scanFile(_ url: URL) async -> AudioTrack {
        let ext = url.pathExtension.lowercased()
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        let asset = AVURLAsset(url: url)
        async let durationSeconds = loadDuration(from: asset)
        async let metadata = loadCommonMetadata(from: asset)
        async let codec = loadCodecHint(from: asset)

        let (loadedDuration, loadedMetadata, loadedCodec) = await (durationSeconds, metadata, codec)
        let compatibility = MusicCompatibilityEvaluator.evaluate(
            url: url,
            ext: ext,
            codecHint: loadedCodec,
            title: loadedMetadata.title,
            artist: loadedMetadata.artist,
            byteCount: byteCount
        )

        return AudioTrack(
            url: url,
            fileName: url.lastPathComponent,
            fileExtension: ext,
            title: loadedMetadata.title,
            artist: loadedMetadata.artist,
            album: loadedMetadata.album,
            durationSeconds: loadedDuration,
            byteCount: byteCount,
            codecHint: loadedCodec,
            compatibility: compatibility,
            isSelected: compatibility.canCopy
        )
    }

    private func enumerateFiles(in folder: URL, matching: (String) -> Bool) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            let ext = url.pathExtension.lowercased()
            guard matching(ext) else { return nil }
            return url
        }
    }

    private func loadDuration(from asset: AVURLAsset) async -> Double? {
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite ? seconds : nil
        } catch {
            return nil
        }
    }

    private func loadCommonMetadata(from asset: AVURLAsset) async -> (title: String?, artist: String?, album: String?) {
        do {
            let metadata = try await asset.load(.commonMetadata)
            func stringValue(for key: AVMetadataKey) async -> String? {
                guard let item = metadata.first(where: { $0.commonKey == key }) else { return nil }
                let value = try? await item.load(.stringValue)
                return value?.nilIfEmpty
            }
            return (
                await stringValue(for: .commonKeyTitle),
                await stringValue(for: .commonKeyArtist),
                await stringValue(for: .commonKeyAlbumName)
            )
        } catch {
            return (nil, nil, nil)
        }
    }

    private func loadCodecHint(from asset: AVURLAsset) async -> String? {
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { return nil }
            let formatDescriptions = try await track.load(.formatDescriptions)
            for description in formatDescriptions {
                let subType = CMFormatDescriptionGetMediaSubType(description)
                let fourCC = fourCharCodeString(subType)
                if !fourCC.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return fourCC
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    private func fourCharCodeString(_ code: FourCharCode) -> String {
        let chars = [
            Character(UnicodeScalar((code >> 24) & 255)!),
            Character(UnicodeScalar((code >> 16) & 255)!),
            Character(UnicodeScalar((code >> 8) & 255)!),
            Character(UnicodeScalar(code & 255)!)
        ]
        return String(chars)
    }

}
