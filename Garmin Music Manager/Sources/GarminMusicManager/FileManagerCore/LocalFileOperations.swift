import AppKit
import Foundation
import UniformTypeIdentifiers

enum LocalFileSort: String, CaseIterable, Identifiable, Codable {
    case name
    case size
    case date
    case kind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .date: return "Date"
        case .kind: return "Kind"
        }
    }
}

enum LocalViewMode: String, CaseIterable, Identifiable, Codable {
    case list
    case icons

    var id: String { rawValue }
}

enum LocalUndoAction {
    case move(from: URL, to: URL)
    case rename(from: URL, to: URL)
    case trash(original: URL, trashURL: URL)
}

/// Native Mac filesystem operations for the File Manager pane.
enum LocalFileOperations {
    struct Result: Sendable {
        var completed: Int
        var failed: Int
        var message: String
        var undo: LocalUndoAction?
    }

    static func createFolder(named name: String, in folder: URL) throws -> URL {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = clean.isEmpty ? "New Folder" : clean
        var url = folder.appendingPathComponent(finalName)
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(finalName) \(index)")
            index += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func rename(_ url: URL, to newName: String) throws -> (URL, LocalUndoAction) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let dest = url.deletingLastPathComponent().appendingPathComponent(clean)
        if FileManager.default.fileExists(atPath: dest.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.moveItem(at: url, to: dest)
        return (dest, .rename(from: dest, to: url))
    }

    static func trash(_ urls: [URL]) throws -> Result {
        var completed = 0
        var failed = 0
        var lastUndo: LocalUndoAction?
        for url in urls {
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                completed += 1
                if let trashURL = resulting as URL? {
                    lastUndo = .trash(original: url, trashURL: trashURL)
                }
            } catch {
                failed += 1
            }
        }
        return Result(
            completed: completed,
            failed: failed,
            message: failed == 0 ? "Moved \(completed) item(s) to Trash." : "Trashed \(completed), failed \(failed).",
            undo: lastUndo
        )
    }

    static func duplicate(_ urls: [URL]) throws -> Result {
        var completed = 0
        var failed = 0
        for url in urls {
            let dest = FileNameCollision.keepBothURL(for: url.lastPathComponent, in: url.deletingLastPathComponent())
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                completed += 1
            } catch {
                failed += 1
            }
        }
        return Result(
            completed: completed,
            failed: failed,
            message: "Duplicated \(completed) item(s).",
            undo: nil
        )
    }

    static func copy(_ urls: [URL], to folder: URL) throws -> Result {
        var completed = 0
        var failed = 0
        for url in urls {
            let dest = uniqueURL(for: url.lastPathComponent, in: folder)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                completed += 1
            } catch {
                failed += 1
            }
        }
        return Result(completed: completed, failed: failed, message: "Copied \(completed) item(s).", undo: nil)
    }

    static func move(_ urls: [URL], to folder: URL) throws -> Result {
        var completed = 0
        var failed = 0
        var lastUndo: LocalUndoAction?
        for url in urls {
            let dest = uniqueURL(for: url.lastPathComponent, in: folder)
            do {
                try FileManager.default.moveItem(at: url, to: dest)
                completed += 1
                lastUndo = .move(from: dest, to: url)
            } catch {
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    try FileManager.default.removeItem(at: url)
                    completed += 1
                    lastUndo = .move(from: dest, to: url)
                } catch {
                    failed += 1
                }
            }
        }
        return Result(completed: completed, failed: failed, message: "Moved \(completed) item(s).", undo: lastUndo)
    }

    static func undo(_ action: LocalUndoAction) throws {
        switch action {
        case let .move(from, to), let .rename(from, to):
            if FileManager.default.fileExists(atPath: to.path) {
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.moveItem(at: from, to: to)
        case let .trash(original, trashURL):
            let dest = original
            if FileManager.default.fileExists(atPath: dest.path) {
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.moveItem(at: trashURL, to: dest)
        }
    }

    static func compress(_ urls: [URL], into folder: URL) throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        let zipURL = folder.appendingPathComponent("Archive-\(stamp).zip")
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = folder
        var args = ["-r", "-q", zipURL.lastPathComponent]
        args.append(contentsOf: urls.map(\.lastPathComponent))
        // Prefer paths relative to folder when possible.
        args = ["-r", "-q", zipURL.path] + urls.map(\.path)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: zipURL.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return zipURL
    }

    static func decompress(_ zipURL: URL, into folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", zipURL.path, "-d", folder.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private static func uniqueURL(for fileName: String, in folder: URL) -> URL {
        let candidate = folder.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return FileNameCollision.keepBothURL(for: fileName, in: folder)
    }
}
