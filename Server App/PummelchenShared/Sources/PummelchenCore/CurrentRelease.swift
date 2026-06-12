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
        try ContractValidation.requireSHA256(release.clientZipSHA256, field: "client_zip_sha256")
        try ContractValidation.requireSHA256(release.mrpackSHA256, field: "mrpack_sha256")
    }
}
