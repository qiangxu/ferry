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

struct FavoritesSidebar: View {
    @ObservedObject var model: AppModel
    @Binding var showConnect: Bool
    @Binding var editing: Favorite?

    var body: some View {
        List {
            Section("Favorites") {
                ForEach(model.favorites) { fav in
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
                        Button("Delete", role: .destructive) { model.remove(fav) }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { editing = nil; showConnect = true } label: { Image(systemName: "plus") }
                    .help("New connection")
            }
        }
    }
}
