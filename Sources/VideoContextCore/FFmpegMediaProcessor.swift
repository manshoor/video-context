import Foundation

public struct FFmpegMediaProcessor<Runner: CommandRunning>: MediaProcessing, IncrementalFrameCapturing, Sendable {
    private let toolchain: MediaToolchain
    private let runner: Runner

    public init(toolchain: MediaToolchain, runner: Runner) {
        self.toolchain = toolchain
        self.runner = runner
    }

    public func inspect(_ videoURL: URL) async throws -> MediaInspection {
        try validateDependencies()
        let output = try await run(
            ProcessCommand(
                executable: toolchain.ffprobe,
                arguments: ["-v", "error", "-show_entries", "format=duration:stream=codec_type", "-of", "json", videoURL.path]
            )
        )
        return try MediaInspection.decode(Data(output.text.utf8))
    }

    public func silencePoints(in videoURL: URL) async throws -> [TimeInterval] {
        let output = try await run(
            ProcessCommand(
                executable: toolchain.ffmpeg,
                arguments: ["-hide_banner", "-i", videoURL.path, "-af", "silencedetect=n=-35dB:d=0.4", "-f", "null", "-"]
            )
        )
        return FFmpegOutputParser.silenceEndTimestamps(output.text)
    }

    public func sceneChanges(in videoURL: URL) async throws -> [TimeInterval] {
        let output = try await run(
            ProcessCommand(
                executable: toolchain.ffmpeg,
                arguments: ["-hide_banner", "-i", videoURL.path, "-vf", "select=gt(scene\\,0.35),showinfo", "-an", "-f", "null", "-"]
            )
        )
        return FFmpegOutputParser.sceneTimestamps(output.text)
    }

    public func extractAudio(from videoURL: URL, chunks: [AudioChunk], directory: URL) async throws -> [AudioChunkFile] {
        var files: [AudioChunkFile] = []
        for chunk in chunks {
            try Task.checkCancellation()
            let outputURL = directory.appending(path: String(format: "chunk-%04d.m4a", chunk.index))
            _ = try await run(
                ProcessCommand(
                    executable: toolchain.ffmpeg,
                    arguments: [
                        "-hide_banner", "-loglevel", "error", "-y",
                        "-ss", String(format: "%.3f", chunk.start),
                        "-t", String(format: "%.3f", chunk.duration),
                        "-i", videoURL.path,
                        "-vn", "-ac", "1", "-c:a", "aac", "-b:a", "64k",
                        outputURL.path
                    ]
                )
            )
            files.append(AudioChunkFile(chunk: chunk, url: outputURL))
        }
        return files
    }

    public func captureFrames(from videoURL: URL, timestamps: [TimeInterval], directory: URL) async throws -> [CapturedFrame] {
        try await captureFrames(from: videoURL, timestamps: timestamps, directory: directory, onFrame: { _ in })
    }

    public func captureFrames(
        from videoURL: URL,
        timestamps: [TimeInterval],
        directory: URL,
        onFrame: @escaping @Sendable (CapturedFrame) async throws -> Void
    ) async throws -> [CapturedFrame] {
        var frames: [CapturedFrame] = []
        for timestamp in timestamps {
            try Task.checkCancellation()
            let milliseconds = Int((timestamp * 1_000).rounded())
            let outputURL = directory.appending(path: String(format: "frame-%010d.jpg", milliseconds))
            let output = try await run(
                ProcessCommand(
                    executable: toolchain.ffmpeg,
                    arguments: [
                        "-hide_banner", "-loglevel", "info", "-y",
                        "-i", videoURL.path,
                        "-ss", String(format: "%.3f", timestamp),
                        "-frames:v", "1", "-vf", "scale=1280:-2,showinfo", "-q:v", "3",
                        outputURL.path
                    ]
                )
            )
            let actualTimestamp = FFmpegOutputParser.firstFrameTimestamp(output.text) ?? timestamp
            let frame = CapturedFrame(timestamp: actualTimestamp, url: outputURL, requestedTimestamp: timestamp)
            try await onFrame(frame)
            frames.append(frame)
        }
        return frames
    }

    private func validateDependencies() throws {
        if let missing = toolchain.missingDependencies().first {
            throw MediaProcessingError.dependencyMissing(missing)
        }
    }

    private func run(_ command: ProcessCommand) async throws -> ProcessOutput {
        let output = try await runner.run(command)
        guard output.status == 0 else {
            throw MediaProcessingError.commandFailed(ProcessRunnerError.unsuccessful(command, output).localizedDescription)
        }
        return output
    }
}
