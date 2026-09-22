import Foundation
import GarminMusicCore

struct FilePropertiesModel: Identifiable, Hashable {
    var id: String
    var name: String
    var path: String
    var kind: String
    var size: Int64
    var modified: Date?
    var extra: [String: String]

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static func local(_ entry: LocalFolderEntry) -> FilePropertiesModel {
        FilePropertiesModel(
            id: entry.id,
            name: entry.name,
            path: entry.url.path,
            kind: entry.kind.rawValue,
            size: entry.size,
            modified: entry.modifiedDate,
            extra: ["URL": entry.url.absoluteString]
        )
    }

    static func device(_ file: DeviceFile) -> FilePropertiesModel {
        var extra: [String: String] = [:]
        if let objectID = file.objectID { extra["Object ID"] = objectID }
        if let artist = file.audioMetadata?.artist { extra["Artist"] = artist }
        if let album = file.audioMetadata?.album { extra["Album"] = album }
        return FilePropertiesModel(
            id: file.id,
            name: file.name,
            path: file.path.isEmpty ? file.name : file.path,
            kind: file.type.rawValue,
            size: file.size,
            modified: file.modifiedDate,
            extra: extra
        )
    }
}
