import AppKit
import Foundation
import UniformTypeIdentifiers

/// Drag payload for one or more local file URLs.
///
/// SwiftUI `onDrag` exposes a single `NSItemProvider`. For multi-select we also
/// register a private type carrying a path list so in-app drop targets (Garmin
/// panel) can expand the full set while still offering a normal file URL.
enum MultiFileDragPayload {
    static let typeIdentifier = "com.garminmusicmanager.file-url-list"

    static func itemProvider(for urls: [URL]) -> NSItemProvider {
        let unique = orderedUnique(urls)
        guard let first = unique.first else {
            return NSItemProvider()
        }

        if unique.count == 1 {
            return NSItemProvider(contentsOf: first)
                ?? NSItemProvider(object: first.absoluteString as NSString)
        }

        let provider = NSItemProvider(contentsOf: first)
            ?? NSItemProvider(object: first.absoluteString as NSString)

        let paths = unique.map(\.path)
        if let data = try? JSONEncoder().encode(paths) {
            provider.registerDataRepresentation(
                forTypeIdentifier: typeIdentifier,
                visibility: .all
            ) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }

    /// Collects file URLs from drop providers, expanding multi-file payloads.
    static func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let lock = NSLock()
        let group = DispatchGroup()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                    defer { group.leave() }
                    guard let data,
                          let paths = try? JSONDecoder().decode([String].self, from: data) else { return }
                    let decoded = paths.map { URL(fileURLWithPath: $0) }
                    lock.lock()
                    urls.append(contentsOf: decoded)
                    lock.unlock()
                }
                continue
            }

            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(orderedUnique(urls))
        }
    }

    private static func orderedUnique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted {
                result.append(url.standardizedFileURL)
            }
        }
        return result
    }
}
