import AppKit
import Foundation
import PummelchenClientCore
import SwiftUI

@MainActor
final class ClientStatusModel: ObservableObject {
    @Published var serverURL: String
    @Published var snapshot: ClientStatusSnapshot?
    @Published var isRefreshing = false
    @Published var isSyncing = false
    @Published var syncMessage: String?

    private var configuration: ClientStatusConfiguration

    init(configuration: ClientStatusConfiguration) {
        self.configuration = configuration
        self.serverURL = configuration.serverURL.absoluteString
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let config = configuration
        Task {
            let service = ClientStatusService(configuration: config)
            let next = await service.checkAndRecord()
            await MainActor.run {
                self.snapshot = next
                self.isRefreshing = false
            }
        }
    }

    func applyServerURL() {
        guard let url = URL(string: serverURL), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            return
        }
        configuration = ClientStatusConfiguration(
            serverURL: url,
            minecraftDirectory: configuration.minecraftDirectory,
            databaseURL: configuration.databaseURL
        )
        refresh()
    }

    func syncNow() {
        guard !isSyncing else { return }
        isSyncing = true
        syncMessage = nil
        let syncConfiguration = ClientSyncConfiguration.productionDefault()
        Task {
            do {
                let result = try await ClientSyncEngine(configuration: syncConfiguration).sync(force: true)
                await MainActor.run {
                    self.syncMessage = "\(result.message) \(result.filesDownloaded) downloaded, \(result.filesVerified) verified."
                    self.isSyncing = false
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.syncMessage = "Sync failed: \(error)"
                    self.isSyncing = false
                    self.refresh()
                }
            }
        }
    }
}

struct PummelchenStatusView: View {
    @ObservedObject var model: ClientStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pummelchen Client")
                        .font(.title.bold())
                    Text("Read-only sync status")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sync Now") {
                    model.syncNow()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(model.isSyncing)
                Button("Refresh") {
                    model.refresh()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isRefreshing)
            }

            HStack(spacing: 8) {
                TextField("Server URL", text: $model.serverURL)
                    .textFieldStyle(.roundedBorder)
                Button("Use") {
                    model.applyServerURL()
                }
            }

            if let snapshot = model.snapshot {
                if let syncMessage = model.syncMessage {
                    Text(syncMessage)
                        .font(.callout)
                        .foregroundStyle(syncMessage.hasPrefix("Sync failed") ? .red : .secondary)
                        .textSelection(.enabled)
                }
                statusSummary(snapshot)
                defaultsTable(snapshot.defaultsHealth)
                footer(snapshot)
            } else {
                ContentUnavailableView("No status yet", systemImage: "arrow.clockwise", description: Text("Refresh reads the server release, local release marker, defaults health, and writes a local DuckDB status row."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(22)
        .frame(minWidth: 820, minHeight: 560)
        .onAppear {
            model.refresh()
        }
    }

    private func statusSummary(_ snapshot: ClientStatusSnapshot) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            GridRow {
                statusBadge(snapshot.state)
                Text(summaryText(snapshot))
                    .font(.headline)
            }
            GridRow {
                Text("Server Release").foregroundStyle(.secondary)
                Text(snapshot.serverReleaseID ?? "offline")
                    .textSelection(.enabled)
            }
            GridRow {
                Text("Client Release").foregroundStyle(.secondary)
                Text(snapshot.localReleaseID ?? "not installed")
                    .textSelection(.enabled)
            }
            GridRow {
                Text("Defaults").foregroundStyle(.secondary)
                Text(snapshot.defaultsOK ? "OK" : "Needs attention")
            }
            GridRow {
                Text("Last Check").foregroundStyle(.secondary)
                Text(snapshot.checkedAt)
            }
        }
    }

    private func defaultsTable(_ rows: [ClientDefaultHealthRow]) -> some View {
        Table(rows) {
            TableColumn("Status") { row in
                Text(row.status.rawValue.replacingOccurrences(of: "_", with: " "))
                    .foregroundStyle(row.status == .ok ? .green : .orange)
            }
            TableColumn("Default") { row in
                Text(row.label)
            }
            TableColumn("Desired") { row in
                Text(row.desiredValue)
                    .lineLimit(2)
            }
            TableColumn("Observed") { row in
                Text(row.observedValue)
                    .lineLimit(2)
            }
            TableColumn("Source") { row in
                Text(row.source)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 230)
    }

    private func footer(_ snapshot: ClientStatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Minecraft: \(snapshot.minecraftDirectory)")
            Text("Local DuckDB: \(snapshot.localDatabase)")
            if let error = snapshot.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private func statusBadge(_ state: ClientSyncState) -> some View {
        Text(label(for: state))
            .font(.headline)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color(for: state).opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(color(for: state))
    }

    private func label(for state: ClientSyncState) -> String {
        switch state {
        case .synced: "Synced"
        case .updateAvailable: "Update Available"
        case .offline: "Server Offline"
        case .repairNeeded: "Repair Needed"
        }
    }

    private func color(for state: ClientSyncState) -> Color {
        switch state {
        case .synced: .green
        case .updateAvailable: .orange
        case .offline: .red
        case .repairNeeded: .red
        }
    }

    private func summaryText(_ snapshot: ClientStatusSnapshot) -> String {
        switch snapshot.state {
        case .synced:
            "All synced. No downloads required."
        case .updateAvailable:
            "A newer server release is available."
        case .offline:
            "Cannot reach the release server."
        case .repairNeeded:
            "Local status database needs repair."
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = ClientStatusModel(configuration: .productionDefault())
        let view = PummelchenStatusView(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pummelchen Client"
        window.center()
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct PummelchenClientMain {
    static func main() {
        if CommandLine.arguments.contains("--once") {
            runOnce()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    private static func runOnce() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let snapshot = await ClientStatusService(configuration: .productionDefault()).checkAndRecord()
            print("state=\(snapshot.state.rawValue)")
            print("server_release=\(snapshot.serverReleaseID ?? "offline")")
            print("client_release=\(snapshot.localReleaseID ?? "not_installed")")
            print("defaults_ok=\(snapshot.defaultsOK)")
            if let error = snapshot.errorMessage {
                print("error=\(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
    }
}
