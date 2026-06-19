import Foundation
import MCPummelchenModShared

public struct ClientAppSelfUpdateResult: Equatable, Sendable {
    public let scheduled: Bool
    public let message: String

    public static let notNeeded = ClientAppSelfUpdateResult(scheduled: false, message: "client app is current")
    public static let unavailable = ClientAppSelfUpdateResult(scheduled: false, message: "client app self-update is unavailable outside an app bundle")
}

public enum ClientAppSelfUpdateError: Error, CustomStringConvertible {
    case missingDMGMetadata
    case checksumMismatch(expected: String, actual: String)
    case commandFailed(String)
    case missingAppInDMG
    case invalidBundle(String)

    public var description: String {
        switch self {
        case .missingDMGMetadata:
            return "current release does not include DMG update metadata"
        case .checksumMismatch(let expected, let actual):
            return "client app DMG checksum mismatch: expected \(expected), got \(actual)"
        case .commandFailed(let message):
            return message
        case .missingAppInDMG:
            return "client app DMG does not contain a .app bundle"
        case .invalidBundle(let message):
            return "client app bundle validation failed: \(message)"
        }
    }
}

public enum ClientAppSelfUpdater {
    public static func needsUpdate(currentBundleReleaseID: String?, release: CurrentRelease) -> Bool {
        guard release.dmgURL != nil, release.dmgSHA256 != nil else {
            return false
        }
        guard let currentBundleReleaseID, currentBundleReleaseID != release.releaseID else {
            return currentBundleReleaseID == nil
        }
        if let currentVersion = releaseSequenceNumber(currentBundleReleaseID),
           let publishedVersion = releaseSequenceNumber(release.releaseID) {
            return publishedVersion > currentVersion
        }
        return true
    }

