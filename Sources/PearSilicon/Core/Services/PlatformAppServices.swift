import Foundation

/// Platform-facing service boundary for native macOS entries. The shared
/// ManagedAppService remains the low-level copy/launch primitive; this type owns
/// only the Mac policy surface.
struct MacAppService: Sendable {
    private let runtime = ManagedAppService()

    func importApp(from source: URL, libraryRoot: URL) throws -> LibraryEntry {
        try runtime.importMacApp(from: source, libraryRoot: libraryRoot)
    }

    @MainActor
    func launch(_ entry: LibraryEntry, metalHUDEnabled: Bool?) async throws -> ManagedAppProcess {
        try await runtime.launch(entry, engine: nil, metalHUDEnabled: metalHUDEnabled)
    }
}

/// Platform-facing service boundary for Wine entries, engines and optional
/// graphics components. iOS and macOS never call into this type.
struct WineAppService: Sendable {
    let engines: WineEngineStore
    let releases = WineReleaseService()
    let graphics = GraphicsComponentService()
    private let runtime = ManagedAppService()

    init(engines: WineEngineStore) {
        self.engines = engines
    }

    func importFolder(
        from source: URL, executablePath: String, libraryRoot: URL,
        engineID: String, displayName: String? = nil
    ) throws -> LibraryEntry {
        try runtime.importWindowsFolder(
            from: source, executablePath: executablePath, libraryRoot: libraryRoot,
            engineID: engineID, displayName: displayName
        )
    }

    func importExecutable(
        from source: URL, libraryRoot: URL, engineID: String, displayName: String? = nil
    ) throws -> LibraryEntry {
        try runtime.importWindowsExecutable(
            from: source, libraryRoot: libraryRoot, engineID: engineID, displayName: displayName
        )
    }

    @MainActor
    func launch(
        _ entry: LibraryEntry, engine: WineEngine, metalHUDEnabled: Bool?
    ) async throws -> ManagedAppProcess {
        try await runtime.launch(entry, engine: engine, metalHUDEnabled: metalHUDEnabled)
    }
}
