import Foundation

public struct ProcessCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let currentDirectory: URL?

    public init(executable: String, arguments: [String], currentDirectory: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.currentDirectory = currentDirectory
    }
}

public struct ProcessOutput: Equatable, Sendable {
    public let status: Int32
    public let text: String

    public init(status: Int32, text: String) {
        self.status = status
        self.text = text
    }
}

public enum ProcessRunnerError: Error, LocalizedError {
    case failedToLaunch(String)
    case unsuccessful(ProcessCommand, ProcessOutput)

    public var errorDescription: String? {
        switch self {
        case .failedToLaunch(let message): message
        case .unsuccessful(let command, let output):
            "\(URL(fileURLWithPath: command.executable).lastPathComponent) failed (exit \(output.status)): \(output.text)"
        }
    }
}

public protocol CommandRunning: Sendable {
    func run(_ command: ProcessCommand) async throws -> ProcessOutput
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    @concurrent
    public func run(_ command: ProcessCommand) async throws -> ProcessOutput {
        try Task.checkCancellation()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectory
        process.standardOutput = pipe
        process.standardError = pipe
        let data = try await withTaskCancellationHandler {
            do {
                try process.run()
            } catch {
                throw ProcessRunnerError.failedToLaunch(error.localizedDescription)
            }
            let value = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return value
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        return ProcessOutput(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
    }
}
