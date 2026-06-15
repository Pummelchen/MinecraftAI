import AppKit
import Foundation
import MCPummelchenModClientCore
import SwiftUI

@MainActor
final class ClientStatusModel: ObservableObject, @unchecked Sendable {
    @Published var serverURL: String
    @Published var snapshot: ClientStatusSnapshot?
    @Published var isRefreshing = false
    @Published var isSyncing = false
    @Published var rowsRepairing = Set<String>()
    @Published var syncMessage: String?
    @Published var controlMessage: String?

    private var configuration: ClientStatusConfiguration
    private var controlTask: Task<Void, Never>?
    private var startupSyncAttempted = false

    init(configuration: ClientStatusConfiguration) {
        self.configuration = configuration
        self.serverURL = configuration.serverURL.absoluteString
    }

    deinit {
        controlTask?.cancel()
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
                self.syncOnStartupIfNeeded(snapshot: next)
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
            pummelchenHome: configuration.pummelchenHome,
            databaseURL: configuration.databaseURL,
            retryPolicy: configuration.retryPolicy,
            clientID: configuration.clientID,
            clientAPIToken: configuration.clientAPIToken
        )
        startControlWatcher()
        refresh()
    }

    func syncNow() {
        guard !isSyncing else { return }
        isSyncing = true
        syncMessage = nil
        let syncConfiguration = makeSyncConfiguration()
        Task {
            do {
                let result = try await ClientSyncEngine(configuration: syncConfiguration).sync(force: true)
                await MainActor.run {
                    self.syncMessage = "\(result.message) \(result.filesDownloaded) downloaded, \(result.filesVerified) verified."
                    self.isSyncing = false
                    self.refresh()
                    if result.selfUpdateScheduled {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            NSApp.terminate(nil)
                        }
                    }
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

    func repair(rowID: String) {
        guard !rowsRepairing.contains(rowID) else {
            return
        }
        guard let snapshot else {
            syncMessage = "No status snapshot is available."
            return
        }
        guard snapshot.defaultsHealth.contains(where: { $0.id == rowID && $0.status.isActionable }) else {
            syncMessage = "Selected row is not actionable."
            return
        }

        rowsRepairing.insert(rowID)
        let config = configuration
        Task {
            let repaired = await ClientStatusService(configuration: config).checkAndRecord(rowIDsToRepair: [rowID])
            await MainActor.run {
                self.snapshot = repaired
                self.rowsRepairing.remove(rowID)
                self.syncMessage = repaired.errorMessage == nil ? "Row fix completed: \(rowID)" : repaired.errorMessage
                self.refresh()
            }
        }
    }

    func startControlWatcher() {
        controlTask?.cancel()
        let syncConfiguration = makeSyncConfiguration()
        guard let token = syncConfiguration.clientAPIToken, !token.isEmpty else {
            controlMessage = "Live updates waiting for client credentials."
            return
        }
        controlMessage = "Live updates connected."
        let model = self
        controlTask = Task {
            do {
                _ = try await ClientControlWatcher(syncConfiguration: syncConfiguration).run { message in
                    Task { @MainActor in
                        model.controlMessage = message
                        model.refresh()
                        if message.localizedCaseInsensitiveContains("self-update scheduled") {
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            } catch {
                if error is CancellationError {
                    await MainActor.run {
                        model.controlMessage = "Live updates connected."
                    }
                    return
                }
                await MainActor.run {
                    model.controlMessage = "Live updates stopped: \(error)"
                }
            }
        }
    }

    private func makeSyncConfiguration() -> ClientSyncConfiguration {
        ClientSyncConfiguration(
            serverURL: configuration.serverURL,
            minecraftDirectory: configuration.minecraftDirectory,
            pummelchenHome: configuration.pummelchenHome,
            databaseURL: configuration.databaseURL,
            clientID: configuration.clientID,
            clientAPIToken: configuration.clientAPIToken,
            retryPolicy: configuration.retryPolicy
        )
    }

    private func syncOnStartupIfNeeded(snapshot: ClientStatusSnapshot) {
        guard !startupSyncAttempted, !isSyncing else {
            return
        }
        guard snapshot.state == .updateAvailable || snapshot.state == .repairNeeded else {
            return
        }
        startupSyncAttempted = true
        syncMessage = "Auto-sync started to repair local files before Minecraft launch."
        syncNow()
    }
}

struct PummelchenStatusView: View {
    @ObservedObject var model: ClientStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MCPummelchenModClient")
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
                if let controlMessage = model.controlMessage {
                    Text(controlMessage)
                        .font(.callout)
                        .foregroundStyle(controlMessage.hasPrefix("Live updates stopped") ? .red : .secondary)
                        .textSelection(.enabled)
                }
                statusSummary(snapshot)
                connectionIndicators(snapshot)
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
            model.startControlWatcher()
        }
    }

    private func connectionIndicators(_ snapshot: ClientStatusSnapshot) -> some View {
        HStack(spacing: 12) {
            endpointIndicator(snapshot.nginx)
            endpointIndicator(snapshot.webTransport)
            Spacer()
        }
    }

    private func endpointIndicator(_ status: EndpointConnectionStatus) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color(for: status.state))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(status.label)
                        .font(.headline)
                    Text(label(for: status.state))
                        .font(.caption)
                        .foregroundStyle(color(for: status.state))
                }
                Text(endpointDetail(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .help(status.message)
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
                HStack(spacing: 8) {
                    Circle()
                        .fill(color(for: row.status))
                        .frame(width: 8, height: 8)
                    Text(row.status.displayValue)
                        .foregroundStyle(color(for: row.status))
                }
            }
            TableColumn("Recommended Action") { row in
                Text(row.recommendedAction)
                    .lineLimit(2)
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
            TableColumn("Fix") { row in
                Button("Fix") {
                    model.repair(rowID: row.id)
                }
                .disabled(!row.status.isActionable || model.rowsRepairing.contains(row.id) || model.isSyncing || model.isRefreshing)
                .controlSize(.small)
            }
        }
        .frame(minHeight: 230)
    }

    private func footer(_ snapshot: ClientStatusSnapshot) -> some View {
        let clientIPText = snapshot.clientIP ?? "unknown"
        return VStack(alignment: .leading, spacing: 5) {
            Text("Minecraft: \(snapshot.minecraftDirectory)")
            Text("Local DuckDB: \(snapshot.localDatabase)")
            Text("Client IP: \(clientIPText)")
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

    private func label(for state: EndpointConnectionState) -> String {
        switch state {
        case .connected: "connected"
        case .degraded: "degraded"
        case .cannotConnect: "cannot connect"
        }
    }

    private func endpointDetail(_ status: EndpointConnectionStatus) -> String {
        if let latency = status.latencyMS {
            return "\(latency) ms - \(status.message)"
        }
        return status.message
    }

    private func color(for state: EndpointConnectionState) -> Color {
        switch state {
        case .connected: .green
        case .degraded: .orange
        case .cannotConnect: .red
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

    private func color(for status: ClientDefaultStatus) -> Color {
        switch status {
        case .pass, .fixedOK, .testing:
            return .green
        case .repairing:
            return .orange
        case .fixedFailed, .fail, .missing:
            return .red
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
            "Local files need repair. Sync Now will verify and fix them."
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
        window.title = "MCPummelchenModClient"
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
struct MCPummelchenModClientMain {
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
            print("nginx=\(snapshot.nginx.state.rawValue) latency_ms=\(snapshot.nginx.latencyMS.map(String.init) ?? "n/a")")
            print("webtransport=\(snapshot.webTransport.state.rawValue) latency_ms=\(snapshot.webTransport.latencyMS.map(String.init) ?? "n/a")")
            if let error = snapshot.errorMessage {
                print("error=\(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
    }
}
