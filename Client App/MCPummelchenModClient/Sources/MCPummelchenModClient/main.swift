import AppKit
import Foundation
import MCPummelchenModClientCore
import MCPummelchenModShared
import SwiftUI

@MainActor
final class ClientStatusModel: ObservableObject, @unchecked Sendable {
    @Published var serverURL: String
    @Published var snapshot: ClientStatusSnapshot?
    @Published var isRefreshing = false
    @Published var isSyncing = false
    @Published var syncMessage: String?
    @Published var controlMessage: String?
    @Published var isForceUpdating = false
    @Published var forceUpdateMessage: String?
    let appVersion: String

    private var configuration: ClientStatusConfiguration
    private var controlTask: Task<Void, Never>?
    private var endpointLatencyTask: Task<Void, Never>?
    private var minecraftCloseRetryTask: Task<Void, Never>?
    private var startupSyncAttempted = false
    private let retryTracker = DefaultsRetryTracker()

    init(configuration: ClientStatusConfiguration) {
        self.configuration = configuration
        self.serverURL = configuration.serverURL.absoluteString
        self.appVersion = Self.appVersion()
    }

    deinit {
        controlTask?.cancel()
        endpointLatencyTask?.cancel()
        minecraftCloseRetryTask?.cancel()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let config = configuration
        Task {
            let service = ClientStatusService(configuration: config)
            let next = await service.checkAndRecord(retryTracker: retryTracker)
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
        startEndpointLatencyRefresh()
        refresh()
    }

    func startEndpointLatencyRefresh() {
        endpointLatencyTask?.cancel()
        let model = self
        endpointLatencyTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await model.refreshEndpointLatencies()
            }
        }
    }

    private func refreshEndpointLatencies() async {
        let config = configuration
        let service = ClientStatusService(configuration: config)
        let endpoints = await service.endpointStatuses()
        if Task.isCancelled {
            return
        }
        await MainActor.run {
            guard let current = self.snapshot else {
                return
            }
            self.snapshot = current.updatingEndpoints(
                downloadServer: endpoints.downloadServer,
                updateServer: endpoints.updateServer,
                checkedAt: endpoints.checkedAt
            )
        }
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
                    if case ClientSyncError.minecraftRunning = error {
                        self.syncMessage = "Minecraft is running. Close Minecraft; sync will continue automatically."
                        self.scheduleSyncAfterMinecraftCloses()
                    } else {
                        self.syncMessage = "Sync failed: \(error)"
                    }
                    self.isSyncing = false
                    self.refresh()
                }
            }
        }
    }

    func forceDownloadAndSelfUpdate() {
        guard !isForceUpdating else { return }
        isForceUpdating = true
        forceUpdateMessage = "Downloading latest client app release..."
        Task {
            do {
                let statusService = ClientStatusService(configuration: configuration)
                let currentRelease = try await statusService.fetchCurrentReleaseFromNginx()
                let result = try await ClientAppSelfUpdater.stageAndScheduleIfNeeded(
                    release: currentRelease,
                    serverURL: configuration.serverURL,
                    pummelchenHome: configuration.pummelchenHome,
                    http: ClientHTTPClient(retryPolicy: configuration.retryPolicy)
                )
                await MainActor.run {
                    self.forceUpdateMessage = result.message
                    if result.scheduled {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            NSApp.terminate(nil)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.forceUpdateMessage = "Force update failed: \(error)"
                    self.isForceUpdating = false
                }
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

    private func scheduleSyncAfterMinecraftCloses() {
        guard minecraftCloseRetryTask == nil else {
            return
        }
        let model = self
        minecraftCloseRetryTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !ClientSyncEngine.minecraftIsRunning() {
                    await MainActor.run {
                        model.minecraftCloseRetryTask = nil
                        model.syncMessage = "Minecraft closed. Continuing sync now."
                        model.syncNow()
                    }
                    return
                }
            }
        }
    }

    private static func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "dev"
    }
}

struct PummelchenStatusView: View {
    @ObservedObject var model: ClientStatusModel

