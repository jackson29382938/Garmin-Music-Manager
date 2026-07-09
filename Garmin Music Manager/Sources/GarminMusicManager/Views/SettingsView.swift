import GarminMusicCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Overwrite policy", selection: $model.syncSettings.overwritePolicy) {
                    ForEach(OverwritePolicy.allCases) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }

                Picker("Organization", selection: $model.syncSettings.organizationPolicy) {
                    ForEach(OrganizationPolicy.allCases) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }

                Toggle("Convert ALAC/FLAC to AAC", isOn: convertToggleBinding)
                Label(
                    model.isFFmpegAvailable
                        ? "ffmpeg found — conversion available"
                        : "ffmpeg not installed (brew install ffmpeg)",
                    systemImage: model.isFFmpegAvailable ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(model.isFFmpegAvailable ? .green : .orange)

                Toggle("Write playlist after send", isOn: $model.syncSettings.writePlaylist)
                Text("Mounted folders get an .m3u8 file next to the tracks (with correct subfolder paths). MTP sends create a native Garmin playlist when the watch supports it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("Always preview before send", isOn: $model.alwaysPreviewBeforeSend)
                Text("When off, Send starts immediately unless free space is low or files would be replaced.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Send", systemImage: "arrow.down.circle")
            }

            Section {
                TextField("Default playlist name", text: $model.playlistName)
            } header: {
                Label("Defaults", systemImage: "textformat")
            }

            Section {
                Toggle("Restore queue on launch", isOn: libraryBinding(\.restoreQueueOnLaunch))
                Picker("Select on import", selection: libraryBinding(\.importSelectionMode)) {
                    ForEach(ImportSelectionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("Skip duplicates when sending", isOn: libraryBinding(\.skipDuplicatesWhenSending))
                Toggle("Auto-deselect duplicates", isOn: libraryBinding(\.autoDeselectDuplicates))
                Picker("Duplicate matching", selection: libraryBinding(\.duplicateMatchMode)) {
                    ForEach(DuplicateMatchMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Stepper(
                    String(format: "Duration match ±%.1fs", model.librarySettings.durationMatchToleranceSeconds),
                    value: libraryBinding(\.durationMatchToleranceSeconds),
                    in: LibrarySettings.durationToleranceRange,
                    step: 0.5
                )
                .disabled(model.librarySettings.duplicateMatchMode != .smart)
                Toggle("Fast import (name + size only)", isOn: libraryBinding(\.fastImport))
                Stepper(
                    model.librarySettings.importConcurrency == 0
                        ? "Import concurrency: unlimited"
                        : "Import concurrency: \(model.librarySettings.importConcurrency)",
                    value: libraryBinding(\.importConcurrency),
                    in: LibrarySettings.importConcurrencyRange
                )
                Stepper(
                    "Large-file warning: \(model.librarySettings.largeFileWarningMB) MB",
                    value: libraryBinding(\.largeFileWarningMB),
                    in: LibrarySettings.largeFileWarningMBRange,
                    step: 25
                )
                Picker("When selection exceeds free space", selection: libraryBinding(\.storageExceedPolicy)) {
                    ForEach(StorageExceedPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                Picker("Default On Watch sort", selection: libraryBinding(\.defaultDeviceSort)) {
                    ForEach(DeviceFileSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                Toggle("Remember last app mode", isOn: libraryBinding(\.rememberLastAppMode))
            } header: {
                Label("Library", systemImage: "music.note.list")
            } footer: {
                Text("Import, selection, and duplicate-matching behavior for the Mac queue.")
            }

            Section {
                Picker("AAC sample rate", selection: conversionBinding(\.aacSampleRate)) {
                    ForEach(AACSampleRate.allCases) { rate in
                        Text(rate.title).tag(rate)
                    }
                }
                Toggle("Keep conversion cache", isOn: conversionBinding(\.keepConversionCache))
                Toggle("Clear cache after successful send", isOn: conversionBinding(\.clearCacheAfterSuccessfulSend))
                Toggle("Treat WAV as convertible", isOn: conversionBinding(\.convertWAV))
                TextField("Custom ffmpeg path (optional)", text: conversionBinding(\.customFFmpegPath))
                    .textFieldStyle(.roundedBorder)
                Text("Bitrate is under Performance. Cache lives in a temp folder and speeds re-sends of the same files.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Conversion", systemImage: "waveform")
            }

            Section {
                Toggle("Refresh device after send", isOn: lifecycleBinding(\.refreshDeviceAfterSend))
                Toggle("Release MTP helper after send", isOn: lifecycleBinding(\.releaseHelperAfterSend))
                TextField("Remote music root", text: lifecycleBinding(\.remoteMusicRoot))
                    .textFieldStyle(.roundedBorder)
                Picker("Playlist strategy", selection: lifecycleBinding(\.playlistWriteStrategy)) {
                    ForEach(PlaylistWriteStrategy.allCases) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                Toggle("Auto-retry failed transfers", isOn: lifecycleBinding(\.autoRetryFailedTransfers))
                Toggle("Notify when send finishes", isOn: lifecycleBinding(\.notifyOnSendComplete))
                    Text("Beeps and shows an in-app notice. System notification permission not required.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Lifecycle", systemImage: "arrow.triangle.2.circlepath")
            }

            Section {
                Picker("Destination mode", selection: Binding(
                    get: { model.destinationMode },
                    set: { mode in
                        if mode == .autoDetected {
                            model.useAutoDetectedDestination()
                        } else if model.destinationMode != .customFolder {
                            model.chooseCustomGarminFolder()
                        }
                    }
                )) {
                    Text("Auto-detected Garmin").tag(GarminDestinationMode.autoDetected)
                    Text("Custom folder").tag(GarminDestinationMode.customFolder)
                }

                if model.destinationMode == .customFolder {
                    Text(model.destinationDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("Choose Folder…") {
                        model.chooseCustomGarminFolder()
                    }
                }

                if let warning = model.destinationWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } header: {
                Label("Destination", systemImage: "folder")
            }

            Section {
                Toggle("Enable advanced full-storage explorer", isOn: $model.advancedStorageExplorerEnabled)

                Picker("Destructive confirmation", selection: $model.destructiveConfirmationMode) {
                    ForEach(DestructiveConfirmationMode.allCases) { mode in
                        Text(label(for: mode)).tag(mode)
                    }
                }

                if !model.advancedStorageExplorerEnabled {
                    Text("The On Watch browser stays music-focused by default. Full storage is hidden until this setting is enabled.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("On Watch Browser", systemImage: "applewatch")
            }

            Section {
                Picker("Preset", selection: performancePresetBinding) {
                    ForEach(PerformancePreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                Text(model.performanceSettings.matchedPreset.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Stepper(
                    "Listing reuse: \(model.performanceSettings.listingReuseLabel)",
                    value: listingReuseBinding,
                    in: PerformanceSettings.listingReuseRange,
                    step: 30
                )
                Text("0 = always re-list. Higher reuses a recent browse for faster sync planning.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Stepper(
                    "MTP keep-alive: \(model.performanceSettings.keepAliveLabel)",
                    value: keepAliveBinding,
                    in: PerformanceSettings.keepAliveRange,
                    step: 15
                )
                Text("Longer is better for multi-step transfers; shorter frees the watch for Garmin Express.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Stepper(
                    "Upload batch size: \(model.performanceSettings.uploadBatchSize)",
                    value: uploadBatchBinding,
                    in: PerformanceSettings.uploadBatchRange
                )
                Text("Larger batches are faster; smaller recover better if USB glitches.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("Auto-detect when devices connect", isOn: autoDetectBinding)
                Stepper(
                    "USB check: \(Int(model.performanceSettings.usbPollIntervalSeconds))s",
                    value: usbPollBinding,
                    in: PerformanceSettings.usbPollRange,
                    step: 1
                )
                .disabled(!model.performanceSettings.autoDetectDevices)

                Stepper(
                    "AAC bitrate: \(model.performanceSettings.aacBitrateKbps) kbps",
                    value: aacBitrateBinding,
                    in: PerformanceSettings.aacBitrateRange,
                    step: 32
                )
                Text("Used for ALAC/FLAC conversion and large-file compress. Lower = smaller files.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("Always re-list before sync", isOn: forceRefreshBinding)
                Text("Ignores listing reuse. Reliable for accuracy; slower on large libraries.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                DisclosureGroup("Advanced reliability & conversion") {
                    Stepper(
                        "MTP retries: \(model.performanceSettings.mtpRetryAttempts)",
                        value: retryAttemptsBinding,
                        in: PerformanceSettings.retryAttemptsRange
                    )
                    Stepper(
                        String(format: "Retry backoff: %.1fs", model.performanceSettings.mtpRetryBackoffSeconds),
                        value: retryBackoffBinding,
                        in: PerformanceSettings.retryBackoffRange,
                        step: 0.1
                    )
                    Stepper(
                        String(format: "Timeout scale: %.2f×", model.performanceSettings.operationTimeoutScale),
                        value: timeoutScaleBinding,
                        in: PerformanceSettings.timeoutScaleRange,
                        step: 0.25
                    )
                    Text("Fail-fast < 1.0 · Normal 1.0 · Patient > 1.0 for slow USB.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Toggle("Verify uploads after transfer", isOn: verifyUploadsBinding)
                    Text("Off is faster but may hide failed copies. Prefer on for Reliable.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Toggle("Compress large files to AAC", isOn: compressLargeBinding)
                    if model.performanceSettings.compressLargeFiles {
                        Stepper(
                            "Threshold: \(model.performanceSettings.convertLargeFilesOverMB) MB",
                            value: largeFileMBBinding,
                            in: 1...PerformanceSettings.largeFileMBRange.upperBound,
                            step: 10
                        )
                        Text("Requires ffmpeg. Applies even when Convert ALAC/FLAC is off.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Load playlist contents from watch", isOn: playlistContentsBinding)
                    Text("Downloads on-device .m3u bodies when browsing. Expensive on some watches.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button("Restore Balanced defaults") {
                    model.restorePerformanceDefaults()
                }
            } header: {
                Label("Performance", systemImage: "gauge.with.dots.needle.67percent")
            } footer: {
                Text("Presets apply a full template. Editing any control switches to Custom. Defaults match historical app behavior (Balanced).")
            }

            Section {
                Label(
                    model.mtpDependencyStatus.message,
                    systemImage: model.mtpDependencyStatus.isReady ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .foregroundStyle(model.mtpDependencyStatus.isReady ? .green : .orange)

                if !model.mtpDependencyStatus.isReady, model.mtpDependencyStatus.canInstallViaHomebrew {
                    Button {
                        model.installMTPDependencies()
                    } label: {
                        if model.isInstallingMTPDependencies {
                            Label("Installing MTP…", systemImage: "hourglass")
                        } else {
                            Label("Install MTP (Homebrew)", systemImage: "cable.connector")
                        }
                    }
                    .disabled(model.isInstallingMTPDependencies)
                }

                Text("Packaged builds bundle the Garmin helper and libmtp (no Homebrew required). Install MTP only when running from source without a system libmtp.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Label("MTP Backend", systemImage: "cable.connector")
            }

            Section {
                Text("Settings are saved automatically. The Settings tab and ⌘, window show the same preferences. Transfer → Advanced mirrors send-related toggles.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(role: .destructive) {
                    model.requestResetAppState()
                } label: {
                    Label("Clear Cache / Reset App", systemImage: "arrow.counterclockwise")
                }

                Text("Clears app selections, cached library data, logs, and temporary conversions without deleting music files.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }

            Section {
                Label("Local/owned files only", systemImage: "checkmark.shield")
                Label("No DRM removal", systemImage: "lock")
                Label("MTP sync supported", systemImage: "cable.connector")
                Text("Garmin Music Manager copies local audio to mounted Garmin folders and helper-backed Garmin MTP devices. Streaming-provider files may stay hidden or protected on the watch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("About", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding()
        .onAppear { model.refreshFFmpegAvailability() }
        .alert("Reset app state?", isPresented: $model.showResetConfirmation) {
            Button("Reset", role: .destructive) {
                model.resetAppState()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears app selections, cached library data, logs, and temporary conversions. It does not delete music files from this Mac or the Garmin.")
        }
    }

    private func label(for mode: DestructiveConfirmationMode) -> String {
        switch mode {
        case .always:
            return "Always"
        case .batchesOnly:
            return "Batches only"
        case .never:
            return "Never"
        }
    }

    private var convertToggleBinding: Binding<Bool> {
        Binding(
            get: { model.syncSettings.convertIncompatibleFormats },
            set: { enabled in
                model.syncSettings.convertIncompatibleFormats = enabled
                if enabled {
                    model.warnIfConversionNeedsFFmpeg()
                }
            }
        )
    }

    // MARK: - Generic settings bindings

    private func libraryBinding<T>(_ keyPath: WritableKeyPath<LibrarySettings, T>) -> Binding<T> {
        Binding(
            get: { model.librarySettings[keyPath: keyPath] },
            set: { value in
                var settings = model.librarySettings
                settings[keyPath: keyPath] = value
                settings.clamp()
                model.librarySettings = settings
            }
        )
    }

    private func conversionBinding<T>(_ keyPath: WritableKeyPath<ConversionSettings, T>) -> Binding<T> {
        Binding(
            get: { model.conversionSettings[keyPath: keyPath] },
            set: { value in
                var settings = model.conversionSettings
                settings[keyPath: keyPath] = value
                model.conversionSettings = settings
            }
        )
    }

    private func lifecycleBinding<T>(_ keyPath: WritableKeyPath<LifecycleSettings, T>) -> Binding<T> {
        Binding(
            get: { model.lifecycleSettings[keyPath: keyPath] },
            set: { value in
                var settings = model.lifecycleSettings
                settings[keyPath: keyPath] = value
                settings.clamp()
                model.lifecycleSettings = settings
            }
        )
    }

    // MARK: - Performance bindings

    private func updatePerformance(_ body: (inout PerformanceSettings) -> Void) {
        var settings = model.performanceSettings
        body(&settings)
        settings.clamp()
        model.performanceSettings = settings
    }

    private var performancePresetBinding: Binding<PerformancePreset> {
        Binding(
            get: { model.performanceSettings.matchedPreset },
            set: { preset in
                if preset == .custom { return }
                model.applyPerformancePreset(preset)
            }
        )
    }

    private var listingReuseBinding: Binding<TimeInterval> {
        Binding(
            get: { model.performanceSettings.listingReuseSeconds },
            set: { value in updatePerformance { $0.listingReuseSeconds = value } }
        )
    }

    private var keepAliveBinding: Binding<TimeInterval> {
        Binding(
            get: { model.performanceSettings.mtpSessionKeepAliveSeconds },
            set: { value in updatePerformance { $0.mtpSessionKeepAliveSeconds = value } }
        )
    }

    private var uploadBatchBinding: Binding<Int> {
        Binding(
            get: { model.performanceSettings.uploadBatchSize },
            set: { value in updatePerformance { $0.uploadBatchSize = value } }
        )
    }

    private var autoDetectBinding: Binding<Bool> {
        Binding(
            get: { model.performanceSettings.autoDetectDevices },
            set: { value in updatePerformance { $0.autoDetectDevices = value } }
        )
    }

    private var usbPollBinding: Binding<TimeInterval> {
        Binding(
            get: { model.performanceSettings.usbPollIntervalSeconds },
            set: { value in updatePerformance { $0.usbPollIntervalSeconds = value } }
        )
    }

    private var aacBitrateBinding: Binding<Int> {
        Binding(
            get: { model.performanceSettings.aacBitrateKbps },
            set: { value in updatePerformance { $0.aacBitrateKbps = value } }
        )
    }

    private var forceRefreshBinding: Binding<Bool> {
        Binding(
            get: { model.performanceSettings.forceRefreshBeforeSync },
            set: { value in updatePerformance { $0.forceRefreshBeforeSync = value } }
        )
    }

    private var verifyUploadsBinding: Binding<Bool> {
        Binding(
            get: { model.performanceSettings.verifyUploads },
            set: { value in updatePerformance { $0.verifyUploads = value } }
        )
    }

    private var compressLargeBinding: Binding<Bool> {
        Binding(
            get: { model.performanceSettings.compressLargeFiles },
            set: { value in
                updatePerformance {
                    $0.compressLargeFiles = value
                    if value && $0.convertLargeFilesOverMB <= 0 {
                        $0.convertLargeFilesOverMB = 50
                    }
                }
            }
        )
    }

    private var largeFileMBBinding: Binding<Int> {
        Binding(
            get: { model.performanceSettings.convertLargeFilesOverMB },
            set: { value in updatePerformance { $0.convertLargeFilesOverMB = value } }
        )
    }

    private var retryAttemptsBinding: Binding<Int> {
        Binding(
            get: { model.performanceSettings.mtpRetryAttempts },
            set: { value in updatePerformance { $0.mtpRetryAttempts = value } }
        )
    }

    private var retryBackoffBinding: Binding<TimeInterval> {
        Binding(
            get: { model.performanceSettings.mtpRetryBackoffSeconds },
            set: { value in updatePerformance { $0.mtpRetryBackoffSeconds = value } }
        )
    }

    private var timeoutScaleBinding: Binding<Double> {
        Binding(
            get: { model.performanceSettings.operationTimeoutScale },
            set: { value in updatePerformance { $0.operationTimeoutScale = value } }
        )
    }

    private var playlistContentsBinding: Binding<Bool> {
        Binding(
            get: { model.performanceSettings.includePlaylistContentsWhenBrowsing },
            set: { value in updatePerformance { $0.includePlaylistContentsWhenBrowsing = value } }
        )
    }
}
