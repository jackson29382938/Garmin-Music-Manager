import AppKit
import Foundation

/// Watches for volume mount/unmount and periodically re-checks USB so MTP
/// watches (which often never mount) still surface after plug-in.
@MainActor
final class DeviceConnectMonitor {
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var lastUSBSignature: String = ""
    private var lastVolumeSignature: String = ""
    private let onChange: () -> Void
    /// Minimum interval between automatic refresh triggers.
    private let coalesceInterval: TimeInterval = 2.5
    private var lastFire = Date.distantPast

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        stop()
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.fireIfNeeded(force: true)
                }
            }
            workspaceObservers.append(token)
        }

        // MTP devices frequently never appear as volumes; poll USB signatures.
        let timer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        timer.tolerance = 1.5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        lastVolumeSignature = currentVolumeSignature()
        lastUSBSignature = currentUSBSignature()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            center.removeObserver(token)
        }
        workspaceObservers.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        let volumes = currentVolumeSignature()
        let usb = currentUSBSignature()
        if volumes != lastVolumeSignature || usb != lastUSBSignature {
            lastVolumeSignature = volumes
            lastUSBSignature = usb
            fireIfNeeded(force: false)
        }
    }

    private func fireIfNeeded(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastFire) >= coalesceInterval else { return }
        lastFire = now
        lastVolumeSignature = currentVolumeSignature()
        lastUSBSignature = currentUSBSignature()
        onChange()
    }

    private func currentVolumeSignature() -> String {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.map(\.path).sorted().joined(separator: "\n")
    }

    /// Lightweight USB identity string (vendor/product/serial) without full refresh cost.
    private func currentUSBSignature() -> String {
        // IORegistry-only — avoids multi-second system_profiler on every poll tick.
        DeviceDetector().connectedGarminUSBSignature()
    }
}
