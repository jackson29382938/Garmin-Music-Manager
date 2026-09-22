import AppKit
import Foundation
import UniformTypeIdentifiers

/// Unified in-app + Finder drag payload (local URLs and/or device file IDs).
enum UnifiedDragPayload {
    static let typeIdentifier = "com.garminmusicmanager.unified-drag"

    struct Envelope: Codable, Hashable, Sendable {
        var sourceKind: DragSourceKind
        var localPaths: [String]
        var deviceFileIDs: [String]
        var displayNames: [String]
        var totalByteCount: Int64
    }

    static func itemProvider(for items: DragItemSet) -> NSItemProvider {
        let envelope = Envelope(
            sourceKind: items.sourceKind,
            localPaths: items.localURLs.map(\.path),
            deviceFileIDs: items.deviceFileIDs,
            displayNames: items.displayNames,
            totalByteCount: items.totalByteCount
        )

        if !items.localURLs.isEmpty {
            let provider = MultiFileDragPayload.itemProvider(for: items.localURLs)
            if let data = try? JSONEncoder().encode(envelope) {
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

        if !items.deviceFileIDs.isEmpty {
            let provider = DeviceFileDragPayload.itemProvider(for: items.deviceFileIDs)
            if let data = try? JSONEncoder().encode(envelope) {
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

        return NSItemProvider()
    }

    static func load(
        from providers: [NSItemProvider],
        completion: @escaping (DragItemSet) -> Void
    ) {
        let group = DispatchGroup()
        let lock = NSLock()
        var envelope: Envelope?
        var deviceIDs: [String] = []

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                    defer { group.leave() }
                    guard let data,
                          let decoded = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
                    lock.lock()
                    envelope = decoded
                    lock.unlock()
                }
            }

            if provider.hasItemConformingToTypeIdentifier(DeviceFileDragPayload.typeIdentifier) {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: DeviceFileDragPayload.typeIdentifier) { data, _ in
                    defer { group.leave() }
                    guard let data,
                          let ids = try? JSONDecoder().decode([String].self, from: data) else { return }
                    lock.lock()
                    deviceIDs.append(contentsOf: ids)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            if let envelope {
                completion(
                    DragItemSet(
                        localURLs: envelope.localPaths.map { URL(fileURLWithPath: $0) },
                        deviceFileIDs: envelope.deviceFileIDs,
                        sourceKind: envelope.sourceKind,
                        totalByteCount: envelope.totalByteCount,
                        displayNames: envelope.displayNames
                    )
                )
                return
            }

            // Fall back to legacy payloads / Finder.
            if !deviceIDs.isEmpty {
                let uniqueIDs = orderedUnique(deviceIDs)
                completion(
                    DragItemSet(
                        localURLs: [],
                        deviceFileIDs: uniqueIDs,
                        sourceKind: .device,
                        totalByteCount: 0,
                        displayNames: uniqueIDs
                    )
                )
                return
            }

            MultiFileDragPayload.loadURLs(from: providers) { loaded in
                let kind: DragSourceKind = providers.contains {
                    $0.hasItemConformingToTypeIdentifier(MultiFileDragPayload.typeIdentifier)
                } ? .localFolder : .externalFinder

                let byteCount: Int64 = loaded.reduce(0) { partial, url in
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                    return partial + Int64(values?.fileSize ?? 0)
                }

                completion(
                    DragItemSet(
                        localURLs: loaded,
                        deviceFileIDs: [],
                        sourceKind: kind,
                        totalByteCount: byteCount,
                        displayNames: loaded.map(\.lastPathComponent)
                    )
                )
            }
        }
    }

    static var dropTypeIdentifiers: [String] {
        [
            typeIdentifier,
            DeviceFileDragPayload.typeIdentifier,
            MultiFileDragPayload.typeIdentifier,
            UTType.fileURL.identifier
        ]
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
