import Foundation

enum PearError: LocalizedError {
    case packageNotFound(String)
    case invalidPackage(String)
    case missingBundleIdentifier
    case missingExecutable(String)
    case commandFailed(tool: String, status: Int32, output: String)
    case launchFailed(String)
    case missingRuntimeComponent(String)
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .packageNotFound(let name):
            return "Paket bulunamadı: \(name)"
        case .invalidPackage(let reason):
            return "Geçersiz paket: \(reason)"
        case .missingBundleIdentifier:
            return "Info.plist içinde CFBundleIdentifier yok."
        case .missingExecutable(let name):
            return "Çalıştırılabilir dosya bulunamadı: \(name)"
        case .commandFailed(let tool, let status, let output):
            return "\(tool) başarısız oldu (durum \(status)): \(output)"
        case .launchFailed(let reason):
            return "Uygulama başlatılamadı: \(reason)"
        case .missingRuntimeComponent(let name):
            return "Uyumluluk bileşeni bulunamadı: \(name)"
        case .notImplemented(let feature):
            return "Henüz uygulanmadı: \(feature)"
        }
    }
}
