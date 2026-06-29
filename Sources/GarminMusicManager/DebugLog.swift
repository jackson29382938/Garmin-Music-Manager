import AppKit
import Foundation

enum DebugLog {
    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("GarminMusicManager/Logs", isDirectory: true)
    }

    static var fileURL: URL {
        directoryURL.appendingPathComponent("debug.log")
    }

    static func prepareLogDirectory() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    static func append(_ entry: LogEntry) {
        prepareLogDirectory()
        let line = entry.formatted + "\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func readAll() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    static func openInFinder() {
        prepareLogDirectory()
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}

extension NSPasteboard {
    static func copyString(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
