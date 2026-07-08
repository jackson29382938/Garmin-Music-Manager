import Foundation
import GarminMusicCore

/// Writes throttled `{"progress":...}` NDJSON lines to the helper response stream.
final class MTPProgressReporter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var lastFraction: Double = -1
    private var lastEmit = Date.distantPast
    private let minInterval: TimeInterval = 0.08
    private let minFractionDelta: Double = 0.01

    init(handle: FileHandle) {
        self.handle = handle
    }

    func report(_ event: MTPProgressEvent, force: Bool = false) {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        let fractionDelta = abs(event.overallFraction - lastFraction)
        let isBoundary = event.bytesTransferred == 0
            || (event.bytesTotal.map { event.bytesTransferred == $0 } ?? false)
            || event.overallFraction >= 0.999

        if !force && !isBoundary {
            if fractionDelta < minFractionDelta && now.timeIntervalSince(lastEmit) < minInterval {
                return
            }
        }

        lastFraction = event.overallFraction
        lastEmit = now

        do {
            var data = try MTPProgressLineEncoder.encode(event)
            data.append(0x0A)
            handle.write(data)
            try handle.synchronize()
        } catch {
            // Progress is best-effort; never fail the transfer because of reporting.
        }
    }

    func itemStarted(
        phase: String,
        itemIndex: Int,
        itemCount: Int,
        itemName: String,
        bytesTotal: Int64?,
        completedBytesBeforeItem: Int64,
        totalBatchBytes: Int64
    ) {
        let overall = overallFraction(
            completedBytesBeforeItem: completedBytesBeforeItem,
            itemSent: 0,
            itemTotal: bytesTotal ?? 0,
            totalBatchBytes: totalBatchBytes,
            itemIndex: itemIndex,
            itemCount: itemCount
        )
        report(
            MTPProgressEvent(
                phase: phase,
                itemIndex: itemIndex,
                itemCount: itemCount,
                itemName: itemName,
                bytesTransferred: 0,
                bytesTotal: bytesTotal,
                overallFraction: overall,
                message: "\(phaseLabel(phase)) \(itemIndex + 1)/\(itemCount): \(itemName)"
            ),
            force: true
        )
    }

    func itemFinished(
        phase: String,
        itemIndex: Int,
        itemCount: Int,
        itemName: String,
        bytesTotal: Int64?,
        completedBytesBeforeItem: Int64,
        totalBatchBytes: Int64
    ) {
        let itemBytes = max(bytesTotal ?? 0, 0)
        let overall = overallFraction(
            completedBytesBeforeItem: completedBytesBeforeItem,
            itemSent: itemBytes,
            itemTotal: itemBytes,
            totalBatchBytes: totalBatchBytes,
            itemIndex: itemIndex,
            itemCount: itemCount
        )
        report(
            MTPProgressEvent(
                phase: phase,
                itemIndex: itemIndex,
                itemCount: itemCount,
                itemName: itemName,
                bytesTransferred: bytesTotal,
                bytesTotal: bytesTotal,
                overallFraction: overall,
                message: "Finished \(itemIndex + 1)/\(itemCount): \(itemName)"
            ),
            force: true
        )
    }

    func makeBridge(
        phase: String,
        itemIndex: Int,
        itemCount: Int,
        itemName: String,
        itemBytes: Int64,
        completedBytesBeforeItem: Int64,
        totalBatchBytes: Int64
    ) -> LibMTPProgressBridge {
        LibMTPProgressBridge(
            reporter: self,
            phase: phase,
            itemIndex: itemIndex,
            itemCount: itemCount,
            itemName: itemName,
            itemBytes: itemBytes,
            completedBytesBeforeItem: completedBytesBeforeItem,
            totalBatchBytes: totalBatchBytes
        )
    }

    fileprivate func overallFraction(
        completedBytesBeforeItem: Int64,
        itemSent: Int64,
        itemTotal: Int64,
        totalBatchBytes: Int64,
        itemIndex: Int,
        itemCount: Int
    ) -> Double {
        if totalBatchBytes > 0 {
            return Double(completedBytesBeforeItem + max(itemSent, 0)) / Double(totalBatchBytes)
        }
        // Fall back to equal item weighting when sizes are unknown.
        let count = max(itemCount, 1)
        let itemPortion = itemTotal > 0 ? Double(itemSent) / Double(itemTotal) : 0
        return (Double(itemIndex) + itemPortion) / Double(count)
    }

    private func phaseLabel(_ phase: String) -> String {
        switch phase {
        case "upload": return "Uploading"
        case "download": return "Downloading"
        case "delete": return "Deleting"
        default: return phase.capitalized
        }
    }
}

/// Context object passed to libmtp's C progress callback.
final class LibMTPProgressBridge: @unchecked Sendable {
    private let reporter: MTPProgressReporter
    private let phase: String
    private let itemIndex: Int
    private let itemCount: Int
    private let itemName: String
    private let itemBytes: Int64
    private let completedBytesBeforeItem: Int64
    private let totalBatchBytes: Int64

    init(
        reporter: MTPProgressReporter,
        phase: String,
        itemIndex: Int,
        itemCount: Int,
        itemName: String,
        itemBytes: Int64,
        completedBytesBeforeItem: Int64,
        totalBatchBytes: Int64
    ) {
        self.reporter = reporter
        self.phase = phase
        self.itemIndex = itemIndex
        self.itemCount = itemCount
        self.itemName = itemName
        self.itemBytes = itemBytes
        self.completedBytesBeforeItem = completedBytesBeforeItem
        self.totalBatchBytes = totalBatchBytes
    }

    func emit(sent: UInt64, total: UInt64) {
        let itemTotal = total > 0 ? Int64(total) : itemBytes
        let itemSent = Int64(sent)
        let overall = reporter.overallFraction(
            completedBytesBeforeItem: completedBytesBeforeItem,
            itemSent: itemSent,
            itemTotal: itemTotal,
            totalBatchBytes: totalBatchBytes,
            itemIndex: itemIndex,
            itemCount: itemCount
        )
        let verb = phase == "download" ? "Downloading" : "Uploading"
        reporter.report(
            MTPProgressEvent(
                phase: phase,
                itemIndex: itemIndex,
                itemCount: itemCount,
                itemName: itemName,
                bytesTransferred: itemSent,
                bytesTotal: itemTotal > 0 ? itemTotal : nil,
                overallFraction: overall,
                message: "\(verb) \(itemIndex + 1)/\(itemCount): \(itemName)"
            )
        )
    }
}

/// Global trampoline for `LIBMTP_progressfunc_t`.
/// Returns 0 to continue; non-zero aborts the current libmtp transfer.
let libmtpProgressTrampoline: @convention(c) (UInt64, UInt64, UnsafeRawPointer?) -> Int32 = { sent, total, data in
    if MTPCancelState.isCancelled {
        return 1
    }
    guard let data else { return 0 }
    let bridge = Unmanaged<LibMTPProgressBridge>.fromOpaque(data).takeUnretainedValue()
    bridge.emit(sent: sent, total: total)
    return MTPCancelState.isCancelled ? 1 : 0
}
