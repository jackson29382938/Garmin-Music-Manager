import AVFoundation
import CoreMedia
import Foundation
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
        for ext in ["aac", "adts", "m4b", "m3u", "m3u8"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    private let fileManager = FileManager.default

    func findAudioFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            let ext = url.pathExtension.lowercased()
            guard Self.supportedAudioExtensions.contains(ext)
                || Self.supportedPlaylistExtensions.contains(ext)
                || Self.knownUnsupportedExtensions.contains(ext) else { return nil }
            return url
        }
    }

    func scanFiles(_ urls: [URL]) async -> [AudioTrack] {
        await withTaskGroup(of: AudioTrack.self) { group in
            for url in urls {
                group.addTask {
                    await self.scanFile(url)
                }
            }
            var results: [AudioTrack] = []
            results.reserveCapacity(urls.count)
            for await track in group {
                results.append(track)
            }
            return results
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

        let compatibility = evaluateCompatibility(
            url: url,
            ext: ext,
            codecHint: loadedCodec,
            metadata: loadedMetadata,
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

    private func evaluateCompatibility(
        url: URL,
        ext: String,
        codecHint: String?,
        metadata: (title: String?, artist: String?, album: String?),
        byteCount: Int64
    ) -> TrackCompatibility {
        var messages: [String] = []
        var blocked = false

        if Self.supportedPlaylistExtensions.contains(ext) {
            return TrackCompatibility(
                status: .warning,
                messages: ["Playlist file; copied as-is, but referenced files must also be present"]
            )
        }

        if Self.knownUnsupportedExtensions.contains(ext) {
            blocked = true
            messages.append(".\(ext) is not supported by Garmin watches")
        } else if !Self.supportedAudioExtensions.contains(ext) {
            blocked = true
            messages.append("Unsupported extension .\(ext)")
        }

        if ext == "m4a" || ext == "m4b", codecHint?.lowercased() == "alac" {
            blocked = true
            messages.append("M4A uses Apple Lossless/ALAC, which Garmin does not support")
        }

        let lowerName = url.lastPathComponent.lowercased()
        if lowerName.contains("protected") || lowerName.contains("drm") || ext == "m4p" {
            blocked = true
            messages.append("Possible DRM-protected file")
        }

        if metadata.title?.isEmpty ?? true {
            messages.append("Missing title tag")
        }
        if metadata.artist?.isEmpty ?? true {
            messages.append("Missing artist tag")
        }

        if byteCount > 250_000_000 {
            messages.append("Large file; consider compressing before copying")
        }

        if blocked {
            return TrackCompatibility(status: .blocked, messages: messages)
        }
        if messages.isEmpty {
            return .ready
        }
        return TrackCompatibility(status: .warning, messages: messages)
    }
}
