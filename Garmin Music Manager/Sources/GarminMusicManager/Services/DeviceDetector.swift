import Foundation

final class DeviceDetector {
    private let fileManager = FileManager.default

    private static let garminModelKeywords = [
        "garmin", "fenix", "forerunner", "venu", "epix", "instinct", "vivoactive", "approach"
    ]

    func findGarminDevices() -> [GarminDevice] {
        findGarminDevices(in: mountedVolumeURLs())
    }

    func findConnectedGarminUSBDevices() -> [GarminUSBDevice] {
        let profilerDevices = systemProfilerUSBTree()
            .filter { isGarminUSBCandidate($0) }
            .map { item in
                GarminUSBDevice(
                    id: item.id,
                    name: item.name,
                    manufacturer: item.manufacturer,
                    vendorID: item.vendorID,
                    productID: item.productID,
                    serialNumber: item.serialNumber
                )
            }

        return dedupeGarminUSBDevices(profilerDevices)
    }

    private func dedupeGarminUSBDevices(_ devices: [GarminUSBDevice]) -> [GarminUSBDevice] {
        var byKey: [String: GarminUSBDevice] = [:]
        for device in devices {
            let key = device.dedupeKey
            if let existing = byKey[key] {
                if device.displayName.count > existing.displayName.count {
                    byKey[key] = device
                }
            } else {
                byKey[key] = device
            }
        }
        return Array(byKey.values)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func findGarminDevices(in mountedVolumes: [URL]) -> [GarminDevice] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .isVolumeKey
        ]

        return mountedVolumes.compactMap { volumeURL in
            guard let values = try? volumeURL.resourceValues(forKeys: Set(keys)) else { return nil }
            let volumeName = values.volumeName ?? volumeURL.lastPathComponent
            let musicDirs = candidateMusicDirectories(for: volumeURL)
            let looksLikeGarmin = isGarminCandidate(volumeName: volumeName, volumeURL: volumeURL, musicDirs: musicDirs)

            guard looksLikeGarmin else { return nil }

            return GarminDevice(
                id: volumeURL.path,
                volumeName: volumeName,
                rootURL: volumeURL,
                totalCapacity: values.volumeTotalCapacity.map { Int64($0) },
                availableCapacity: values.volumeAvailableCapacityForImportantUsage.map { Int64($0) },
                candidateMusicDirectories: musicDirs.isEmpty ? [volumeURL] : musicDirs
            )
        }
        .sorted { $0.volumeName.localizedCaseInsensitiveCompare($1.volumeName) == .orderedAscending }
    }

    private func mountedVolumeURLs() -> [URL] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .isVolumeKey
        ]
        return fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
    }

    private func isGarminCandidate(volumeName: String, volumeURL: URL, musicDirs: [URL]) -> Bool {
        let lowerName = volumeName.lowercased()
        if Self.garminModelKeywords.contains(where: { lowerName.contains($0) }) {
            return true
        }
        if fileManager.fileExists(atPath: volumeURL.appendingPathComponent("GARMIN").path) {
            return true
        }
        return !musicDirs.isEmpty
    }

    private func candidateMusicDirectories(for root: URL) -> [URL] {
        let candidates = [
            root.appendingPathComponent("GARMIN/Music", isDirectory: true),
            root.appendingPathComponent("Music", isDirectory: true),
            root.appendingPathComponent("Garmin/Music", isDirectory: true),
            root.appendingPathComponent("Primary/Music", isDirectory: true),
            root.appendingPathComponent("Internal Storage/Music", isDirectory: true),
            root.appendingPathComponent("Media/Music", isDirectory: true)
        ]
        return candidates.filter { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private func isGarminUSBCandidate(_ item: USBProfilerItem) -> Bool {
        let haystack = [item.name, item.manufacturer, item.vendorID, item.productID]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return Self.garminModelKeywords.contains { haystack.contains($0) }
            || haystack.contains("091e") // Garmin's USB vendor ID.
    }

    private func systemProfilerUSBTree() -> [USBProfilerItem] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPUSBDataType", "-json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0 else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let usbItems = root["SPUSBDataType"] as? [[String: Any]]
        else {
            return []
        }

        var result: [USBProfilerItem] = []
        collectUSBProfilerItems(usbItems, into: &result)
        return result
    }

    private func collectUSBProfilerItems(_ dictionaries: [[String: Any]], into result: inout [USBProfilerItem]) {
        for dictionary in dictionaries {
            if let item = USBProfilerItem(dictionary: dictionary) {
                result.append(item)
            }
            if let children = dictionary["_items"] as? [[String: Any]] {
                collectUSBProfilerItems(children, into: &result)
            }
        }
    }

}

private struct USBProfilerItem {
    let id: String
    let name: String
    let manufacturer: String?
    let vendorID: String?
    let productID: String?
    let serialNumber: String?

    init?(dictionary: [String: Any]) {
        guard let name = dictionary["_name"] as? String, !name.isEmpty else { return nil }
        self.name = name
        self.manufacturer = dictionary["manufacturer"] as? String
        self.vendorID = dictionary["vendor_id"] as? String
        self.productID = dictionary["product_id"] as? String
        self.serialNumber = dictionary["serial_num"] as? String
        self.id = [name, manufacturer, vendorID, productID, serialNumber]
            .compactMap { $0 }
            .joined(separator: "|")
    }
}
