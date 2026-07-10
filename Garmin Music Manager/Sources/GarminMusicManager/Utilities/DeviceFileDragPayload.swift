import AppKit
import Foundation
import UniformTypeIdentifiers

/// Drag payload for one or more Garmin device file IDs (File Manager cross-pane drag).
enum DeviceFileDragPayload {
    static let typeIdentifier = "com.garminmusicmanager.device-file-ids"

    static func itemProvider(for fileIDs: [String]) -> NSItemProvider {
        let unique = orderedUnique(fileIDs)
        let provider = NSItemProvider()
        guard !unique.isEmpty,
              let data = try? JSONEncoder().encode(unique) else {
            return provider
        }

        provider.registerDataRepresentation(
            forTypeIdentifier: typeIdentifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        // Also register a plain string so SwiftUI has a primary representation.
        provider.registerObject(unique.joined(separator: "\n") as NSString, visibility: .all)
        return provider
    }

    static func loadIDs(from providers: [NSItemProvider], completion: @escaping ([String]) -> Void) {
        var ids: [String] = []
        let lock = NSLock()
        let group = DispatchGroup()

        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else { continue }
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                defer { group.leave() }
                guard let data,
                      let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
                lock.lock()
                ids.append(contentsOf: decoded)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            completion(orderedUnique(ids))
        }
    }

    private static func orderedUnique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in ids where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }
}
