import AppKit
import Foundation
import OSLog

private let telemetryLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "server.pummelchen.client-installer",
    category: "Installer"
)

final class InstallerApp: NSObject, NSApplicationDelegate {
    private let installerVersion = "1.2.1"
    private let sessionID = UUID().uuidString.lowercased()
    private var window: NSWindow!
    private let titleLabel = NSTextField(labelWithString: "Pummelchen Client Installer")
    private let stepLabel = NSTextField(labelWithString: "Preparing...")
    private let detailLabel = NSTextField(labelWithString: "Starting installer")
    private let progressBar = NSProgressIndicator()
    private let logView = NSTextView()
    private let openLogButton = NSButton(title: "Open Log", target: nil, action: nil)
    private let closeButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var task: Process?
    private var outputBuffer = ""
    private var logPath: String?
    private var appLogURL: URL?
    private var installerEventURL: URL?
    private var finished = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        prepareAppLog()
        configureTelemetry()
        appendAppLog("app_started session_id=\(sessionID) installer_version=\(installerVersion)")
        sendEvent(
            eventType: "app_started",
            severity: "info",
            status: "running",
            message: "Pummelchen Installer app launched.",
            waitForCompletion: true
        )
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        startInstaller()
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pummelchen Installer"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        window.makeKeyAndOrderFront(nil)

        guard let content = window.contentView else { return }
        titleLabel.font = .boldSystemFont(ofSize: 22)
        stepLabel.font = .boldSystemFont(ofSize: 14)
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 3

        progressBar.minValue = 0
        progressBar.maxValue = 10
        progressBar.doubleValue = 0
        progressBar.isIndeterminate = false

        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.drawsBackground = true
        logView.textColor = .black
        logView.backgroundColor = .white
        logView.insertionPointColor = .black

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = logView
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        scrollView.contentView.backgroundColor = .white

        openLogButton.target = self
        openLogButton.action = #selector(openLog)
        openLogButton.isEnabled = logPath != nil
        closeButton.target = self
        closeButton.action = #selector(cancelOrClose)