    private var clientIPText: String { model.snapshot?.clientIP ?? "unknown" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("MCPummelchenModClient \(model.appVersion)")
                        Text("Client IP: \(clientIPText)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
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
                Button("Force Update") {
                    model.forceDownloadAndSelfUpdate()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model.isForceUpdating || model.snapshot?.serverReleaseID == nil)
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
                if let forceUpdateMessage = model.forceUpdateMessage {
                    Text(forceUpdateMessage)
                        .font(.callout)
                        .foregroundStyle(forceUpdateMessage.hasPrefix("Force update failed") ? .red : (forceUpdateMessage.contains("staged") || forceUpdateMessage.contains("current") ? .green : .secondary))
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
            model.startEndpointLatencyRefresh()
        }
    }

    private func connectionIndicators(_ snapshot: ClientStatusSnapshot) -> some View {
        HStack(spacing: 12) {
            endpointIndicator(snapshot.downloadServer)
            endpointIndicator(snapshot.updateServer)
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
            TableColumn("Configuration") { row in
                Text(row.label)
            }
            TableColumn("Requirement") { row in
                Text(row.desiredValue)
                    .lineLimit(2)
            }
            TableColumn("Status Check") { row in
                HStack(spacing: 8) {
                    Circle()
                        .fill(color(for: row.status))
                        .frame(width: 8, height: 8)
                    Text(observedStatus(for: row.status))
                        .foregroundStyle(color(for: row.status))
                        .lineLimit(2)
                }
            }
            TableColumn("Recommended Action") { row in
                Text(actionText(for: row))
                    .lineLimit(2)
            }
        }
        .frame(minHeight: 230)
    }

    private func actionText(for row: ClientDefaultHealthRow) -> String {
        if row.status == .pass {
            return "No action required"
        }
        if row.status == .testing {
            return "Reading local state"
        }
        if row.status == .repairing {
            return "Repairing"
        }
        if row.status == .fixedOK {
            return "Auto repair succeeded"
        }
        if row.status == .fixedFailed {
            return "Auto repair failed; retry or review logs"
        }

        if !row.recommendedAction.isEmpty {
            return row.recommendedAction
        }

        if row.id.hasPrefix("config/") {
            return "Apply managed \(row.label)"
        }

        return "Apply managed default"
    }

    private func footer(_ snapshot: ClientStatusSnapshot) -> some View {
        return VStack(alignment: .leading, spacing: 5) {
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

    private func observedStatus(for status: ClientDefaultStatus) -> String {
        status.displayValue
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
        window.title = "MCPummelchenModClient \(model.appVersion)"
        window.center()
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Single-Instance Guard

/// Uses a POSIX file lock so a second launch activates the running instance and exits.
final class SingleInstanceLock {
    private let lockFilePath: URL
    private var fileDescriptor: Int32 = -1

    init(name: String) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Pummelchen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.lockFilePath = dir.appendingPathComponent("\(name).lock")
    }

    /// Returns `true` if this process acquired the lock (sole instance).
    /// Returns `false` if another instance already holds it.
    func acquire() -> Bool {
        let path = lockFilePath.path
        fileDescriptor = open(path, O_CREAT | O_WRONLY, 0o600)
        guard fileDescriptor >= 0 else { return false }
        let result = flock(fileDescriptor, LOCK_EX | LOCK_NB)
        if result != 0 {
            close(fileDescriptor)
            fileDescriptor = -1
            return false
        }
        let pidData = Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
        _ = pidData.withUnsafeBytes { ptr in
            write(fileDescriptor, ptr.baseAddress!, ptr.count)
        }
        return true
    }

    deinit {
        if fileDescriptor >= 0 {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }
    }
}

private func activateExistingInstance() {
    guard let bundleID = Bundle.main.bundleIdentifier else { return }
    let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    for app in existing where app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
        app.activate(options: [.activateAllWindows])
        return
    }
}

@main
struct MCPummelchenModClientMain {
    static func main() {
        if CommandLine.arguments.contains("--once") {
            runOnce()
            return
        }

        let instanceLock = SingleInstanceLock(name: "MCPummelchenModClient")
        if !instanceLock.acquire() {
            activateExistingInstance()
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
            print("download_server=\(snapshot.downloadServer.state.rawValue) latency_ms=\(snapshot.downloadServer.latencyMS.map(String.init) ?? "n/a")")
            print("update_server=\(snapshot.updateServer.state.rawValue) latency_ms=\(snapshot.updateServer.latencyMS.map(String.init) ?? "n/a")")
            if let error = snapshot.errorMessage {
                print("error=\(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
    }
}
