import Foundation

public enum ManagedClientSection: String, CaseIterable, Codable, Sendable {
    case mods
    case resourcepacks
    case shaderpacks
    case tools
}

public struct FileInventoryEntry: Equatable, Codable, Sendable {
    public let section: ManagedClientSection
    public let name: String
    public let relativePath: String
    public let sizeBytes: Int64
    public let sha256: String

    public init(section: ManagedClientSection, name: String, relativePath: String, sizeBytes: Int64, sha256: String) {
        self.section = section
        self.name = name
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}

public enum FileInventory {
    public static func entry(for fileURL: URL, section: ManagedClientSection, root: URL) throws -> FileInventoryEntry {
        let safePath = try SafePath(root: root).validateChild(fileURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: safePath.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let digest = try SHA256Hasher.hashFile(at: safePath)
        return FileInventoryEntry(
            section: section,
            name: safePath.lastPathComponent,
            relativePath: try SafePath(root: root).relativePath(for: safePath),
            sizeBytes: size,
            sha256: digest
        )
    }

    public static func verify(fileURL: URL, expectedSize: Int64, expectedSHA256: String) throws -> Bool {
        try ContractValidation.requireSHA256(expectedSHA256, field: "expectedSHA256")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard size == expectedSize else {
            return false
        }
        return try SHA256Hasher.hashFile(at: fileURL) == expectedSHA256
    }
}
