import Foundation
import MCPummelchenModShared

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ClientDMGBuilderError: Error, CustomStringConvertible {
    case platformUnsupported(String)
    case processFailed(String)
    case missingFile(String)
    case invalidResponse(String)
    case networkTimeout(String)
    case networkError(String)

    public var description: String {
        switch self {
        case .platformUnsupported(let value):
            return value
        case .processFailed(let value):
            return value
        case .missingFile(let value):
            return "missing file: \(value)"
        case .invalidResponse(let value):
            return "invalid response: \(value)"
        case .networkTimeout(let value):
            return "network timeout while calling \(value)"
        case .networkError(let value):
            return "network error: \(value)"
        }
    }
}

public struct ClientDMGBuilderConfig: Sendable {
    public let projectRoot: URL
    public let clientPackageRoot: URL
    public let serverPackageRoot: URL
    public let releaseID: String
    public let clientVersion: String
    public let serverURL: String
    public let serverAddress: String
    public let duckdbDylibPath: String
    public let macOSDeploymentTarget: String
    public let runNginxControlLiveTest: Bool
    public let runHeadlessSoak: Bool
    public let headlessSoakSeconds: Int
    public let headlessCommand: String?
    public let expectedInstalledReleaseID: String?
    public let clientAPIToken: String?
    public let requireClientToken: Bool

    public init(
        projectRoot: URL,
        clientPackageRoot: URL,
        serverPackageRoot: URL,
        releaseID: String = "development",
        clientVersion: String = "0.8.4",
        serverURL: String = "https://pummelchen.91.99.176.243.nip.io",
        serverAddress: String = "91.99.176.243:25565",
        duckdbDylibPath: String = "/opt/homebrew/lib/libduckdb.dylib",
        macOSDeploymentTarget: String = "26.0",
        runNginxControlLiveTest: Bool = true,
        runHeadlessSoak: Bool = false,
        headlessSoakSeconds: Int = 60,
        headlessCommand: String? = nil,
        expectedInstalledReleaseID: String? = nil,
        clientAPIToken: String? = nil,
        requireClientToken: Bool = false
    ) {
        self.projectRoot = projectRoot
        self.clientPackageRoot = clientPackageRoot
        self.serverPackageRoot = serverPackageRoot
        self.releaseID = releaseID
        self.clientVersion = clientVersion
        self.serverURL = serverURL
        self.serverAddress = serverAddress
        self.duckdbDylibPath = duckdbDylibPath
        self.macOSDeploymentTarget = macOSDeploymentTarget
        self.runNginxControlLiveTest = runNginxControlLiveTest
        self.runHeadlessSoak = runHeadlessSoak
        self.headlessSoakSeconds = headlessSoakSeconds
        self.headlessCommand = headlessCommand
        self.expectedInstalledReleaseID = expectedInstalledReleaseID
        self.clientAPIToken = clientAPIToken
        self.requireClientToken = requireClientToken
    }
}

public struct ClientDMGBuildResult: Sendable {
    public let dmgPath: URL
    public let dmgSHA256: String

    public init(dmgPath: URL, dmgSHA256: String) {
        self.dmgPath = dmgPath
        self.dmgSHA256 = dmgSHA256
    }
}

public struct ClientDMGBuilder: Sendable {
    private static let appName = "MCPummelchenModClient"
    private static let appBundleName = "MCPummelchenModClient.app"
    private static let dmgFileName = "MCPummelchenModClient.dmg"

    public let config: ClientDMGBuilderConfig

    public init(config: ClientDMGBuilderConfig) {
        self.config = config
    }

    public func build() throws -> ClientDMGBuildResult {
        #if os(macOS)
        let fm = FileManager.default
        let projectRoot = config.projectRoot.standardizedFileURL
        let clientPackageRoot = config.clientPackageRoot.standardizedFileURL
        let buildDir = clientPackageRoot.appendingPathComponent(".build", isDirectory: true)
        let dmgDir = buildDir.appendingPathComponent("pummelchen-dmg", isDirectory: true)
        let stageDir = dmgDir.appendingPathComponent("stage", isDirectory: true)
        let appDir = stageDir.appendingPathComponent(Self.appBundleName, isDirectory: true)
        let contentsDir = appDir.appendingPathComponent("Contents", isDirectory: true)
        let macOSDir = contentsDir.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesDir = contentsDir.appendingPathComponent("Resources", isDirectory: true)
        let frameworksDir = contentsDir.appendingPathComponent("Frameworks", isDirectory: true)
        let dmgPath = dmgDir.appendingPathComponent(Self.dmgFileName)

        if fm.fileExists(atPath: appDir.path) {
            try fm.removeItem(at: appDir)
        }
        try fm.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: frameworksDir, withIntermediateDirectories: true)

