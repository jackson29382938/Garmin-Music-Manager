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
        await withTaskGroup(of: (Int, AudioTrack).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    let track = await self.scanFile(url)
                    return (index, track)
                }
            }

            var indexed: [(Int, AudioTrack)] = []
            indexed.reserveCapacity(urls.count)
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
