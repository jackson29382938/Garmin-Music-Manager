import Foundation
import GarminMusicCore

final class SettingsStore {
    private let defaults: UserDefaults

    private enum Keys {
        static let lastDestinationPath = "lastDestinationPath"
        static let destinationMode = "destinationMode"
        static let playlistName = "playlistName"
        static let overwritePolicy = "overwritePolicy"
        static let organizationPolicy = "organizationPolicy"
        static let writePlaylist = "writePlaylist"
        static let convertIncompatibleFormats = "convertIncompatibleFormats"
        static let advancedStorageExplorerEnabled = "advancedStorageExplorerEnabled"
        static let destructiveConfirmationMode = "destructiveConfirmationMode"
        static let lastDeviceBrowseMode = "lastDeviceBrowseMode"
        static let alwaysPreviewBeforeSend = "alwaysPreviewBeforeSend"
        static let listingReuseSeconds = "performance.listingReuseSeconds"
        static let mtpSessionKeepAliveSeconds = "performance.mtpSessionKeepAliveSeconds"
        static let uploadBatchSize = "performance.uploadBatchSize"
        static let autoDetectDevices = "performance.autoDetectDevices"
        static let usbPollIntervalSeconds = "performance.usbPollIntervalSeconds"
        static let aacBitrateKbps = "performance.aacBitrateKbps"
        static let forceRefreshBeforeSync = "performance.forceRefreshBeforeSync"
        static let mtpRetryAttempts = "performance.mtpRetryAttempts"
        static let mtpRetryBackoffSeconds = "performance.mtpRetryBackoffSeconds"
        static let operationTimeoutScale = "performance.operationTimeoutScale"
        static let compressLargeFiles = "performance.compressLargeFiles"
        static let convertLargeFilesOverMB = "performance.convertLargeFilesOverMB"
        static let includePlaylistContentsWhenBrowsing = "performance.includePlaylistContentsWhenBrowsing"
        static let verifyUploads = "performance.verifyUploads"
        static let librarySettingsJSON = "librarySettings.v1"
        static let conversionSettingsJSON = "conversionSettings.v1"
        static let lifecycleSettingsJSON = "lifecycleSettings.v1"
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

