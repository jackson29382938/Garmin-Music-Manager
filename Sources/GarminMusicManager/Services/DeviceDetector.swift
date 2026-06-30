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
        let mtpDevices = libMTPDetectedDevices()
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

        let candidates = mtpDevices.isEmpty ? profilerDevices : mtpDevices + profilerDevices
        return dedupeGarminUSBDevices(candidates)
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

    private func libMTPDetectedDevices() -> [GarminUSBDevice] {
        guard let mtpDetectURL = executableURL(named: "mtp-detect") else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "'\(mtpDetectURL.path)' 2>&1 | /usr/bin/sed -n '1,120p'"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(8)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                process.terminate()
                return []
            }
        } catch {
            return []
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return parseLibMTPDetectOutput(output)
    }

    private func executableURL(named executableName: String) -> URL? {
        let searchPaths = [
            "/opt/homebrew/bin", // Apple Silicon Homebrew
            "/usr/local/bin",    // Intel Homebrew
            "/usr/bin",
            "/bin"
        ]

        for directory in searchPaths {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(executableName)
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func parseLibMTPDetectOutput(_ output: String) -> [GarminUSBDevice] {
        var devices: [GarminUSBDevice] = []
        var currentVendorID: String?
        var currentProductID: String?
        var currentProduct: String?
        var manufacturer: String?
        var model: String?
        var serialNumber: String?

        func flush() {
            let name = model ?? currentProduct
            guard let name else { return }
            let haystack = [manufacturer, name, currentVendorID, currentProductID]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            guard Self.garminModelKeywords.contains(where: { haystack.contains($0) }) || haystack.contains("091e") else { return }

            devices.append(GarminUSBDevice(
                id: [manufacturer, name, currentVendorID, currentProductID, serialNumber]
                    .compactMap { $0 }
                    .joined(separator: "|"),
                name: name,
                manufacturer: manufacturer ?? "Garmin",
                vendorID: currentVendorID,
                productID: currentProductID,
                serialNumber: serialNumber
            ))
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Device ") {
                flush()
                currentVendorID = firstCapture(in: line, pattern: #"VID=([0-9a-fA-F]+)"#)
                currentProductID = firstCapture(in: line, pattern: #"PID=([0-9a-fA-F]+)"#)
                currentProduct = firstCapture(in: line, pattern: #"is a (.+)\.$"#)
                manufacturer = nil
                model = nil
                serialNumber = nil
            } else if line.hasPrefix("Manufacturer:") {
                manufacturer = value(afterColonIn: line)
            } else if line.hasPrefix("Model:") {
                model = value(afterColonIn: line)
            } else if line.hasPrefix("Serial number:") {
                serialNumber = value(afterColonIn: line)
            }
        }
        flush()

        var devicesByID: [String: GarminUSBDevice] = [:]
        for device in devices {
            devicesByID[device.id] = device
        }
        return Array(devicesByID.values)
    }

    private func value(afterColonIn line: String) -> String? {
        guard let range = line.range(of: ":") else { return nil }
        let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard
            let match = regex.firstMatch(in: text, range: range),
            match.numberOfRanges > 1,
            let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[captureRange])
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