        if fm.fileExists(atPath: dmgDir.path) {
            try fm.removeItem(at: dmgDir)
        }
        try fm.createDirectory(at: dmgDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: frameworksDir, withIntermediateDirectories: true)

        _ = try runCommand(executable: "/usr/bin/env", arguments: ["swift", "build", "-c", "release", "--product", Self.appName], workingDirectory: clientPackageRoot)
        _ = try runCommand(executable: "/usr/bin/env", arguments: ["swift", "build", "-c", "release", "--product", "pummelchen-client-sync"], workingDirectory: clientPackageRoot)
        let binaryPath = try runCommand(executable: "/usr/bin/env", arguments: ["swift", "build", "-c", "release", "--show-bin-path"], workingDirectory: clientPackageRoot)
        let resolvedBinaryDirectory = URL(fileURLWithPath: binaryPath.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
        let clientBinary = resolvedBinaryDirectory.appendingPathComponent(Self.appName, isDirectory: false)
        let syncBinary = resolvedBinaryDirectory.appendingPathComponent("pummelchen-client-sync", isDirectory: false)
        guard fm.fileExists(atPath: clientBinary.path) else {
            throw ClientDMGBuilderError.missingFile("Swift client binary not found at \(clientBinary.path)")
        }
        guard fm.fileExists(atPath: syncBinary.path) else {
            throw ClientDMGBuilderError.missingFile("Swift sync binary not found at \(syncBinary.path)")
        }
        try copyFile(clientBinary, to: macOSDir.appendingPathComponent(Self.appName))
        try copyFile(syncBinary, to: macOSDir.appendingPathComponent("pummelchen-client-sync"))

        let tokenText = config.clientAPIToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tokenURL = resourcesDir.appendingPathComponent("client-api-token", isDirectory: false)
        if !tokenText.isEmpty {
            try tokenText.appending("\n").data(using: .utf8)?.write(to: tokenURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        }

        if config.requireClientToken && !fm.fileExists(atPath: tokenURL.path) {
            throw ClientDMGBuilderError.processFailed("DMG validation failed: missing bundled client API token resource")
        }

        let iconSrc = clientPackageRoot.appendingPathComponent("Resources/AppIcon.png", isDirectory: false)
        if fm.fileExists(atPath: iconSrc.path) {
            let iconset = buildDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
            if fm.fileExists(atPath: iconset.path) {
                try fm.removeItem(at: iconset)
            }
            try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
            let iconMap: [(Int, String)] = [
                (16, "icon_16x16.png"),
                (16, "icon_16x16@2x.png"),
                (32, "icon_32x32.png"),
                (32, "icon_32x32@2x.png"),
                (128, "icon_128x128.png"),
                (128, "icon_128x128@2x.png"),
                (256, "icon_256x256.png"),
                (256, "icon_256x256@2x.png"),
                (512, "icon_512x512.png"),
                (512, "icon_512x512@2x.png")
            ]
            for (size, fileName) in iconMap {
                _ = try runCommand(executable: "/usr/bin/sips", arguments: ["-z", String(size), String(size), iconSrc.path, "--out", iconset.appendingPathComponent(fileName).path])
            }
            _ = try runCommand(executable: "/usr/bin/iconutil", arguments: ["-c", "icns", iconset.path, "-o", resourcesDir.appendingPathComponent("AppIcon.icns").path])
        }

        let resolvedDuckDB = resolvePath(config.duckdbDylibPath, base: projectRoot)
        guard fm.fileExists(atPath: resolvedDuckDB.path) else {
            throw ClientDMGBuilderError.missingFile("DuckDB dylib not found: \(resolvedDuckDB.path)")
        }
        let resolvedDuckDBReal = resolvedDuckDB.standardizedFileURL.resolvingSymlinksInPath()
        let otoolOutput = try runCommand(executable: "/usr/bin/otool", arguments: ["-D", resolvedDuckDBReal.path], workingDirectory: projectRoot)
        let duckDBInstallName = otoolOutput
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .compactMap { $0.isEmpty ? nil : $0 }
            .last ?? resolvedDuckDBReal.path

        let bundledDuckDB = frameworksDir.appendingPathComponent("libduckdb.dylib")
        try copyFile(resolvedDuckDBReal, to: bundledDuckDB)
        _ = try runCommand(executable: "/usr/bin/install_name_tool", arguments: ["-id", "@rpath/libduckdb.dylib", bundledDuckDB.path])
        _ = try runCommand(executable: "/usr/bin/install_name_tool", arguments: ["-change", duckDBInstallName, "@rpath/libduckdb.dylib", macOSDir.appendingPathComponent(Self.appName).path])
        _ = try runCommand(executable: "/usr/bin/install_name_tool", arguments: ["-change", duckDBInstallName, "@rpath/libduckdb.dylib", macOSDir.appendingPathComponent("pummelchen-client-sync").path])
        _ = try runCommand(executable: "/usr/bin/install_name_tool", arguments: ["-add_rpath", "@executable_path/../Frameworks", macOSDir.appendingPathComponent(Self.appName).path])
        _ = try runCommand(executable: "/usr/bin/install_name_tool", arguments: ["-add_rpath", "@executable_path/../Frameworks", macOSDir.appendingPathComponent("pummelchen-client-sync").path])

        let duckdbPrefix = resolvedDuckDBReal.deletingLastPathComponent().deletingLastPathComponent()
        let duckdbLicense = duckdbPrefix.appendingPathComponent("LICENSE", isDirectory: false)
        if fm.fileExists(atPath: duckdbLicense.path) {
            try copyFile(duckdbLicense, to: resourcesDir.appendingPathComponent("duckdb-LICENSE.txt", isDirectory: false))
        }

        let infoPlist = contentsDir.appendingPathComponent("Info.plist")
        let info = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDisplayName</key>
            <string>MCPummelchenModClient</string>
            <key>CFBundleExecutable</key>
            <string>MCPummelchenModClient</string>
            <key>CFBundleIdentifier</key>
            <string>de.pummelchen.minecraft.client</string>
            <key>CFBundleIconFile</key>
            <string>AppIcon</string>
            <key>CFBundleName</key>
            <string>MCPummelchenModClient</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleShortVersionString</key>
            <string>\(config.clientVersion)</string>
            <key>CFBundleVersion</key>
            <string>\(config.clientVersion)</string>
            <key>PummelchenReleaseID</key>
            <string>\(config.releaseID)</string>
            <key>LSMinimumSystemVersion</key>
            <string>\(config.macOSDeploymentTarget)</string>
        </dict>
        </plist>
        """
        try info.write(to: infoPlist, atomically: true, encoding: .utf8)

        _ = try runCommand(executable: "/usr/bin/plutil", arguments: ["-lint", infoPlist.path])
        _ = try runCommand(executable: "/usr/bin/codesign", arguments: ["--force", "--sign", "-", bundledDuckDB.path])
        _ = try runCommand(executable: "/usr/bin/codesign", arguments: ["--force", "--sign", "-", macOSDir.appendingPathComponent("pummelchen-client-sync").path])
        _ = try runCommand(executable: "/usr/bin/codesign", arguments: ["--force", "--sign", "-", macOSDir.appendingPathComponent(Self.appName).path])
        _ = try runCommand(executable: "/usr/bin/codesign", arguments: ["--force", "--deep", "--sign", "-", appDir.path])
        _ = try runCommand(executable: "/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", "--verbose=2", appDir.path])

        if config.runNginxControlLiveTest {
            try runNginxControlLiveTest(syncBinaryPath: macOSDir.appendingPathComponent("pummelchen-client-sync"))
        }

        _ = try runCommand(
            executable: "/usr/bin/hdiutil",
            arguments: [
                "create",
                "-volname",
                Self.appName,
                "-srcfolder",
                stageDir.path,
                "-ov",
                "-format",
                "UDZO",
                "-imagekey",
                "zlib-level=9",
                dmgPath.path
            ],
            workingDirectory: dmgDir
        )

        let sha256 = try SHA256Hasher.hashFile(at: dmgPath)
        try "\(sha256)  \(Self.dmgFileName)\n".write(to: dmgPath.appendingPathExtension("sha256"), atomically: true, encoding: .utf8)

        if config.runHeadlessSoak {
            try runHeadlessSoak(dmgPath: dmgPath)
        }

        return ClientDMGBuildResult(dmgPath: dmgPath, dmgSHA256: sha256)
        #else
        throw ClientDMGBuilderError.platformUnsupported("Client DMG builds are only supported on macOS")
        #endif
    }

    private func runNginxControlLiveTest(syncBinaryPath: URL) throws {
        guard let token = config.clientAPIToken, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientDMGBuilderError.processFailed("DMG validation requires PUMMELCHEN_CLIENT_API_TOKEN for nginx control check")
        }

        let tokenTrimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let eventsBase = try requestBaseURL(path: "/api/v1/control/events")
        let clientID = "dmg-nginx-control-\(Int(Date().timeIntervalSince1970))"

        let queryBefore: [String: String] = ["client_id": clientID, "limit": "200"]
        let beforeURL = try makeURL(base: eventsBase, query: queryBefore)
        let before = try requestJSON(beforeURL, method: "GET", headers: defaultHeaders(token: tokenTrimmed, clientID: clientID))
        guard before.statusCode == 200 else {
            throw ClientDMGBuilderError.processFailed("DMG validation failed: could not fetch control events pre-flight")
        }
        let afterEventID = (before.json["next_after_event_id"] as? String) ?? ""

        let eventBody: [String: Any] = {
            var payload: [String: Any] = [
                "event_type": "server_message",
                "target_client_id": clientID,
                "priority": "normal",
                "title": "DMG nginx control validation",
                "message": "Temporary DMG validation event.",
                "payload": ["probe": "dmg_nginx_control_validation"]
            ]
            if !config.releaseID.isEmpty {
                payload["release_id"] = config.releaseID
            }
            return payload
        }()
        let createResult = try requestJSON(eventsBase, method: "POST", headers: defaultHeaders(token: tokenTrimmed), body: eventBody)
        guard createResult.statusCode == 201 else {
            throw ClientDMGBuilderError.processFailed("DMG validation failed: could not create nginx control probe event")
        }

        let workRoot = config.projectRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("pummelchen-dmg")
            .appendingPathComponent("nginx-control-live-test", isDirectory: true)
        if FileManager.default.fileExists(atPath: workRoot.path) {
            try FileManager.default.removeItem(at: workRoot)
        }
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)

        var watchArgs = [
            "watch",
            "--server-url",
            config.serverURL,
            "--minecraft-dir",
            workRoot.appendingPathComponent("minecraft").path,
            "--pummelchen-home",
            workRoot.appendingPathComponent("home").path,
            "--db",
            workRoot.appendingPathComponent("home/client.duckdb").path,
            "--client-id",
            clientID,
            "--max-cycles",
            "3",
            "--allow-while-running",
            "--no-report",
            "--skip-java-repair"
        ]
        if !afterEventID.isEmpty {
            watchArgs.append(contentsOf: ["--after-event-id", afterEventID])
        }

        let syncLog = try runCommand(
            executable: syncBinaryPath.path,
            arguments: watchArgs,
            workingDirectory: workRoot,
            environment: ["PUMMELCHEN_CLIENT_API_TOKEN": tokenTrimmed],
            timeoutSeconds: 45
        )

        if !syncLog.contains("Events handled: 1") {
            throw ClientDMGBuilderError.processFailed("DMG validation failed: control event was not fetched")
        }
        if !syncLog.contains("Syncs run: 0") {
            throw ClientDMGBuilderError.processFailed("DMG validation failed: control event unexpectedly triggered sync")
        }

        var pendingQuery: [String: String] = ["client_id": clientID, "limit": "5"]
        if !afterEventID.isEmpty {
            pendingQuery["after_event_id"] = afterEventID
        }
        let pendingURL = try makeURL(base: eventsBase, query: pendingQuery)
        let pending = try requestJSON(pendingURL, method: "GET", headers: defaultHeaders(token: tokenTrimmed, clientID: clientID))
        guard pending.statusCode == 200 else {
            throw ClientDMGBuilderError.processFailed("DMG validation failed: could not fetch pending nginx control events")
        }
        let eventCount = (pending.json["events"] as? [Any])?.count ?? Int.max
        guard eventCount == 0 else {
            throw ClientDMGBuilderError.processFailed("DMG validation failed: nginx control probe ack did not clear pending events")
        }

        print("DMG nginx control live test passed: event fetched, event acknowledged, pending_events=0")
    }

    private func runHeadlessSoak(dmgPath: URL) throws {
        let token = config.clientAPIToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let headlessCommand = config.headlessCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
            ? config.headlessCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let expectedInstalledReleaseID = config.expectedInstalledReleaseID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
            ? config.expectedInstalledReleaseID?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        _ = try runCommand(
            executable: "/usr/bin/env",
            arguments: ["swift", "run", "--package-path", config.serverPackageRoot.path, "-c", "release", "pummelchen-headless-soak", "--dmg", dmgPath.path, "--release-id", config.releaseID, "--server-address", config.serverAddress, "--server-url", config.serverURL, "--duration-seconds", String(max(60, config.headlessSoakSeconds))] + (headlessCommand.map { ["--headless-command", $0] } ?? []) + (expectedInstalledReleaseID.map { ["--expected-installed-release-id", $0] } ?? []),
            workingDirectory: config.projectRoot,
            environment: token == nil ? nil : ["PUMMELCHEN_CLIENT_API_TOKEN": token!],
            timeoutSeconds: Double(max(4_500, config.headlessSoakSeconds + 4_200))
        )
    }

    private func requestBaseURL(path: String) throws -> URL {
        guard let base = URL(string: config.serverURL) else {
            throw ClientDMGBuilderError.invalidResponse("invalid server URL: \(config.serverURL)")
        }
        return base.appendingPathComponent(path)
    }

    private func makeURL(base: URL, query: [String: String]) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ClientDMGBuilderError.invalidResponse("invalid control API URL: \(base.absoluteString)")
        }
        components.queryItems = query.map { key, value in
            URLQueryItem(name: key, value: value)
        }
        guard let url = components.url else {
            throw ClientDMGBuilderError.invalidResponse("could not build control API URL")
        }
        return url
    }

    private func defaultHeaders(token: String, clientID: String? = nil) -> [String: String] {
        var headers = ["Authorization": "Bearer \(token)"]
        if let clientID {
            headers["X-Pummelchen-Client-ID"] = clientID
        }
        headers["Content-Type"] = "application/json"
        return headers
    }

    private func requestJSON(
        _ url: URL,
        method: String,
        headers: [String: String],
        body: [String: Any]? = nil
    ) throws -> (statusCode: Int, json: [String: Any]) {
        let (statusCode, data) = try requestData(url, method: method, headers: headers, body: body)
        guard !data.isEmpty else {
            return (statusCode, [:])
        }
        let payload = try JSONSerialization.jsonObject(with: data)
        guard let json = payload as? [String: Any] else {
            let sample = String(data: data.prefix(512), encoding: .utf8) ?? ""
            throw ClientDMGBuilderError.invalidResponse("unexpected response payload: \(sample)")
        }
        return (statusCode, json)
    }

    private func requestData(
        _ url: URL,
        method: String,
        headers: [String: String],
        body: [String: Any]? = nil
    ) throws -> (statusCode: Int, data: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let session = URLSession(configuration: .ephemeral)
        final class RequestResponse: @unchecked Sendable {
            var status: Int = 0
            var result: Result<Data, Error>?
        }
        let responseCapture = RequestResponse()
        let semaphore = DispatchSemaphore(value: 0)

        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                responseCapture.result = .failure(error)
            } else {
                responseCapture.status = (response as? HTTPURLResponse)?.statusCode ?? 0
                responseCapture.result = .success(data ?? Data())
            }
            semaphore.signal()
        }
        task.resume()

        let wait = semaphore.wait(timeout: .now() + 45)
        guard wait == .success else {
            task.cancel()
            throw ClientDMGBuilderError.networkTimeout(url.absoluteString)
        }

        guard let responseData = responseCapture.result else {
            throw ClientDMGBuilderError.networkError("No response data for \(url.absoluteString)")
        }
        do {
            return (responseCapture.status, try responseData.get())
        } catch {
            throw ClientDMGBuilderError.networkError(error.localizedDescription)
        }
    }

    private func copyFile(_ source: URL, to target: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: target)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    }

    private func runCommand(
        executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeoutSeconds: TimeInterval = 120
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        if let environment {
            var values = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                values[key] = value
            }
            process.environment = values
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let started = Date()
        while process.isRunning {
            if Date().timeIntervalSince(started) > timeoutSeconds {
                process.terminate()
                throw ClientDMGBuilderError.processFailed("command timeout for \(executable) \(arguments.joined(separator: " "))")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let command = ([executable] + arguments).joined(separator: " ")
            throw ClientDMGBuilderError.processFailed("\(command)\n\(output)")
        }
        return output
    }

    private func resolvePath(_ value: String, base: URL) -> URL {
        let candidate = URL(fileURLWithPath: value)
        if value.hasPrefix("/") {
            return candidate.standardizedFileURL
        }
        return URL(fileURLWithPath: value, relativeTo: base).standardizedFileURL
    }
}
