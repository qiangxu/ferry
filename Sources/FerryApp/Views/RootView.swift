import FerryKit
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: SessionViewModel
    @ObservedObject var prompter: HostKeyPrompter
    @State private var showConnect = false
    @State private var editing: Favorite?

    init(model: AppModel) {
        self.model = model
        self.session = model.session
        self.prompter = model.prompter
    }

    var body: some View {
        NavigationSplitView {
            FavoritesSidebar(model: model, showConnect: $showConnect, editing: $editing)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            detail
        }
        .frame(minWidth: 800, minHeight: 500)
        .sheet(isPresented: $showConnect) {
            ConnectView(model: model, initial: editing) { showConnect = false }
        }
        .alert("Unknown host key", isPresented: Binding(
            get: { prompter.request != nil },
            set: { if !$0, prompter.request != nil { prompter.resolve(false) } }
        )) {
            Button("Trust and Connect") { prompter.resolve(true) }
            Button("Cancel", role: .cancel) { prompter.resolve(false) }
        } message: {
            Text("Host \(prompter.request.map { Self.hostPort($0.host, $0.port) } ?? "") has not been seen before.\nFingerprint:\n\(prompter.request?.fingerprint ?? "")")
        }
        .alert("Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var detail: some View {
        switch session.state {
        case .disconnected:
            placeholder("Pick a favorite or press + to connect.")
        case .connecting:
            VStack { ProgressView(); Text("Connecting...") }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .connected:
            VStack(spacing: 0) {
                if let message = session.errorMessage {
                    HStack {
                        Text(message).foregroundStyle(.red).lineLimit(3)
                        Spacer()
                        Button("Dismiss") { session.dismissError() }
                    }
                    .padding(8)
                    .background(.red.opacity(0.1))
                }
                RemoteBrowserView(session: session)
            }
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message).foregroundStyle(.red)
                if session.entries.isEmpty {
                    placeholder("Pick a favorite or press + to connect.")
                } else {
                    RemoteBrowserView(session: session)
                }
            }
        }
    }

    static func hostPort(_ host: String, _ port: Int) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
