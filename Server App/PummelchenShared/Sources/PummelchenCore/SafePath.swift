import Foundation

public struct SafePath: Sendable {
    public let root: URL

    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        try ContractValidation.require(root.isFileURL, "root must be a file URL")
    }

    public func validateChild(_ candidate: URL) throws -> URL {
        try ContractValidation.require(candidate.isFileURL, "candidate must be a file URL")
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        try ContractValidation.require(
            candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/"),
            "path escapes root: \(candidate.path)"
        )
        return URL(fileURLWithPath: candidatePath)
    }

    public func relativePath(for candidate: URL) throws -> String {
        let safe = try validateChild(candidate)
        let rootPath = root.standardizedFileURL.path
        if safe.path == rootPath {
            return "."
        }
        return String(safe.path.dropFirst(rootPath.count + 1))
    }
}
