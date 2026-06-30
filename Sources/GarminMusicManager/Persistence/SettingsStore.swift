import Foundation
import GarminMusicCore

final class SettingsStore {
    private let defaults: UserDefaults

    private enum Keys {
        static let lastDestinationPath = "lastDestinationPath"
        static let playlistName = "playlistName"
        static let overwritePolicy = "overwritePolicy"
        static let organizationPolicy = "organizationPolicy"
        static let writePlaylist = "writePlaylist"
        static let advancedStorageExplorerEnabled = "advancedStorageExplorerEnabled"
        static let destructiveConfirmationMode = "destructiveConfirmationMode"
        static let lastDeviceBrowseMode = "lastDeviceBrowseMode"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastDestinationPath: String? {
        get { defaults.string(forKey: Keys.lastDestinationPath) }
        set { defaults.set(newValue, forKey: Keys.lastDestinationPath) }
    }

    var lastDestinationURL: URL? {
        guard let path = lastDestinationPath else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    var playlistName: String {
        get { defaults.string(forKey: Keys.playlistName) ?? "Garmin Playlist" }
        set { defaults.set(newValue, forKey: Keys.playlistName) }
    }

    var syncSettings: SyncSettings {
        get {
            SyncSettings(
                overwritePolicy: OverwritePolicy(rawValue: defaults.string(forKey: Keys.overwritePolicy) ?? "") ?? .skipIdentical,
                organizationPolicy: OrganizationPolicy(rawValue: defaults.string(forKey: Keys.organizationPolicy) ?? "") ?? .flat,
                writePlaylist: defaults.object(forKey: Keys.writePlaylist) as? Bool ?? true
            )
        }
        set {
            defaults.set(newValue.overwritePolicy.rawValue, forKey: Keys.overwritePolicy)
            defaults.set(newValue.organizationPolicy.rawValue, forKey: Keys.organizationPolicy)
            defaults.set(newValue.writePlaylist, forKey: Keys.writePlaylist)
        }
    }

    var advancedStorageExplorerEnabled: Bool {
        get { defaults.object(forKey: Keys.advancedStorageExplorerEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.advancedStorageExplorerEnabled) }
    }

    var destructiveConfirmationMode: DestructiveConfirmationMode {
        get {
            DestructiveConfirmationMode(rawValue: defaults.string(forKey: Keys.destructiveConfirmationMode) ?? "") ?? .batchesOnly
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.destructiveConfirmationMode)
        }
    }

    var lastDeviceBrowseMode: DeviceBrowseMode {
        get {
            DeviceBrowseMode(rawValue: defaults.string(forKey: Keys.lastDeviceBrowseMode) ?? "") ?? .musicOnly
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.lastDeviceBrowseMode)
        }
    }

    func saveDestination(_ url: URL?) {
        lastDestinationPath = url?.path
    }
}