        let buttonRow = NSStackView(views: [openLogButton, closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.distribution = .gravityAreas
        buttonRow.spacing = 10

        let stack = NSStackView(views: [titleLabel, stepLabel, detailLabel, progressBar, scrollView, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stepLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 250),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func startInstaller() {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("install-bootstrap.sh").path else {
            sendEvent(
                eventType: "script_missing",
                severity: "error",
                status: "failed",
                message: "Installer resource is missing.",
                waitForCompletion: true
            )
            fail("Installer resource is missing.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script]
        var environment = ProcessInfo.processInfo.environment
        environment["PUMMELCHEN_SKIP_DIALOGS"] = "1"
        environment["PUMMELCHEN_UI"] = "1"
        environment["PUMMELCHEN_NONINTERACTIVE"] = "1"
        environment["PUMMELCHEN_OPEN_LAUNCHER"] = environment["PUMMELCHEN_OPEN_LAUNCHER"] ?? "1"
        environment["PUMMELCHEN_INSTALLER_SESSION_ID"] = sessionID
        environment["PUMMELCHEN_INSTALLER_VERSION"] = installerVersion
        if let installerEventURL {
            environment["PUMMELCHEN_INSTALLER_EVENT_URL"] = installerEventURL.absoluteString
        }
        if let appLogURL {
            environment["PUMMELCHEN_INSTALLER_LOG_FILE"] = appLogURL.path
        }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.consume(text)
            }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.taskFinished(status: process.terminationStatus)
            }
        }

        do {
            try process.run()
            appendAppLog("script_started path=\(script)")
            sendEvent(
                eventType: "script_started",
                severity: "info",
                status: "running",
                message: "Installer bootstrap script started.",
                waitForCompletion: false
            )
            task = process
        } catch {
            appendAppLog("script_launch_failed error=\(error.localizedDescription)")
            sendEvent(
                eventType: "script_launch_failed",
                severity: "error",
                status: "failed",
                message: "Could not start installer: \(error.localizedDescription)",
                waitForCompletion: true
            )
            fail("Could not start installer: \(error.localizedDescription)")
        }
    }

    private func consume(_ text: String) {
        outputBuffer += text
        let lines = outputBuffer.components(separatedBy: .newlines)
        outputBuffer = lines.last ?? ""
        for line in lines.dropLast() {
            processLine(line)
        }
    }

    private func processLine(_ line: String) {
        appendAppLog(line)
        if line.hasPrefix("PUMMELCHEN_PROGRESS\t") {
            let parts = line.components(separatedBy: "\t")
            if parts.count >= 4, let current = Double(parts[1]), let total = Double(parts[2]) {
                progressBar.maxValue = total
                progressBar.doubleValue = current
                stepLabel.stringValue = "Step \(Int(current)) of \(Int(total))"
                detailLabel.stringValue = parts.dropFirst(3).joined(separator: "\t")
            }
            return
        }
        if line.hasPrefix("PUMMELCHEN_DETAIL\t") {
            detailLabel.stringValue = String(line.dropFirst("PUMMELCHEN_DETAIL\t".count))
            return
        }
        if line.hasPrefix("PUMMELCHEN_LOG\t") {
            logPath = String(line.dropFirst("PUMMELCHEN_LOG\t".count))
            openLogButton.isEnabled = true
            return
        }
        if line.hasPrefix("PUMMELCHEN_FAIL\t") {
            sendEvent(
                eventType: "failed",
                severity: "error",
                status: "failed",
                message: String(line.dropFirst("PUMMELCHEN_FAIL\t".count)),
                waitForCompletion: false
            )
            fail(String(line.dropFirst("PUMMELCHEN_FAIL\t".count)))
            return
        }
        if line.hasPrefix("PUMMELCHEN_DONE\t") {
            detailLabel.stringValue = String(line.dropFirst("PUMMELCHEN_DONE\t".count))
            progressBar.doubleValue = progressBar.maxValue
            return
        }
        appendLog(line)
    }

    private func appendLog(_ line: String) {
        let text = NSAttributedString(
            string: line + "\n",
            attributes: [
                .font: logView.font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.black,
            ]
        )
        logView.textStorage?.append(text)
        logView.scrollRangeToVisible(NSRange(location: logView.string.count, length: 0))
    }

    private func taskFinished(status: Int32) {
        if finished { return }
        finished = true
        task = nil
        if status == 0 {
            progressBar.doubleValue = progressBar.maxValue
            stepLabel.stringValue = "Ready to play"
            detailLabel.stringValue = "Ready to play Pummelchen Server. Minecraft Launcher is opening."
            closeButton.title = "Done"
            appendAppLog("app_finished status=ok")
            sendEvent(
                eventType: "app_finished",
                severity: "info",
                status: "ok",
                message: "Ready to play Pummelchen Server.",
                waitForCompletion: true
            )
        } else {
            stepLabel.stringValue = "Install failed"
            if !detailLabel.stringValue.hasPrefix("PUMMELCHEN") {
                detailLabel.stringValue = "The installer stopped with exit code \(status). Open the log for details."
            }
            closeButton.title = "Close"
            appendAppLog("app_finished status=failed exit_code=\(status)")
            sendEvent(
                eventType: "app_finished",
                severity: "error",
                status: "failed",
                message: "The installer stopped with exit code \(status).",
                waitForCompletion: true
            )
        }
    }

    private func fail(_ message: String) {
        stepLabel.stringValue = "Install failed"
        detailLabel.stringValue = message
        closeButton.title = "Close"
        finished = true
        appendAppLog("app_failed message=\(message)")
        sendEvent(
            eventType: "failed",
            severity: "error",
            status: "failed",
            message: message,
            waitForCompletion: true
        )
    }

    @objc private func openLog() {
        guard let logPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc private func cancelOrClose() {
        if let task, task.isRunning {
            appendAppLog("cancel_requested")
            sendEvent(
                eventType: "cancelled",
                severity: "warning",
                status: "cancelled",
                message: "User cancelled the installer.",
                waitForCompletion: true
            )
            task.terminate()
            return
        }
        NSApp.terminate(nil)
    }

    private func prepareAppLog() {
        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser
        let logDir = homeURL.appendingPathComponent("Library/Logs/Pummelchen", isDirectory: true)
        try? fileManager.createDirectory(at: logDir, withIntermediateDirectories: true)
        let stamp = Self.fileStamp.string(from: Date())
        let url = logDir.appendingPathComponent("dmg-installer-\(stamp).log")
        fileManager.createFile(atPath: url.path, contents: nil)
        appLogURL = url
        logPath = url.path
        openLogButton.isEnabled = true
    }

    private func configureTelemetry() {
        let environment = ProcessInfo.processInfo.environment
        let baseURL = environment["PUMMELCHEN_BASE_URL"] ?? "http://91.99.176.243:7788"
        let explicitURL = environment["PUMMELCHEN_INSTALLER_EVENT_URL"]
        let eventURLString = explicitURL ?? baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/client-logs/installer-event"
        installerEventURL = URL(string: eventURLString)
    }

    private func appendAppLog(_ line: String) {
        guard let appLogURL else { return }
        let stampedLine = "\(Self.isoStamp.string(from: Date())) \(line)\n"
        guard let data = stampedLine.data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: appLogURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            telemetryLogger.error("Could not append installer log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sendEvent(
        eventType: String,
        severity: String,
        status: String,
        message: String,
        waitForCompletion: Bool
    ) {
        guard ProcessInfo.processInfo.environment["PUMMELCHEN_DISABLE_INSTALLER_EVENTS"] != "1",
              let installerEventURL else {
            return
        }
        var fields: [String: String] = [
            "session_id": sessionID,
            "event_type": eventType,
            "severity": severity,
            "status": status,
            "message": message,
            "event_at": Self.isoStamp.string(from: Date()),
            "installer_version": installerVersion,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? installerVersion,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "arch": Self.archName,
        ]
        if let appLogURL {
            fields["local_log_path"] = redactedHomePath(appLogURL.path)
        }

        var request = URLRequest(url: installerEventURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("PummelchenInstaller/\(installerVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = Self.formBody(fields)

        telemetryLogger.info("Installer event: \(eventType, privacy: .public) \(status, privacy: .public)")
        let semaphore = waitForCompletion ? DispatchSemaphore(value: 0) : nil
        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error {
                telemetryLogger.error("Installer event upload failed: \(error.localizedDescription, privacy: .public)")
            }
            semaphore?.signal()
        }.resume()
        if let semaphore {
            _ = semaphore.wait(timeout: .now() + 6)
        }
    }

    private func redactedHomePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        fields
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static let isoStamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static var archName: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

let app = NSApplication.shared
let delegate = InstallerApp()
app.delegate = delegate
app.run()
