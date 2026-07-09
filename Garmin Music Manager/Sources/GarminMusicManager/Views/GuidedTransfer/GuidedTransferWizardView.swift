import SwiftUI

/// Full-screen Guided Transfer wizard: one step at a time.
struct GuidedTransferWizardView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: GuidedTransferSession
    var onExit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stepIndicator
            Divider()
            ScrollView {
                stepContent
                    .padding(28)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.transferProgress) { _, snap in
            if session.isTransferring {
                session.transferProgress = snap
            }
        }
        .onChange(of: model.isSyncing) { _, syncing in
            if session.isTransferring, !syncing, session.step == .transferProgress {
                // Keep session in control; completion handled in session task after sync returns.
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.title2)
                .foregroundStyle(AppTheme.garminTint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Guided Transfer")
                    .font(.title2.bold())
                Text("Simple step-by-step music transfer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            watchPill
            Button("Exit wizard") {
                session.cancelWizard(model: model)
                onExit()
            }
            .help("Return to the normal Transfer interface")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var watchPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.destinationIsReady ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(watchLabel)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Watch: \(watchLabel)")
    }

    private var watchLabel: String {
        if model.destinationIsReady {
            return model.connectedMTPDeviceName
                ?? model.connectedUSBDevices.first?.displayName
                ?? model.selectedDevice?.volumeName
                ?? "Watch ready"
        }
        if !model.connectedUSBDevices.isEmpty {
            return "Detected — needs setup"
        }
        return "No watch"
    }

    private var stepIndicator: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(GuidedWizardStep.progressSteps.enumerated()), id: \.element.id) { index, s in
                    if index > 0 {
                        Rectangle()
                            .fill(s <= session.step ? AppTheme.garminTint.opacity(0.5) : Color.secondary.opacity(0.2))
                            .frame(width: 20, height: 2)
                    }
                    VStack(spacing: 4) {
                        Image(systemName: s.systemImage)
                            .font(.caption)
                            .foregroundStyle(stepColor(s))
                        Text(s.title)
                            .font(.caption2)
                            .foregroundStyle(s == session.step ? .primary : .secondary)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 72)
                    .accessibilityLabel("Step \(index + 1): \(s.title)\(s == session.step ? ", current" : "")")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color.primary.opacity(0.03))
        .accessibilityElement(children: .contain)
    }

    private func stepColor(_ s: GuidedWizardStep) -> Color {
        if s == session.step { return AppTheme.garminTint }
        if s < session.step { return .green }
        return .secondary
    }

    @ViewBuilder
    private var stepContent: some View {
        switch session.step {
        case .pairWatch:
            pairStep
        case .chooseMode:
            modeStep
        case .analyze:
            analyzeStep
        case .reviewPlan:
            reviewStep
        case .confirmPlan:
            confirmStep
        case .transferProgress:
            progressStep
        case .completeSummary:
            completeStep
        case .errorRecovery:
            errorStep
        }
    }

    private var footer: some View {
        HStack {
            if canGoBack {
                Button("Back") {
                    session.goBack(model: model)
                }
                .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if let err = session.errorMessage, session.step != .errorRecovery {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            primaryButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var canGoBack: Bool {
        switch session.step {
        case .pairWatch, .transferProgress, .completeSummary:
            return false
        case .errorRecovery:
            return true
        default:
            return true
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch session.step {
        case .pairWatch:
            Button("Continue") {
                session.continueFromPair(model: model)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.garminTint)
            .disabled(!session.pairIsReady(model: model))
            .keyboardShortcut(.defaultAction)

        case .chooseMode:
            EmptyView()

        case .analyze:
            ProgressView()
                .controlSize(.small)

        case .reviewPlan:
            Button("Continue to confirm") {
                session.continueToConfirm()
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.garminTint)
            .keyboardShortcut(.defaultAction)

        case .confirmPlan:
            Button("Start Transfer") {
                session.startTransfer(model: model)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.garminTint)
            .keyboardShortcut(.defaultAction)
            .disabled(session.plan?.willExceedStorage == true)

        case .transferProgress:
            Button("Cancel transfer", role: .destructive) {
                session.cancelTransfer(model: model)
            }

        case .completeSummary:
            Button("Done — back to app") {
                session.reset()
                onExit()
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.garminTint)
            .keyboardShortcut(.defaultAction)

        case .errorRecovery:
            Button("Try again") {
                session.errorMessage = nil
                session.step = .pairWatch
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.garminTint)
        }
    }

    // MARK: - Steps

    private var pairStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("First, connect the watch you want to transfer music with.")
                .font(.title3.bold())
            Text("Use a data USB cable, unlock the watch, and close Garmin Express or Android File Transfer if they are open.")
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    if model.destinationIsReady {
                        Label(watchLabel, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.headline)
                        Text(model.destinationDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let free = model.deviceBrowser.storageInfo?.availableCapacity {
                            Text("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free on watch")
                                .font(.caption)
                        }
                    } else if !model.connectedUSBDevices.isEmpty {
                        Label("Watch detected over USB", systemImage: "cable.connector")
                            .foregroundStyle(.orange)
                        Text(model.mtpDependencyStatus.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if model.mtpDependencyStatus.canInstallViaHomebrew {
                            Button("Install MTP") {
                                model.installMTPDependencies()
                            }
                        }
                        Button("Choose music folder…") {
                            model.chooseCustomGarminFolder()
                        }
                    } else {
                        Label("No watch connected", systemImage: "applewatch.slash")
                            .foregroundStyle(.secondary)
                        Text("Plug in the Garmin and click Refresh.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        model.refreshDevices()
                        if model.canAttemptMTP {
                            model.browseGarminMusicLibrary()
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isBrowsingDevice || model.deviceBrowser.isRefreshing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            if !model.devices.isEmpty {
                Text("Mounted volumes")
                    .font(.subheadline.weight(.semibold))
                ForEach(model.devices) { device in
                    Button {
                        model.selectDevice(device)
                    } label: {
                        HStack {
                            Image(systemName: model.selectedDevice?.id == device.id ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) {
                                Text(device.volumeName)
                                Text(device.storageDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var modeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What do you want to do?")
                .font(.title3.bold())
            Text("Nothing is copied until you review and confirm a plan.")
                .foregroundStyle(.secondary)

            GroupBox("Mac library sources (for send / both-ways)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Guided Transfer can scan beyond the Transfer queue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(GuidedLibraryScanSource.allCases) { source in
                        Toggle(isOn: Binding(
                            get: { session.enabledScanSources.contains(source) },
                            set: { _ in session.toggleScanSource(source) }
                        )) {
                            Label(source.title, systemImage: source.systemImage)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            ForEach(GuidedTransferMode.allCases) { mode in
                Button {
                    session.selectMode(mode, model: model)
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: mode.systemImage)
                            .font(.title)
                            .foregroundStyle(AppTheme.garminTint)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(mode.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .background(AppTheme.garminTint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(AppTheme.garminTint.opacity(0.2), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint(mode.subtitle)
            }
        }
    }

    private var analyzeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Analyzing libraries…")
                .font(.title3.bold())
            Text("Scanning Mac sources and comparing with the watch. No files are moved yet.")
                .foregroundStyle(.secondary)
            ProgressView()
            Text(session.analysisProgress)
                .font(.caption)
                .foregroundStyle(.secondary)
            if session.catalogStats.uniqueTracks > 0 {
                Text(session.catalogStats.summaryLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Movement plan")
                .font(.title3.bold())
            Text("Review what will move. Resolve conflicts before continuing. Analysis only — nothing has been copied yet.")
                .foregroundStyle(.secondary)

            if let plan = session.plan {
                Text(plan.catalogStats.summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                planSummaryCards(plan)

                if plan.willExceedStorage {
                    Label("Selected “to watch” music may exceed free space.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }

                if !plan.conflictItems.isEmpty {
                    conflictSection(plan.conflictItems)
                }

                DisclosureGroup("Show all plan details", isExpanded: $session.showDetails) {
                    planDetailList(plan)
                }
                .padding(.top, 8)
            }
        }
    }

    private func conflictSection(_ conflicts: [GuidedPlanItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Conflicts (\(conflicts.count))", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("These look similar on Mac and watch but aren’t a perfect match. Choose what to do for each pair. Default is skip both.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(conflicts) { item in
                conflictCard(item)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        }
    }

    private func conflictCard(_ item: GuidedPlanItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            if let kind = item.matchKind {
                Text(kind)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.macTint)
                    Text(item.macLabel ?? "—")
                        .font(.caption)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Watch")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.garminTint)
                    Text(item.watchLabel ?? "—")
                        .font(.caption)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Picker(
                "Resolution",
                selection: Binding(
                    get: { item.resolution ?? .skipBoth },
                    set: { session.setConflictResolution(itemID: item.id, resolution: $0) }
                )
            ) {
                ForEach(GuidedConflictResolution.allCases) { res in
                    Text(res.title).tag(res)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("Conflict resolution for \(item.displayName)")

            Text((item.resolution ?? .skipBoth).help)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func planSummaryCards(_ plan: GuidedTransferPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                summaryChip(title: "To watch", value: "\(plan.toWatchItems.count)", tint: AppTheme.garminTint)
                summaryChip(title: "From watch", value: "\(plan.fromWatchItems.count)", tint: AppTheme.macTint)
                summaryChip(title: "Conflicts", value: "\(plan.conflictItems.count)", tint: .orange)
            }
            HStack(spacing: 12) {
                summaryChip(
                    title: "Already both",
                    value: "\(plan.items.filter { $0.bucket == .alreadyBoth }.count)",
                    tint: .secondary
                )
                summaryChip(
                    title: "Size to watch",
                    value: ByteCountFormatter.string(fromByteCount: plan.toWatchBytes, countStyle: .file),
                    tint: .secondary
                )
                if let free = plan.freeBytesOnWatch {
                    summaryChip(
                        title: "Watch free",
                        value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file),
                        tint: plan.willExceedStorage ? .orange : .green
                    )
                }
            }
        }
    }

    private func summaryChip(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(tint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func planDetailList(_ plan: GuidedTransferPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(GuidedPlanBucket.allCases.filter { $0 != .conflict }) { bucket in
                let bucketItems = plan.items.filter { $0.bucket == bucket }
                if !bucketItems.isEmpty {
                    Text(bucket.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(bucketItems.prefix(200)) { item in
                        HStack(alignment: .top) {
                            if bucket == .toWatch || bucket == .fromWatch {
                                Toggle("", isOn: Binding(
                                    get: { item.isIncluded },
                                    set: { _ in session.toggleInclude(itemID: item.id) }
                                ))
                                .labelsHidden()
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayName)
                                    .lineLimit(1)
                                if let reason = item.reason {
                                    Text(reason)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if item.byteCount > 0 {
                                Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm transfer")
                .font(.title3.bold())
            Text("This is the final check. Nothing will be deleted. Nothing will move until you press Start Transfer.")
                .foregroundStyle(.secondary)

            if let plan = session.plan {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        labeledRow("Watch", plan.watchDisplayName)
                        labeledRow("Mode", plan.mode.title)
                        labeledRow("Mac catalog", plan.catalogStats.summaryLine)
                        labeledRow("To watch", "\(plan.toWatchItems.count) track(s) · \(ByteCountFormatter.string(fromByteCount: plan.toWatchBytes, countStyle: .file))")
                        labeledRow("From watch", "\(plan.fromWatchItems.count) file(s) · \(ByteCountFormatter.string(fromByteCount: plan.fromWatchBytes, countStyle: .file))")
                        labeledRow("Conflicts resolved", "\(plan.conflictItems.filter { ($0.resolution ?? .skipBoth) != .skipBoth }.count) of \(plan.conflictItems.count)")
                        labeledRow("Skipped / not included", "\(plan.skippedItems.count)")
                        labeledRow("Overwrite", "Uses your Send settings (default: skip identical)")
                        labeledRow("Delete", "Never (this wizard does not delete)")
                        if plan.mode == .fromWatch || plan.mode == .bothWays {
                            labeledRow("Import folder", "~/Music/Garmin Imports")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if plan.willExceedStorage {
                    Label("Not enough free space on the watch for the selected send list.", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func labeledRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .font(.subheadline)
            Spacer()
        }
    }

    private var progressStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transferring…")
                .font(.title3.bold())
            Label("Do not disconnect the watch until this finishes.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)

            let snap = session.transferProgress ?? model.transferProgress
            ProgressView(value: snap?.fraction ?? model.syncProgress)
            HStack {
                Text(snap?.primaryLine ?? model.transferLog.last ?? "Working…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Text(snap?.percentLabel ?? "\(Int((model.syncProgress * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
            }
            if model.isManagingDeviceFiles, let op = model.deviceBrowser.operation {
                Text(op.primaryLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var completeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let summary = session.summary {
                Label(
                    summary.wasCancelled ? "Transfer cancelled" : (summary.failedCount > 0 ? "Finished with issues" : "Transfer complete"),
                    systemImage: summary.wasCancelled || summary.failedCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                .font(.title3.bold())
                .foregroundStyle(summary.failedCount > 0 || summary.wasCancelled ? .orange : .green)

                Text(summary.message)
                    .foregroundStyle(.secondary)

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        labeledRow("Watch", summary.watchName)
                        labeledRow("To watch", "\(summary.toWatchCount)")
                        labeledRow("From watch", "\(summary.fromWatchCount)")
                        labeledRow("Skipped", "\(summary.skippedCount)")
                        labeledRow("Failed", "\(summary.failedCount)")
                        labeledRow("Data", ByteCountFormatter.string(fromByteCount: summary.bytesTransferred, countStyle: .file))
                        labeledRow("Time", String(format: "%.0f s", summary.duration))
                        if let path = session.importDestinationPath {
                            labeledRow("Imports saved", path)
                        }
                    }
                }

                if !summary.failedNames.isEmpty {
                    DisclosureGroup("Failed items") {
                        ForEach(summary.failedNames, id: \.self) { name in
                            Text(name).font(.caption)
                        }
                    }
                }

                HStack {
                    Button("Start another transfer") {
                        session.reset()
                    }
                    if model.canRetryFailedTransfers {
                        Button("Retry failed (advanced)") {
                            onExit()
                            model.retryFailedTransfers()
                        }
                    }
                }
            }
        }
    }

    private var errorStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.bold())
                .foregroundStyle(.orange)
            Text(session.errorMessage ?? "Unknown error.")
                .foregroundStyle(.secondary)
            Text("You can go back and try again. Completed file copies are kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
