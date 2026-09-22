import Foundation

enum FileManagerPane: String, Hashable, Sendable {
    case mac
    case garmin
}

enum FileClipboardMode: String, Hashable, Sendable {
    case copy
    case cut
}

/// In-app clipboard for File Manager / On Watch (local URLs and/or device file IDs).
@MainActor
final class FileClipboard: ObservableObject {
    @Published private(set) var mode: FileClipboardMode = .copy
    @Published private(set) var localURLs: [URL] = []
    @Published private(set) var deviceFileIDs: [String] = []
    @Published private(set) var displayNames: [String] = []
    @Published private(set) var sourcePane: FileManagerPane?

    var isEmpty: Bool { localURLs.isEmpty && deviceFileIDs.isEmpty }

    var summary: String {
        guard !isEmpty else { return "Clipboard empty" }
        let count = max(localURLs.count, deviceFileIDs.count)
        let verb = mode == .cut ? "Cut" : "Copied"
        return "\(verb) \(count) item(s)"
    }

    func copyLocal(_ urls: [URL], names: [String], from pane: FileManagerPane) {
        mode = .copy
        localURLs = urls.map(\.standardizedFileURL)
        deviceFileIDs = []
        displayNames = names
        sourcePane = pane
    }

    func cutLocal(_ urls: [URL], names: [String], from pane: FileManagerPane) {
        mode = .cut
        localURLs = urls.map(\.standardizedFileURL)
        deviceFileIDs = []
        displayNames = names
        sourcePane = pane
    }

    func copyDevice(ids: [String], names: [String], from pane: FileManagerPane) {
        mode = .copy
        localURLs = []
        deviceFileIDs = ids
        displayNames = names
        sourcePane = pane
    }

    func cutDevice(ids: [String], names: [String], from pane: FileManagerPane) {
        mode = .cut
        localURLs = []
        deviceFileIDs = ids
        displayNames = names
        sourcePane = pane
    }

    func clear() {
        localURLs = []
        deviceFileIDs = []
        displayNames = []
        sourcePane = nil
        mode = .copy
    }

    /// After a successful cut-paste, clear clipboard.
    func consumeIfCut() {
        if mode == .cut { clear() }
    }
}
