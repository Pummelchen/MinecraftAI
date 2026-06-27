import Foundation

public struct CurrentRelease: Codable, Equatable, Sendable {
    public let releaseID: String
    public let createdAt: String
    public let activatedAt: String?
    public let status: String
    public let minecraftVersion: String?
    public let loaderVersion: String?
    public let serverKey: String
    public let manifestURL: String
    public let clientZipURL: String
    public let clientZipSHA256: String
    public let mrpackURL: String
    public let mrpackSHA256: String
    public let dmgURL: String?
    public let dmgSHA256: String?
    public let notes: String

    enum CodingKeys: String, CodingKey {
        case releaseID = "release_id"
        case createdAt = "created_at"
        case activatedAt = "activated_at"
        case status
        case minecraftVersion = "minecraft_version"
        case loaderVersion = "loader_version"
        case serverKey = "server_key"
        case manifestURL = "manifest_url"
        case clientZipURL = "client_zip_url"
        case clientZipSHA256 = "client_zip_sha256"
        case mrpackURL = "mrpack_url"
        case mrpackSHA256 = "mrpack_sha256"
        case dmgURL = "dmg_url"
        case dmgSHA256 = "dmg_sha256"
        case notes
    }

    public init(
        releaseID: String,
        createdAt: String,
        activatedAt: String?,
        status: String,
        minecraftVersion: String?,
        loaderVersion: String?,
        serverKey: String,
        manifestURL: String,
        clientZipURL: String,
        clientZipSHA256: String,
        mrpackURL: String,
        mrpackSHA256: String,
        dmgURL: String? = nil,
        dmgSHA256: String? = nil,
        notes: String
    ) {
        self.releaseID = releaseID
        self.createdAt = createdAt
        self.activatedAt = activatedAt
        self.status = status
        self.minecraftVersion = minecraftVersion
        self.loaderVersion = loaderVersion
        self.serverKey = serverKey
        self.manifestURL = manifestURL
        self.clientZipURL = clientZipURL
        self.clientZipSHA256 = clientZipSHA256
        self.mrpackURL = mrpackURL
        self.mrpackSHA256 = mrpackSHA256
        self.dmgURL = dmgURL
        self.dmgSHA256 = dmgSHA256
        self.notes = notes
    }
}

public enum CurrentReleaseValidator {
    public static func decode(_ data: Data) throws -> CurrentRelease {
        let decoder = JSONDecoder()
        return try decoder.decode(CurrentRelease.self, from: data)
    }

    public static func validate(_ release: CurrentRelease) throws {
        _ = try ReleaseIdentifier(release.releaseID)
        try ContractValidation.require(
            !release.createdAt.isEmpty,
            "created_at is required"
        )
        try ContractValidation.require(
            !release.status.isEmpty,
            "status is required"
        )
        try ContractValidation.require(
            !release.serverKey.isEmpty,
            "server_key is required"
        )
        try ContractValidation.require(
            release.manifestURL.hasSuffix("/client-sync-manifest.tsv"),
            "manifest_url must point to client-sync-manifest.tsv"
        )
        try validateRelativeReleaseURL(
            release.manifestURL,
            releaseID: release.releaseID,
            expectedSuffix: "/client-sync-manifest.tsv",
            expectedExtension: nil,
            field: "manifest_url"
        )
        try validateRelativeReleaseURL(
            release.clientZipURL,
            releaseID: release.releaseID,
            expectedSuffix: nil,
            expectedExtension: ".zip",
            field: "client_zip_url"
        )
        try validateRelativeReleaseURL(
            release.mrpackURL,
            releaseID: release.releaseID,
            expectedSuffix: nil,
            expectedExtension: ".mrpack",
            field: "mrpack_url"
        )
        try ContractValidation.require(
            (release.dmgURL == nil) == (release.dmgSHA256 == nil),
            "dmg_url and dmg_sha256 must be provided together"
        )
        if let dmgURL = release.dmgURL {
            try validateRelativeDMGURL(dmgURL, releaseID: release.releaseID, minecraftVersion: release.minecraftVersion ?? "26.1.2")
        }
        try ContractValidation.requireSHA256(release.clientZipSHA256, field: "client_zip_sha256")
        try ContractValidation.requireSHA256(release.mrpackSHA256, field: "mrpack_sha256")
        if let dmgSHA256 = release.dmgSHA256 {
            try ContractValidation.requireSHA256(dmgSHA256, field: "dmg_sha256")
        }
    }

    private static func validateRelativeReleaseURL(
        _ value: String,
        releaseID: String,
        expectedSuffix: String?,
        expectedExtension: String?,
        field: String
    ) throws {
        try ContractValidation.require(!value.isEmpty, "\(field) is required")
        try ContractValidation.require(URL(string: value)?.scheme == nil, "\(field) must be a relative release URL")
        try ContractValidation.require(!value.contains(".."), "\(field) must not contain parent traversal")
        try ContractValidation.require(!value.contains("\\"), "\(field) must use forward slashes")
        try ContractValidation.require(!value.contains("//"), "\(field) must not contain empty path segments")

        let path = value.hasPrefix("/") ? String(value.dropFirst()) : value
        let expectedPrefix = "downloads/releases/\(releaseID)/"
        try ContractValidation.require(
            path.hasPrefix(expectedPrefix),
            "\(field) must stay inside \(expectedPrefix)"
        )
        if let expectedSuffix {
            try ContractValidation.require(
                path.hasSuffix(expectedSuffix),
                "\(field) must end with \(expectedSuffix)"
            )
        }
        if let expectedExtension {
            try ContractValidation.require(
                path.lowercased().hasSuffix(expectedExtension),
                "\(field) must end with \(expectedExtension)"
            )
        }
    }

    private static func validateRelativeDMGURL(_ value: String, releaseID: String, minecraftVersion: String) throws {
        try ContractValidation.require(!value.isEmpty, "dmg_url is required")
        try ContractValidation.require(URL(string: value)?.scheme == nil, "dmg_url must be a relative release URL")
        try ContractValidation.require(!value.contains(".."), "dmg_url must not contain parent traversal")
        try ContractValidation.require(!value.contains("\\"), "dmg_url must use forward slashes")
        try ContractValidation.require(!value.contains("//"), "dmg_url must not contain empty path segments")

        let path = value.hasPrefix("/") ? String(value.dropFirst()) : value
        let stableAlias = "downloads/MCPummelchenModClient_\(artifactVersion(minecraftVersion)).dmg"
        if path == stableAlias {
            return
        }

        let legacyReleasePrefix = "downloads/releases/\(releaseID)/"
        try ContractValidation.require(
            path.hasPrefix(legacyReleasePrefix) && path.lowercased().hasSuffix(".dmg"),
            "dmg_url must be the stable /\(stableAlias) alias"
        )
    }

    private static func artifactVersion(_ minecraftVersion: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let scalars = minecraftVersion.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return value.isEmpty ? "unknown" : value
    }
}
