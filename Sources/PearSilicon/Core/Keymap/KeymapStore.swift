import Foundation

/// Persists one JSON keymap file per app under `<base>/Keymaps/<bundleID>.json`.
final class KeymapStore: @unchecked Sendable {

    private let baseURL: URL
    private let fileManager = FileManager.default

    init(baseURL: URL) {
        self.baseURL = baseURL
        try? fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    func fileURL(for bundleID: String) -> URL {
        baseURL.appendingPathComponent("\(bundleID).json")
    }

    func exists(for bundleID: String) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: bundleID).path)
    }

    func load(for bundleID: String) throws -> Keymap? {
        let url = fileURL(for: bundleID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try KeymapCoding.decoder.decode(Keymap.self, from: data)
    }

    func save(_ keymap: Keymap) throws {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let data = try KeymapCoding.encoder.encode(keymap)
        try data.write(to: fileURL(for: keymap.bundleID), options: .atomic)
    }

    func delete(for bundleID: String) throws {
        let url = fileURL(for: bundleID)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}

enum KeymapCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
