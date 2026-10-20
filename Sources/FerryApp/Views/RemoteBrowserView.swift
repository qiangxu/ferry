import FerryKit
import SwiftUI
import UniformTypeIdentifiers

struct RemoteBrowserView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: SessionViewModel
    @State private var selection: String?
    @State private var dropTargeted = false

    init(model: AppModel) {
        self.model = model
        self.session = model.session
    }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            Table(session.entries.sorted(by: Self.order), selection: $selection) {
                TableColumn("Name") { e in
                    Label(e.name, systemImage: e.isDirectory ? "folder" : "doc")
                }
                TableColumn("Size") { e in
                    Text(e.isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))
                }
                .width(80)
                TableColumn("Modified") { e in
                    Text(e.modified.formatted(date: .abbreviated, time: .shortened))
                }
                .width(150)
                TableColumn("Kind") { e in
                    Text(Self.kind(e))
                }
                .width(90)
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                guard let id = ids.first, let entry = session.entries.first(where: { $0.path == id }) else { return }
                Task { await session.open(entry) }
            }
            .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3) } }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in await session.upload(url) }
                    }
                }
                return true
            }
        }
    }

    private var pathBar: some View {
        HStack(spacing: 4) {
            Button { Task { await session.goUp() } } label: { Image(systemName: "chevron.up") }
                .help("Parent directory")
            let crumbs = Self.breadcrumbs(session.currentPath)
            ForEach(crumbs, id: \.path) { crumb in
                Button(crumb.name) { Task { await session.navigate(to: crumb.path) } }
                    .buttonStyle(.link)
                if crumb.path != crumbs.last?.path { Text("/").foregroundStyle(.secondary) }
            }
            Spacer()
            Button { addCurrentDirectoryToFavorites() } label: { Image(systemName: "bookmark") }
                .help("Save this directory as a favorite")
                .disabled(session.activeFavoriteID == nil)
        }
        .padding(8)
    }

    /// Saves the current directory as a second-level bookmark under the active connection.
    private func addCurrentDirectoryToFavorites() {
        guard let favoriteID = session.activeFavoriteID else { return }
        let path = session.currentPath
        let last = RemotePath.name(of: path)
        model.addBookmark(to: favoriteID, name: last.isEmpty ? path : last, path: path)
    }

    static func breadcrumbs(_ path: String) -> [(name: String, path: String)] {
        var result: [(String, String)] = [("/", "/")]
        var acc = ""
        for part in path.split(separator: "/") {
            acc += "/" + part
            result.append((String(part), acc))
        }
        return result
    }

    static func order(_ a: RemoteEntry, _ b: RemoteEntry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    static func kind(_ e: RemoteEntry) -> String {
        if e.isDirectory { return "Folder" }
        let ext = (e.name as NSString).pathExtension
        return ext.isEmpty ? "File" : ext.uppercased()
    }
}

extension RemoteEntry: Identifiable {
    public var id: String { path }
}
