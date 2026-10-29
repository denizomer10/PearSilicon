import CoreFoundation
import Foundation

/// Immutable compatibility configuration for one bundle and one host session.
/// The vendor identifier is synthetic, not an Apple or host-device identity.
struct RuntimeDeviceProfile: Equatable, Sendable {
    static let inputEnvironmentKeys: Set<String> = [
        "PEAR_DEVICE_MODEL", "PEAR_DEVICE_NAME", "PEAR_DEVICE_IDIOM",
        "PEAR_FAKE_IOS_VERSION", "PEAR_FAKE_IOS_BUILD", "PEAR_FAKE_DARWIN",
    ]

    let schema = 1
    let bundleID: String
    let model: String
    let name: String
    let idiom: String
    let systemName = "iOS"
    let systemVersion: String
    let systemBuild: String
    let darwinRelease: String
    let vendorIdentifier: String

    private static let propertyListKeys = [
        "schema", "bundle", "model", "name", "idiom", "systemName",
        "systemVersion", "systemBuild", "darwinRelease", "vendorIdentifier",
    ]

    static func defaults(bundleID: String) -> RuntimeDeviceProfile {
        RuntimeDeviceProfile(
            bundleID: bundleID, model: "iPhone15,2", name: "iPhone", idiom: "phone",
            systemVersion: "16.0", systemBuild: "20A000", darwinRelease: "22.6.0"
        )
    }

    init(bundleID: String, environment: [String: String]) throws {
        try Self.validateBundleID(bundleID)
        let defaults = Self.defaults(bundleID: bundleID)
        func value(_ key: String, fallback: String) -> String {
            guard let raw = environment[key], !raw.isEmpty else { return fallback }
            return raw
        }
        let model = value("PEAR_DEVICE_MODEL", fallback: defaults.model)
        let name = value("PEAR_DEVICE_NAME", fallback: defaults.name)
        let rawIdiom = value("PEAR_DEVICE_IDIOM", fallback: defaults.idiom)
        let idiom: String
        switch rawIdiom.lowercased() {
        case "phone", "iphone": idiom = "phone"
        case "pad", "ipad": idiom = "pad"
        default: throw RuntimeDeviceProfileError.invalidField("idiom")
        }
        let version = value("PEAR_FAKE_IOS_VERSION", fallback: defaults.systemVersion)
        let build = value("PEAR_FAKE_IOS_BUILD", fallback: defaults.systemBuild)
        let darwin = value("PEAR_FAKE_DARWIN", fallback: defaults.darwinRelease)
        try Self.validate(
            model: model, name: name, idiom: idiom,
            systemVersion: version, systemBuild: build, darwinRelease: darwin
        )
        self.init(
            bundleID: bundleID, model: model, name: name, idiom: idiom,
            systemVersion: version, systemBuild: build, darwinRelease: darwin
        )
    }