    private static func releaseSequenceNumber(_ releaseID: String) -> Int? {
        let pattern = #"_V([0-9]+)(?:_|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: releaseID, range: NSRange(releaseID.startIndex..., in: releaseID)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: releaseID) else {
            return nil
        }
        return Int(releaseID[range])
    }

    public static func currentAppBundleURL() -> URL? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL.standardizedFileURL
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .standardizedFileURL
        return appBundleURL(containingExecutable: executable)
    }

    static func appBundleURL(containingExecutable executable: URL) -> URL? {
        var current = executable
        while current.path != "/" {
            if current.pathExtension == "app" {
                let macOSDir = current.appendingPathComponent("Contents/MacOS", isDirectory: true).standardizedFileURL.path
                guard executable.path.hasPrefix(macOSDir + "/") else {
                    return nil
                }
                return current
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    public static func bundleReleaseID(at appBundle: URL) -> String? {
        guard let data = try? Data(contentsOf: appBundle.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return info["PummelchenReleaseID"] as? String
    }

    public static func stageAndScheduleIfNeeded(
        release: CurrentRelease,
        serverURL: URL,
        pummelchenHome: URL,
        http: ClientHTTPClient,
        appBundle: URL? = currentAppBundleURL()
    ) async throws -> ClientAppSelfUpdateResult {
        #if os(macOS)
        guard let appBundle else {
            return .unavailable
        }
        guard needsUpdate(currentBundleReleaseID: bundleReleaseID(at: appBundle), release: release) else {
            return .notNeeded
        }
        guard let dmgURL = release.dmgURL, let expectedSHA = release.dmgSHA256 else {
            throw ClientAppSelfUpdateError.missingDMGMetadata
        }

        let work = pummelchenHome
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("self-update-\(release.releaseID)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let localDMG = work.appendingPathComponent("MCPummelchenModClient.dmg")
        let downloaded = try await http.download(from: absoluteURL(dmgURL, serverURL: serverURL))
        try? FileManager.default.removeItem(at: localDMG)
        try FileManager.default.moveItem(at: downloaded, to: localDMG)

        let actualSHA = try SHA256Hasher.hashFile(at: localDMG).lowercased()
        guard actualSHA == expectedSHA.lowercased() else {
            throw ClientAppSelfUpdateError.checksumMismatch(expected: expectedSHA.lowercased(), actual: actualSHA)
        }

        let mounted = try mountDMG(localDMG)
        defer { try? detachDMG(mounted) }
        let sourceApp = try findAppBundle(in: mounted)
        try validateSourceApp(sourceApp, expectedReleaseID: release.releaseID)

        let stagedApp = work.appendingPathComponent(sourceApp.lastPathComponent, isDirectory: true)
        try run("/usr/bin/ditto", [sourceApp.path, stagedApp.path], timeout: 180)
        try validateSourceApp(stagedApp, expectedReleaseID: release.releaseID)

        let script = try writeInstallerScript(work: work)
        try launchInstaller(script: script, stagedApp: stagedApp, targetApp: appBundle)
        return ClientAppSelfUpdateResult(
            scheduled: true,
            message: "client app update to \(release.releaseID) staged; app will relaunch"
        )
        #else
        return .unavailable
        #endif
    }

    private static func absoluteURL(_ value: String, serverURL: URL) -> URL {
        if let url = URL(string: value), url.scheme != nil {
            return url
        }
        return serverURL.appendingPathComponent(value.hasPrefix("/") ? String(value.dropFirst()) : value)
    }

    #if os(macOS)
    private static func mountDMG(_ dmg: URL) throws -> URL {
        let result = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-plist", dmg.path], timeout: 120)
        let data = Data(result.utf8)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw ClientAppSelfUpdateError.commandFailed("could not parse hdiutil attach output")
        }
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String {
                return URL(fileURLWithPath: mountPoint, isDirectory: true)
            }
        }
        throw ClientAppSelfUpdateError.commandFailed("DMG mounted without a mount point")
    }

    private static func detachDMG(_ mountPoint: URL) throws {
        _ = try run("/usr/bin/hdiutil", ["detach", mountPoint.path], timeout: 60)
    }

    private static func findAppBundle(in mountPoint: URL) throws -> URL {
        let entries = try FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
        if let app = entries.first(where: { $0.pathExtension == "app" }) {
            return app
        }
        throw ClientAppSelfUpdateError.missingAppInDMG
    }

    private static func validateSourceApp(_ app: URL, expectedReleaseID: String) throws {
        let info = app.appendingPathComponent("Contents/Info.plist")
        let executable = app.appendingPathComponent("Contents/MacOS/MCPummelchenModClient")
        let helper = app.appendingPathComponent("Contents/MacOS/pummelchen-client-sync")
        let duckDB = app.appendingPathComponent("Contents/Frameworks/libduckdb.dylib")
        for required in [info, executable, helper, duckDB] {
            guard FileManager.default.fileExists(atPath: required.path) else {
                throw ClientAppSelfUpdateError.invalidBundle("missing \(required.path)")
            }
        }
        guard bundleReleaseID(at: app) == expectedReleaseID else {
            throw ClientAppSelfUpdateError.invalidBundle("PummelchenReleaseID does not match \(expectedReleaseID)")
        }
        _ = try run("/usr/bin/plutil", ["-lint", info.path], timeout: 30)
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 90)
    }

    private static func writeInstallerScript(work: URL) throws -> URL {
        let script = work.appendingPathComponent("install-and-relaunch.sh")
        let body = """
        #!/bin/sh
        set -eu
        SOURCE_APP="$1"
        TARGET_APP="$2"
        WAIT_PID="$3"
        LOG_FILE="$4"
        {
          echo "self_update_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          RESTORE_NEEDED=0
          BACKUP_APP="${TARGET_APP}.pummelchen-backup-$(date -u +%Y%m%d%H%M%S)"
          restore_previous_app() {
            status=$?
            if [ "$status" -ne 0 ] && [ "$RESTORE_NEEDED" -eq 1 ] && [ -d "$BACKUP_APP" ]; then
              rm -rf "$TARGET_APP"
              mv "$BACKUP_APP" "$TARGET_APP"
              echo "self_update_restored_previous_app=true"
            fi
            if [ "$status" -ne 0 ]; then
              echo "self_update_failed_status=$status"
            fi
            exit "$status"
          }
          trap restore_previous_app EXIT
          for _ in $(seq 1 120); do
            if ! kill -0 "$WAIT_PID" 2>/dev/null; then
              break
            fi
            sleep 1
          done
          if [ -d "$TARGET_APP" ]; then
            mv "$TARGET_APP" "$BACKUP_APP"
            RESTORE_NEEDED=1
          fi
          /usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"
          /usr/bin/codesign --verify --deep --strict "$TARGET_APP"
          RESTORE_NEEDED=0
          /usr/bin/xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
          /usr/bin/open "$TARGET_APP"
          rm -rf "$BACKUP_APP" "$(dirname "$SOURCE_APP")"
          echo "self_update_done=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          trap - EXIT
        } >> "$LOG_FILE" 2>&1
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private static func launchInstaller(script: URL, stagedApp: URL, targetApp: URL) throws {
        let log = script.deletingLastPathComponent().appendingPathComponent("self-update.log")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, stagedApp.path, targetApp.path, String(ProcessInfo.processInfo.processIdentifier), log.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            throw ClientAppSelfUpdateError.commandFailed("\(executable) timed out")
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ClientAppSelfUpdateError.commandFailed("\(executable) failed: \(text)")
        }
        return text
    }
    #endif
}
