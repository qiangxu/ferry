import FerryKit
import SwiftUI

public func colorFromLabel(_ label: String?) -> Color {
    switch label {
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "blue": return .blue
    case "purple": return .purple
    case "gray": return .gray
    default: return .clear
    }
}

/// Identifies the bookmark being renamed, so the rename alert knows which one to save.
private struct RenameTarget: Identifiable {
    let id: UUID        // the bookmark id
    let favoriteID: UUID
}

struct FavoritesSidebar: View {
    @ObservedObject var model: AppModel
    @Binding var showConnect: Bool
    @Binding var editing: Favorite?
    @State private var renameTarget: RenameTarget?
    @State private var renameText: String = ""

    var body: some View {
        List {
            Section("Favorites") {
                ForEach(model.favorites) { fav in
                    if fav.bookmarks.isEmpty {
                        connectionRow(fav)
                    } else {
                        DisclosureGroup {
                            ForEach(fav.bookmarks) { bm in bookmarkRow(fav, bm) }
                        } label: {
                            connectionRow(fav)
                        }
                    }
                }
            }
        }
        .alert("Rename favorite", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let t = renameTarget { model.renameBookmark(t.id, in: t.favoriteID, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .toolbar {
            ToolbarItem {
                Button { editing = nil; showConnect = true } label: { Image(systemName: "plus") }
                    .help("New connection")
            }
        }
    }

    private func connectionRow(_ fav: Favorite) -> some View {
        HStack {
            Circle().fill(colorFromLabel(fav.colorLabel)).frame(width: 8, height: 8)
            VStack(alignment: .leading) {
                Text(fav.name).font(.body)
                Text("\(fav.username)@\(fav.host)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { Task { await model.session.connect(fav) } }
        .contextMenu {
            Button("Edit...") { editing = fav; showConnect = true }
            Button("Forget this host") {
                model.session.forgetHost(host: fav.host, port: fav.port)
                if let j = fav.jumpHost, !j.isEmpty {
                    model.session.forgetHost(host: j, port: fav.jumpPort)
                }
            }
            Button("Delete", role: .destructive) { model.remove(fav) }
        }
    }

    private func bookmarkRow(_ fav: Favorite, _ bm: DirBookmark) -> some View {
        HStack {
            Image(systemName: "folder").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(bm.name).font(.callout)
                Text(bm.path).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { Task { await model.session.connect(fav, overridePath: bm.path) } }
        .contextMenu {
            Button("Rename...") { renameText = bm.name; renameTarget = RenameTarget(id: bm.id, favoriteID: fav.id) }
            Button("Delete", role: .destructive) { model.removeBookmark(bm.id, from: fav.id) }
        }
    }
}
