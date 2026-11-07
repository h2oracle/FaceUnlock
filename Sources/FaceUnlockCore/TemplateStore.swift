import CryptoKit
import Foundation

/// Persists the face template under
/// ~/Library/Application Support/FaceUnlock/face-template.json
/// with the directory at 0700 and the file at 0600.
public struct TemplateStore: Sendable {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("face-template.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    public static var standard: TemplateStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return TemplateStore(directory: base.appendingPathComponent("FaceUnlock", isDirectory: true))
    }

    public func load() -> FaceTemplate? { loadWithDigest()?.template }

    /// The template plus the SHA-256 (hex) of the exact file bytes, for
    /// comparison with the digest kept in the Keychain.
    public func loadWithDigest() -> (template: FaceTemplate, sha256: String)? {
        guard let data = try? Data(contentsOf: fileURL),
              let template = try? JSONDecoder().decode(FaceTemplate.self, from: data),
              template.version == FaceTemplate.currentVersion else { return nil }
        return (template, Self.sha256Hex(data))
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Saves and returns the SHA-256 (hex) of the bytes written.
    @discardableResult
    public func save(_ template: FaceTemplate) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(template)
        // Write to a private temp file first so the final file is never
        // briefly world-readable, then atomically replace.
        let tmp = directory.appendingPathComponent(".face-template.\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if fm.fileExists(atPath: fileURL.path) {
                _ = try fm.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: fileURL)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return Self.sha256Hex(data)
    }

    public func delete() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
    }
}
