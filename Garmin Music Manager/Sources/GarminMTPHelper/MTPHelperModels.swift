import CLibMTP
import Foundation
import GarminMusicCore

struct RawDeviceDescriptor {
    let index: Int
    let vendor: String
    let product: String
    let vendorID: UInt16
    let productID: UInt16
    let busLocation: UInt32
    let deviceNumber: UInt8

    init(_ rawDevice: LIBMTP_raw_device_t, index: Int) {
        self.index = index
        self.vendor = string(from: rawDevice.device_entry.vendor) ?? ""
        self.product = string(from: rawDevice.device_entry.product) ?? ""
        self.vendorID = rawDevice.device_entry.vendor_id
        self.productID = rawDevice.device_entry.product_id
        self.busLocation = rawDevice.bus_location
        self.deviceNumber = rawDevice.devnum
    }

    var isGarmin: Bool {
        vendorID == MTPDirectSession.garminVendorID
            || vendor.localizedCaseInsensitiveContains("garmin")
            || product.localizedCaseInsensitiveContains("garmin")
            || product.localizedCaseInsensitiveContains("forerunner")
    }

    var displayName: String {
        let combined = [vendor, product]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !combined.isEmpty {
            return combined
        }
        return "Garmin device"
    }
}

struct MTPFileRecord {
    let id: UInt32
    let parentID: UInt32
    let storageID: UInt32
    let name: String
    let size: UInt64
    let modifiedDate: Date?
    let fileType: LIBMTP_filetype_t
}

struct MTPTrackRecord {
    let id: UInt32
    let parentID: UInt32
    let storageID: UInt32
    let fileName: String
    let size: UInt64
    let modifiedDate: Date?
    let fileType: LIBMTP_filetype_t
    let metadata: DeviceAudioMetadata
}

struct MTPPlaylistRecord {
    let id: UInt32
    let name: String
    let trackIDs: [UInt32]
}

struct MTPFolderRecord {
    let id: UInt32
    let parentID: UInt32
    let storageID: UInt32
    let name: String
    let path: String
}

struct MTPUploadedFile {
    let displayName: String
    let remotePath: String
    let size: Int64
    let objectID: UInt32?
}

struct MTPFolderLocation {
    let id: UInt32
    let storageID: UInt32
    let path: String
}

struct MTPFolderIndex {
    let root: MTPFolderLocation
    private var byPath: [String: MTPFolderLocation] = [:]
    private var byID: [UInt32: MTPFolderLocation] = [:]

    init(rootStorageID: UInt32) {
        self.root = MTPFolderLocation(
            id: LIBMTP_FILES_AND_FOLDERS_ROOT,
            storageID: rootStorageID,
            path: ""
        )
        insert(root)
    }

    mutating func insert(_ location: MTPFolderLocation) {
        byPath[folderKey(location.path)] = location
        byID[location.id] = location
    }

    func location(path: String) -> MTPFolderLocation? {
        byPath[folderKey(path)]
    }

    func location(id: UInt32) -> MTPFolderLocation? {
        byID[id]
    }
}

func joinPath(_ parent: String, _ child: String) -> String {
    let cleanParent = parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let cleanChild = child.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if cleanParent.isEmpty { return cleanChild }
    if cleanChild.isEmpty { return cleanParent }
    return "\(cleanParent)/\(cleanChild)"
}

func folderKey(_ path: String) -> String {
    path
        .replacingOccurrences(of: "\\", with: "/")
        .trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
        .lowercased()
}

func string(from pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    return String(cString: pointer)
}

func string(from pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    return String(cString: pointer)
}

func copyStringAndFree(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    defer { LIBMTP_FreeMemory(UnsafeMutableRawPointer(pointer)) }
    return String(cString: pointer)
}

func duplicatedCString(_ value: String?) -> UnsafeMutablePointer<CChar>? {
    guard let value, !value.isEmpty else { return nil }
    return strdup(value)
}
