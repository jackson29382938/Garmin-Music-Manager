import Foundation

final class DeviceDetector {
    private let fileManager = FileManager.default

    private static let garminModelKeywords = [
        "garmin", "fenix", "forerunner", "venu", "epix", "instinct", "vivoactive", "approach"
    ]
    /// Garmin International USB vendor ID (0x091e / decimal 2334).
    static let garminVendorIDHex = "091e"
    static let garminVendorIDDecimal = 0x091e

    func findGarminDevices() -> [GarminDevice] {
        findGarminDevices(in: mountedVolumeURLs())
    }

    /// USB/MTP watches that never mount under `/Volumes`. Uses IORegistry first
    /// (reliable on Apple Silicon) and merges `system_profiler` when it has better names.
    func findConnectedGarminUSBDevices() -> [GarminUSBDevice] {
        var items = ioregUSBDevices()
        // system_profiler is slower; still useful on older macOS / for friendlier names.
        let profilerItems = systemProfilerUSBTree()
        if !profilerItems.isEmpty {
            items.append(contentsOf: profilerItems)
        }

        let devices = items
            .filter { isGarminUSBCandidate($0) }
            .map { item in
                GarminUSBDevice(
                    id: item.id,
                    name: item.displayName,
                    manufacturer: item.manufacturer ?? (item.isGarminVendor ? "Garmin" : nil),
                    vendorID: item.vendorID,
                    productID: item.productID,
                    serialNumber: item.serialNumber
                )
            }

        return dedupeGarminUSBDevices(devices)
    }

    /// Lightweight identity string for connect-monitor polling (IORegistry only).
    func connectedGarminUSBSignature() -> String {
        ioregUSBDevices()
            .filter { isGarminUSBCandidate($0) }
            .map { item in
                if let serial = item.serialNumber?.lowercased(), !serial.isEmpty {
                    return "serial:\(serial)"
                }
                return "vid:\(item.normalizedVendorID ?? "")|pid:\(item.normalizedProductID ?? "")|\(item.name.lowercased())"
            }
            .sorted()
            .joined(separator: "\n")
    }

    private func dedupeGarminUSBDevices(_ devices: [GarminUSBDevice]) -> [GarminUSBDevice] {
        var byKey: [String: GarminUSBDevice] = [:]
        for device in devices {
            let key = device.dedupeKey
            if let existing = byKey[key] {
                // Prefer a concrete product name over "Garmin watch" / "Unnamed Device".
                if deviceNameQuality(device) > deviceNameQuality(existing) {
                    byKey[key] = device
                }
            } else {
                byKey[key] = device
            }
        }
        return Array(byKey.values)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func deviceNameQuality(_ device: GarminUSBDevice) -> Int {
        let lower = device.name.lowercased()
        if lower == "unnamed device" || lower == "usb device" || lower == "composite device" {
            return 0
        }
        if lower == "garmin watch" || lower == "garmin" {
            return 1
        }
        if Self.garminModelKeywords.contains(where: { lower.contains($0) && $0 != "garmin" }) {
            return 3
        }
        return 2
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
        if item.isGarminVendor {
            return true
        }
        let haystack = [item.name, item.manufacturer, item.vendorID, item.productID]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return Self.garminModelKeywords.contains { haystack.contains($0) }
    }

    // MARK: - system_profiler

    /// Apple Silicon macOS often leaves `SPUSBDataType` empty; devices live under `SPUSBHostDataType`
    /// with `USBDeviceKey*` property names instead of classic `vendor_id` / `product_id`.
    private func systemProfilerUSBTree() -> [USBProfilerItem] {
        var result: [USBProfilerItem] = []
        for dataType in ["SPUSBDataType", "SPUSBHostDataType"] {
            result.append(contentsOf: systemProfilerUSBTree(dataType: dataType))
        }
        return result
    }

    private func systemProfilerUSBTree(dataType: String) -> [USBProfilerItem] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = [dataType, "-json"]

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
            let usbItems = root[dataType] as? [[String: Any]]
        else {
            return []
        }

        var result: [USBProfilerItem] = []
        collectUSBProfilerItems(usbItems, into: &result)
        return result
    }

    private func collectUSBProfilerItems(_ dictionaries: [[String: Any]], into result: inout [USBProfilerItem]) {
        for dictionary in dictionaries {
            if let item = USBProfilerItem(profilerDictionary: dictionary) {
                result.append(item)
            }
            if let children = dictionary["_items"] as? [[String: Any]] {
                collectUSBProfilerItems(children, into: &result)
            }
        }
    }

    // MARK: - IORegistry

    private func ioregUSBDevices() -> [USBProfilerItem] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        // XML/plist of IOUSBHostDevice nodes — works when system_profiler SPUSBDataType is empty.
        process.arguments = ["-c", "IOUSBHostDevice", "-r", "-l", "-a"]

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
        guard !data.isEmpty else { return [] }

        let root: Any
        do {
            root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            return []
        }

        var result: [USBProfilerItem] = []
        collectIoregItems(root, into: &result)
        return result
    }

    private func collectIoregItems(_ node: Any, into result: inout [USBProfilerItem]) {
        if let dictionary = node as? [String: Any] {
            if let item = USBProfilerItem(ioregDictionary: dictionary) {
                result.append(item)
            }
            if let children = dictionary["IORegistryEntryChildren"] as? [Any] {
                for child in children {
                    collectIoregItems(child, into: &result)
                }
            }
        } else if let array = node as? [Any] {
            for element in array {
                collectIoregItems(element, into: &result)
            }
        }
    }
}