    init(propertyList: [String: Any], bundleID: String) throws {
        for field in Self.propertyListKeys where propertyList[field] == nil {
            throw RuntimeDeviceProfileError.invalidField(field)
        }
        guard propertyList.count == Self.propertyListKeys.count else {
            throw RuntimeDeviceProfileError.invalidField("schema")
        }
        guard let schema = propertyList["schema"] as? NSNumber,
              CFGetTypeID(schema) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: schema.objCType)),
              schema.compare(NSNumber(value: 1)) == .orderedSame else {
            throw RuntimeDeviceProfileError.invalidField("schema")
        }
        func string(_ field: String) throws -> String {
            guard let value = propertyList[field] as? String else {
                throw RuntimeDeviceProfileError.invalidField(field)
            }
            return value
        }
        let wireBundle = try string("bundle")
        try Self.validateBundleID(bundleID)
        try Self.validateBundleID(wireBundle)
        guard wireBundle == bundleID else {
            throw RuntimeDeviceProfileError.invalidField("bundle")
        }
        guard try string("systemName") == "iOS" else {
            throw RuntimeDeviceProfileError.invalidField("systemName")
        }
        let model = try string("model")
        let name = try string("name")
        let idiom = try string("idiom")
        let version = try string("systemVersion")
        let build = try string("systemBuild")
        let darwin = try string("darwinRelease")
        try Self.validate(
            model: model, name: name, idiom: idiom,
            systemVersion: version, systemBuild: build, darwinRelease: darwin
        )
        self.init(
            bundleID: bundleID, model: model, name: name, idiom: idiom,
            systemVersion: version, systemBuild: build, darwinRelease: darwin
        )
        // Equality with the computed UUID also enforces uppercase canonical text;
        // callers cannot provide or persist a different compatibility identity.
        guard try string("vendorIdentifier") == vendorIdentifier else {
            throw RuntimeDeviceProfileError.invalidField("vendorIdentifier")
        }
    }

    var propertyList: [String: Any] {
        [
            "schema": schema, "bundle": bundleID, "model": model, "name": name,
            "idiom": idiom, "systemName": systemName, "systemVersion": systemVersion,
            "systemBuild": systemBuild, "darwinRelease": darwinRelease,
            "vendorIdentifier": vendorIdentifier,
        ]
    }

    /// An in-process startup snapshot for the runtime's early C getters. This
    /// adds no opt-in switches and requires neither Foundation nor game IPC.
    var runtimeEnvironment: [String: String] {
        [
            "PEAR_DEVICE_MODEL": model, "PEAR_DEVICE_NAME": name, "PEAR_DEVICE_IDIOM": idiom,
            "PEAR_FAKE_IOS_VERSION": systemVersion, "PEAR_FAKE_IOS_BUILD": systemBuild,
            "PEAR_FAKE_DARWIN": darwinRelease, "PEAR_DEVICE_PROFILE_SOURCE": "host-v1",
            "PEAR_DEVICE_PROFILE_BUNDLE": bundleID, "PEAR_DEVICE_VENDOR_UUID": vendorIdentifier,
        ]
    }

    private init(
        bundleID: String, model: String, name: String, idiom: String,
        systemVersion: String, systemBuild: String, darwinRelease: String
    ) {
        self.bundleID = bundleID
        self.model = model
        self.name = name
        self.idiom = idiom
        self.systemVersion = systemVersion
        self.systemBuild = systemBuild
        self.darwinRelease = darwinRelease
        self.vendorIdentifier = Self.vendorIdentifier(bundleID: bundleID, model: model)
    }

    private static func validateBundleID(_ bundleID: String) throws {
        guard !bundleID.isEmpty, bundleID.utf8.count <= 255,
              !bundleID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RuntimeDeviceProfileError.invalidField("bundle")
        }
    }

    private static func validate(
        model: String, name: String, idiom: String,
        systemVersion: String, systemBuild: String, darwinRelease: String
    ) throws {
        let modelBytes = model.utf8
        guard (1...63).contains(modelBytes.count), let first = modelBytes.first, isLetter(first),
              modelBytes.dropFirst().allSatisfy({ isLetter($0) || isDigit($0) || [44, 95, 45].contains($0) }) else {
            throw RuntimeDeviceProfileError.invalidField("model")
        }
        guard !name.isEmpty, name.utf8.count <= 127,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RuntimeDeviceProfileError.invalidField("name")
        }
        guard idiom == "phone" || idiom == "pad" else {
            throw RuntimeDeviceProfileError.invalidField("idiom")
        }
        guard validVersion(systemVersion) else {
            throw RuntimeDeviceProfileError.invalidField("systemVersion")
        }
        let buildBytes = systemBuild.utf8
        guard (1...64).contains(buildBytes.count), let first = buildBytes.first, isLetter(first) || isDigit(first),
              buildBytes.dropFirst().allSatisfy({ isLetter($0) || isDigit($0) || [46, 95, 45].contains($0) }) else {
            throw RuntimeDeviceProfileError.invalidField("systemBuild")
        }
        guard validVersion(darwinRelease) else {
            throw RuntimeDeviceProfileError.invalidField("darwinRelease")
        }
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    private static func validVersion(_ value: String) -> Bool {
        guard (1...14).contains(value.utf8.count) else { return false }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return (1...3).contains(components.count) && components.allSatisfy {
            (1...4).contains($0.utf8.count) && $0.utf8.allSatisfy(isDigit)
        }
    }

    private static func vendorIdentifier(bundleID: String, model: String) -> String {
        // Preserve DeviceShim's legacy FNV pair and little-endian byte order,
        // including its nonstandard constants and absence of UUID bit rewriting.
        var h1: UInt64 = 1_469_598_103_934_665_603
        var h2: UInt64 = 1_099_511_628_211
        for byte in (bundleID + ":" + model).utf8 {
            h1 = (h1 ^ UInt64(byte)) &* 1_099_511_628_211
            h2 = (h2 ^ UInt64(byte)) &* 1_469_598_103_934_665_603
        }
        let bytes = [h1, h2].flatMap { hash in
            (0..<8).map { UInt8(truncatingIfNeeded: hash >> ($0 * 8)) }
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )).uuidString
    }
}

enum RuntimeDeviceProfileError: LocalizedError, Equatable {
    case invalidField(String)

    var errorDescription: String? {
        switch self {
        case .invalidField(let field): return "device profile: invalid \(field)"
        }
    }
}
