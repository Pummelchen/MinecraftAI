import Foundation
import Testing
@testable import MCPummelchenModClientCore
@testable import MCPummelchenModShared

@Suite("Client app self updater")
struct ClientAppSelfUpdaterTests {
    @Test("detects when the published release is newer than the app bundle release")
    func detectsNeededAppUpdate() throws {
        let release = CurrentRelease(
            releaseID: "release_20260613_V99_self_update",
            createdAt: "2026-06-13T00:00:00+00:00",
            activatedAt: "2026-06-13T00:00:00+00:00",
            status: "tested",
            minecraftVersion: "26.1.2",
            loaderVersion: "26.1.2.76",
            serverKey: "minecraft_26_1_2",
            manifestURL: "/downloads/releases/release_20260613_V99_self_update/client-sync-manifest.tsv",
            clientZipURL: "/downloads/releases/release_20260613_V99_self_update/client.zip",
            clientZipSHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            mrpackURL: "/downloads/releases/release_20260613_V99_self_update/pack.mrpack",
            mrpackSHA256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            dmgURL: "/downloads/releases/release_20260613_V99_self_update/MCPummelchenModClient.dmg",
            dmgSHA256: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            notes: "test"
        )

        #expect(!ClientAppSelfUpdater.needsUpdate(currentBundleReleaseID: release.releaseID, release: release))
        #expect(ClientAppSelfUpdater.needsUpdate(currentBundleReleaseID: "release_20260613_V98_old", release: release))
        #expect(!ClientAppSelfUpdater.needsUpdate(currentBundleReleaseID: "release_20260613_V100_prepublication", release: release))
        #expect(ClientAppSelfUpdater.needsUpdate(currentBundleReleaseID: nil, release: release))

        let noDMG = CurrentRelease(
            releaseID: release.releaseID,
            createdAt: release.createdAt,
            activatedAt: release.activatedAt,
            status: release.status,
            minecraftVersion: release.minecraftVersion,
            loaderVersion: release.loaderVersion,
            serverKey: release.serverKey,
            manifestURL: release.manifestURL,
            clientZipURL: release.clientZipURL,
            clientZipSHA256: release.clientZipSHA256,
            mrpackURL: release.mrpackURL,
            mrpackSHA256: release.mrpackSHA256,
            notes: release.notes
        )
        #expect(!ClientAppSelfUpdater.needsUpdate(currentBundleReleaseID: nil, release: noDMG))
    }

    @Test("only treats executables inside Contents/MacOS as app-bundle self-update targets")
    func appBundleDetectionRequiresMacOSExecutableLocation() throws {
        let app = URL(fileURLWithPath: "/Applications/MCPummelchenModClient.app", isDirectory: true)
        let appExecutable = app.appendingPathComponent("Contents/MacOS/MCPummelchenModClient")
        #expect(ClientAppSelfUpdater.appBundleURL(containingExecutable: appExecutable) == app)

        let xcodeTool = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest")
        #expect(ClientAppSelfUpdater.appBundleURL(containingExecutable: xcodeTool) == nil)
    }
}
