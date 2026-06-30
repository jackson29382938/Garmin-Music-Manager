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
        if let manufacturer, !name.localizedCaseInsensitiveContains(manufacturer) {
            return "\(manufacturer) \(name)"
        }
        return name
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