// MARK: - USBProfilerItem

/// Normalized USB device fields from system_profiler JSON or IORegistry plist.
struct USBProfilerItem: Equatable {
    let id: String
    let name: String
    let manufacturer: String?
    let vendorID: String?
    let productID: String?
    let serialNumber: String?

    var normalizedVendorID: String? {
        Self.normalizeHexID(vendorID)
    }

    var normalizedProductID: String? {
        Self.normalizeHexID(productID)
    }

    var isGarminVendor: Bool {
        normalizedVendorID == DeviceDetector.garminVendorIDHex
    }

    /// Prefer a human-readable label when the host reports "Unnamed Device".
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let generic = lower.isEmpty
            || lower == "unnamed device"
            || lower == "usb device"
            || lower == "composite device"
        if isGarminVendor && generic {
            return "Garmin watch"
        }
        return trimmed.isEmpty ? "USB device" : trimmed
    }

    init?(profilerDictionary dictionary: [String: Any]) {
        guard let rawName = dictionary["_name"] as? String, !rawName.isEmpty else { return nil }
        // Skip pure bus/controller nodes that never carry product IDs.
        let vendor = Self.stringValue(
            dictionary["vendor_id"]
                ?? dictionary["USBDeviceKeyVendorID"]
                ?? dictionary["usb_vendor_id"]
        )
        let product = Self.stringValue(
            dictionary["product_id"]
                ?? dictionary["USBDeviceKeyProductID"]
                ?? dictionary["usb_product_id"]
        )
        let serial = Self.stringValue(
            dictionary["serial_num"]
                ?? dictionary["USBDeviceKeySerialNumber"]
                ?? dictionary["serial_number"]
        )
        let manufacturer = Self.stringValue(
            dictionary["manufacturer"]
                ?? dictionary["USBDeviceKeyManufacturer"]
        )

        // Bus controllers list as "_name": "USB 3.1 Bus" with no vendor/product — drop them.
        if vendor == nil && product == nil && serial == nil {
            let lower = rawName.lowercased()
            if lower.contains("bus") || lower.contains("xhci") || lower.contains("hub") {
                return nil
            }
        }

        self.name = rawName
        self.manufacturer = manufacturer
        self.vendorID = vendor
        self.productID = product
        self.serialNumber = serial
        self.id = [rawName, manufacturer, vendor, product, serial]
            .compactMap { $0 }
            .joined(separator: "|")
    }

    init?(ioregDictionary dictionary: [String: Any]) {
        guard let vendorNum = Self.intValue(dictionary["idVendor"]) else { return nil }
        let productNum = Self.intValue(dictionary["idProduct"])
        // Interfaces under a host device may repeat vendor without being a distinct gadget;
        // require a product id for a real device node.
        guard let productNum else { return nil }

        let vendorHex = String(format: "%04x", vendorNum)
        let productHex = String(format: "%04x", productNum)
        let serial = Self.stringValue(
            dictionary["USB Serial Number"]
                ?? dictionary["kUSBSerialNumberString"]
                ?? dictionary["USB Serial Number String"]
        )
        let productName = Self.stringValue(
            dictionary["USB Product Name"]
                ?? dictionary["kUSBProductString"]
                ?? dictionary["USB Product Name String"]
        )
        let manufacturer = Self.stringValue(
            dictionary["USB Vendor Name"]
                ?? dictionary["kUSBVendorString"]
                ?? dictionary["USB Vendor Name String"]
        )
        let location = Self.stringValue(dictionary["locationID"]) ?? Self.stringValue(dictionary["IORegistryEntryLocation"])

        self.name = productName ?? "Unnamed Device"
        self.manufacturer = manufacturer
        self.vendorID = "0x\(vendorHex)"
        self.productID = "0x\(productHex)"
        self.serialNumber = serial
        self.id = [self.name, manufacturer, self.vendorID, self.productID, serial, location]
            .compactMap { $0 }
            .joined(separator: "|")
    }

    /// Test helper for constructing items without shelling out.
    init(
        name: String,
        manufacturer: String? = nil,
        vendorID: String? = nil,
        productID: String? = nil,
        serialNumber: String? = nil
    ) {
        self.name = name
        self.manufacturer = manufacturer
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.id = [name, manufacturer, vendorID, productID, serialNumber]
            .compactMap { $0 }
            .joined(separator: "|")
    }

    static func normalizeHexID(_ raw: String?) -> String? {
        guard var value = raw?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        // system_profiler sometimes appends a name: "0x091e (Garmin International)".
        if let space = value.firstIndex(of: " ") {
            value = String(value[..<space])
        }
        if value.hasPrefix("0x") {
            value.removeFirst(2)
        }
        // Decimal forms (ioreg sometimes surfaces as decimal strings in mixed paths).
        if value.allSatisfy(\.isNumber), let number = Int(value), number <= 0xFFFF {
            return String(format: "%04x", number)
        }
        // Keep only hex digits.
        value = value.filter { $0.isHexDigit }
        guard !value.isEmpty else { return nil }
        if value.count < 4 {
            value = String(repeating: "0", count: 4 - value.count) + value
        }
        return value
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        case let int as Int:
            return String(int)
        case let int64 as Int64:
            return String(int64)
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let int64 as Int64:
            return Int(int64)
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("0x") {
                return Int(trimmed.dropFirst(2), radix: 16)
            }
            return Int(trimmed)
        default:
            return nil
        }
    }
}