    var destinationMode: GarminDestinationMode {
        get {
            GarminDestinationMode(rawValue: defaults.string(forKey: Keys.destinationMode) ?? "") ?? .autoDetected
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.destinationMode)
        }
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
                writePlaylist: defaults.object(forKey: Keys.writePlaylist) as? Bool ?? true,
                convertIncompatibleFormats: defaults.object(forKey: Keys.convertIncompatibleFormats) as? Bool ?? false
            )
        }
        set {
            defaults.set(newValue.overwritePolicy.rawValue, forKey: Keys.overwritePolicy)
            defaults.set(newValue.organizationPolicy.rawValue, forKey: Keys.organizationPolicy)
            defaults.set(newValue.writePlaylist, forKey: Keys.writePlaylist)
            defaults.set(newValue.convertIncompatibleFormats, forKey: Keys.convertIncompatibleFormats)
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

    /// When true (default), Send opens a preview sheet. Power users can disable it.
    var alwaysPreviewBeforeSend: Bool {
        get {
            if defaults.object(forKey: Keys.alwaysPreviewBeforeSend) == nil { return true }
            return defaults.bool(forKey: Keys.alwaysPreviewBeforeSend)
        }
        set { defaults.set(newValue, forKey: Keys.alwaysPreviewBeforeSend) }
    }

    var performanceSettings: PerformanceSettings {
        get {
            let d = PerformanceSettings.default
            var settings = PerformanceSettings(
                listingReuseSeconds: (defaults.object(forKey: Keys.listingReuseSeconds) as? Double) ?? d.listingReuseSeconds,
                mtpSessionKeepAliveSeconds: (defaults.object(forKey: Keys.mtpSessionKeepAliveSeconds) as? Double) ?? d.mtpSessionKeepAliveSeconds,
                uploadBatchSize: (defaults.object(forKey: Keys.uploadBatchSize) as? Int) ?? d.uploadBatchSize,
                autoDetectDevices: defaults.object(forKey: Keys.autoDetectDevices) as? Bool ?? d.autoDetectDevices,
                usbPollIntervalSeconds: (defaults.object(forKey: Keys.usbPollIntervalSeconds) as? Double) ?? d.usbPollIntervalSeconds,
                aacBitrateKbps: (defaults.object(forKey: Keys.aacBitrateKbps) as? Int) ?? d.aacBitrateKbps,
                forceRefreshBeforeSync: defaults.object(forKey: Keys.forceRefreshBeforeSync) as? Bool ?? d.forceRefreshBeforeSync,
                mtpRetryAttempts: (defaults.object(forKey: Keys.mtpRetryAttempts) as? Int) ?? d.mtpRetryAttempts,
                mtpRetryBackoffSeconds: (defaults.object(forKey: Keys.mtpRetryBackoffSeconds) as? Double) ?? d.mtpRetryBackoffSeconds,
                operationTimeoutScale: (defaults.object(forKey: Keys.operationTimeoutScale) as? Double) ?? d.operationTimeoutScale,
                compressLargeFiles: defaults.object(forKey: Keys.compressLargeFiles) as? Bool ?? d.compressLargeFiles,
                convertLargeFilesOverMB: (defaults.object(forKey: Keys.convertLargeFilesOverMB) as? Int) ?? d.convertLargeFilesOverMB,
                includePlaylistContentsWhenBrowsing: defaults.object(forKey: Keys.includePlaylistContentsWhenBrowsing) as? Bool
                    ?? d.includePlaylistContentsWhenBrowsing,
                verifyUploads: defaults.object(forKey: Keys.verifyUploads) as? Bool ?? d.verifyUploads
            )
            settings.clamp()
            return settings
        }
        set {
            var value = newValue
            value.clamp()
            defaults.set(value.listingReuseSeconds, forKey: Keys.listingReuseSeconds)
            defaults.set(value.mtpSessionKeepAliveSeconds, forKey: Keys.mtpSessionKeepAliveSeconds)
            defaults.set(value.uploadBatchSize, forKey: Keys.uploadBatchSize)
            defaults.set(value.autoDetectDevices, forKey: Keys.autoDetectDevices)
            defaults.set(value.usbPollIntervalSeconds, forKey: Keys.usbPollIntervalSeconds)
            defaults.set(value.aacBitrateKbps, forKey: Keys.aacBitrateKbps)
            defaults.set(value.forceRefreshBeforeSync, forKey: Keys.forceRefreshBeforeSync)
            defaults.set(value.mtpRetryAttempts, forKey: Keys.mtpRetryAttempts)
            defaults.set(value.mtpRetryBackoffSeconds, forKey: Keys.mtpRetryBackoffSeconds)
            defaults.set(value.operationTimeoutScale, forKey: Keys.operationTimeoutScale)
            defaults.set(value.compressLargeFiles, forKey: Keys.compressLargeFiles)
            defaults.set(value.convertLargeFilesOverMB, forKey: Keys.convertLargeFilesOverMB)
            defaults.set(value.includePlaylistContentsWhenBrowsing, forKey: Keys.includePlaylistContentsWhenBrowsing)
            defaults.set(value.verifyUploads, forKey: Keys.verifyUploads)
        }
    }

    var librarySettings: LibrarySettings {
        get {
            if let data = defaults.data(forKey: Keys.librarySettingsJSON),
               var decoded = try? JSONDecoder().decode(LibrarySettings.self, from: data) {
                decoded.clamp()
                return decoded
            }
            return .default
        }
        set {
            var value = newValue
            value.clamp()
            if let data = try? JSONEncoder().encode(value) {
                defaults.set(data, forKey: Keys.librarySettingsJSON)
            }
        }
    }

    var conversionSettings: ConversionSettings {
        get {
            if let data = defaults.data(forKey: Keys.conversionSettingsJSON),
               let decoded = try? JSONDecoder().decode(ConversionSettings.self, from: data) {
                return decoded
            }
            return .default
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.conversionSettingsJSON)
            }
        }
    }

    var lifecycleSettings: LifecycleSettings {
        get {
            if let data = defaults.data(forKey: Keys.lifecycleSettingsJSON),
               var decoded = try? JSONDecoder().decode(LifecycleSettings.self, from: data) {
                decoded.clamp()
                return decoded
            }
            return .default
        }
        set {
            var value = newValue
            value.clamp()
            if let data = try? JSONEncoder().encode(value) {
                defaults.set(data, forKey: Keys.lifecycleSettingsJSON)
            }
        }
    }

    func saveDestination(_ url: URL?) {
        lastDestinationPath = url?.path
    }

    func resetAppState() {
        defaults.removeObject(forKey: Keys.lastDestinationPath)
        destinationMode = .autoDetected
    }

    func resetAllSettings() {
        for key in [
            Keys.lastDestinationPath,
            Keys.destinationMode,
            Keys.playlistName,
            Keys.overwritePolicy,
            Keys.organizationPolicy,
            Keys.writePlaylist,
            Keys.convertIncompatibleFormats,
            Keys.advancedStorageExplorerEnabled,
            Keys.destructiveConfirmationMode,
            Keys.lastDeviceBrowseMode,
            Keys.alwaysPreviewBeforeSend,
            Keys.listingReuseSeconds,
            Keys.mtpSessionKeepAliveSeconds,
            Keys.uploadBatchSize,
            Keys.autoDetectDevices,
            Keys.usbPollIntervalSeconds,
            Keys.aacBitrateKbps,
            Keys.forceRefreshBeforeSync,
            Keys.mtpRetryAttempts,
            Keys.mtpRetryBackoffSeconds,
            Keys.operationTimeoutScale,
            Keys.compressLargeFiles,
            Keys.convertLargeFilesOverMB,
            Keys.includePlaylistContentsWhenBrowsing,
            Keys.verifyUploads,
            Keys.librarySettingsJSON,
            Keys.conversionSettingsJSON,
            Keys.lifecycleSettingsJSON
        ] {
            defaults.removeObject(forKey: key)
        }
    }
}
