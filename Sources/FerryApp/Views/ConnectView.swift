import FerryKit
import SwiftUI
import AppKit

struct ConnectView: View {
    @ObservedObject var model: AppModel
    let initial: Favorite?
    let dismiss: () -> Void

    @State private var id = UUID()
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var useKey = false
    @State private var password = ""
    @State private var keyPath = ""
    @State private var path = "/"
    @State private var note = ""
    @State private var color = "none"

    private static let colors = ["none", "red", "orange", "yellow", "green", "blue", "purple", "gray"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                LabeledContent("Protocol") { Text("SFTP").foregroundStyle(.secondary) }
                TextField("Server", text: $host)
                TextField("Port", text: $port)
                TextField("Username", text: $username)
                Picker("Auth", selection: $useKey) {
                    Text("Password").tag(false)
                    Text("Private key").tag(true)
                }
                .pickerStyle(.segmented)
                if useKey {
                    HStack {
                        TextField("Private key path", text: $keyPath)
                        Button("Choose...") { chooseKey() }
                    }
                } else {
                    SecureField("Password", text: $password)
                }
                TextField("Path", text: $path)
                TextField("Note", text: $note)
                Picker("Color", selection: $color) {
                    ForEach(Self.colors, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add to Favorites") { _ = save() }
                    .disabled(!valid)
                Button("Connect") {
                    if let fav = save() {
                        dismiss()
                        Task { await model.session.connect(fav) }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: load)
    }

    private var valid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(port) != nil
    }

    private func load() {
        guard let f = initial else { return }
        id = f.id
        host = f.host
        port = String(f.port)
        username = f.username
        useKey = f.auth == .privateKey
        keyPath = f.privateKeyPath ?? ""
        path = f.initialPath
        note = f.note
        color = f.colorLabel ?? "none"
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url { keyPath = url.path }
    }

    /// Persists the favorite (metadata to the store, password to Keychain only).
    private func save() -> Favorite? {
        let h = host.trimmingCharacters(in: .whitespaces)
        let u = username.trimmingCharacters(in: .whitespaces)
        let fav = Favorite(
            id: id, name: "\(u)@\(h)", host: h, port: Int(port) ?? 22, username: u,
            auth: useKey ? .privateKey : .password,
            privateKeyPath: useKey ? keyPath : nil,
            initialPath: path.isEmpty ? "/" : path,
            colorLabel: color == "none" ? nil : color, note: note
        )
        return model.save(fav, password: useKey ? nil : password) ? fav : nil
    }
}
