import Foundation

struct GarminDevice: Identifiable, Hashable {
    let id: String
    let volumeName: String
    let rootURL: URL
    let totalCapacity: Int64?
    let availableCapacity: Int64?
    let candidateMusicDirectories: [URL]

    var bestMusicDirectory: URL? {
        candidateMusicDirectories.first
    }

    var storageDescription: String {
        guard let totalCapacity, let availableCapacity else { return "Storage unknown" }
        let total = ByteCountFormatter.string(fromByteCount: totalCapacity, countStyle: .file)
        let available = ByteCountFormatter.string(fromByteCount: availableCapacity, countStyle: .file)
        return "\(available) free of \(total)"
    }

    var usedCapacity: Int64? {
        guard let totalCapacity, let availableCapacity else { return nil }
        return max(0, totalCapacity - availableCapacity)
    }

    var usageFraction: Double? {
        guard let totalCapacity, totalCapacity > 0, let availableCapacity else { return nil }
        let used = Double(totalCapacity - availableCapacity)
        return used / Double(totalCapacity)
    }
}

struct GarminUSBDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let manufacturer: String?
    let vendorID: String?
    let productID: String?
    let serialNumber: String?

    var displayName: String {
        let lower = name.lowercased()
        let generic = lower == "unnamed device" || lower == "usb device" || lower == "composite device" || lower == "garmin watch"
        let looksGarmin = isLikelyGarmin
        if looksGarmin && (generic || name.isEmpty) {
            return "Garmin watch"
        }
        if let manufacturer, !name.localizedCaseInsensitiveContains(manufacturer) {
            return "\(manufacturer) \(name)"
        }
        return name
    }

    /// True when vendor/product/name fields point at a Garmin gadget.
    var isLikelyGarmin: Bool {
        let vendor = vendorID?.lowercased() ?? ""
        if vendor.contains("091e") || vendor == "2334" || vendor == "0x091e" {
            return true
        }
        let haystack = [name, manufacturer, vendorID, productID]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return haystack.contains("garmin")
            || haystack.contains("fenix")
            || haystack.contains("forerunner")
            || haystack.contains("venu")
            || haystack.contains("epix")
            || haystack.contains("instinct")
            || haystack.contains("vivoactive")
            || haystack.contains("approach")
    }

    /// Collapses duplicate USB/MTP entries for the same physical watch.
    var dedupeKey: String {
        if let serialNumber = serialNumber?.lowercased(), !serialNumber.isEmpty {
            return "serial:\(serialNumber)"
        }
        let normalized = name.lowercased()
            .replacingOccurrences(of: "garmin", with: "")
            .replacingOccurrences(of: "solar", with: "")
            .replacingOccurrences(of: " ", with: "")
        return "name:\(normalized)"
    }
}
