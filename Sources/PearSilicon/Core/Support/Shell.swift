import Foundation

enum Shell {
    @discardableResult
    static func run(
        _ launchPath: String,
        _ arguments: [String],
        at workingDirectory: URL? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw PearError.commandFailed(
                tool: (launchPath as NSString).lastPathComponent,
                status: process.terminationStatus,
                output: output
            )
        }
        return output
    }

    /// Runs a tool and returns its exit status and combined output instead of
    /// throwing. Used where a non-zero status is expected and recoverable —
    /// `unzip` exits 2 after a bad CRC even though it extracted every other
    /// file, and refusing the whole app package would be worse than keeping the rest.
    static func runAllowingFailure(
        _ launchPath: String,
        _ arguments: [String],
        at workingDirectory: URL? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Runs a tool with its output going straight to our stderr, for long
    /// commands (xcodebuild) where the user should see progress live.
    static func runStreaming(
        _ launchPath: String,
        _ arguments: [String],
        at workingDirectory: URL? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw PearError.commandFailed(
                tool: (launchPath as NSString).lastPathComponent,
                status: process.terminationStatus,
                output: "(see output above)"
            )
        }
    }
}
