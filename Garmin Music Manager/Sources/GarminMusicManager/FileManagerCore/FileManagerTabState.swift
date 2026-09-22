import Foundation

struct FileManagerTab: Identifiable, Hashable, Codable {
    var id: UUID
    var title: String
    var path: String

    init(id: UUID = UUID(), title: String, path: String) {
        self.id = id
        self.title = title
        self.path = path
    }

    static func folder(_ url: URL) -> FileManagerTab {
        FileManagerTab(title: url.lastPathComponent, path: url.path)
    }
}

@MainActor
final class FileManagerTabState: ObservableObject {
    @Published var tabs: [FileManagerTab]
    @Published var selectedTabID: UUID?

    init(initial: URL) {
        let tab = FileManagerTab.folder(initial)
        tabs = [tab]
        selectedTabID = tab.id
    }

    var selectedTab: FileManagerTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    func open(_ url: URL, inNewTab: Bool) {
        if inNewTab {
            let tab = FileManagerTab.folder(url)
            tabs.append(tab)
            selectedTabID = tab.id
        } else if let id = selectedTabID, let idx = tabs.firstIndex(where: { $0.id == id }) {
            tabs[idx] = FileManagerTab(id: id, title: url.lastPathComponent, path: url.path)
        } else {
            let tab = FileManagerTab.folder(url)
            tabs = [tab]
            selectedTabID = tab.id
        }
    }

    func close(_ id: UUID) {
        guard tabs.count > 1 else { return }
        tabs.removeAll { $0.id == id }
        if selectedTabID == id {
            selectedTabID = tabs.first?.id
        }
    }

    func select(_ id: UUID) {
        selectedTabID = id
    }
}
