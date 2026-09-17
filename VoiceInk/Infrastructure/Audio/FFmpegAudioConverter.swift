import Foundation

enum FFmpegAudioConverter {
    enum ConversionError: LocalizedError {
        case unavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return String(localized: "FFmpeg is required to transcribe WebM files. Install it with Homebrew using: brew install ffmpeg")
            case let .failed(details):
                return String(localized: "FFmpeg failed to convert the WebM file: \(details)")
            }
        }
    }

    static func convertWebMToWav(_ inputURL: URL) async throws -> URL {
        guard let executablePath = await findExecutable() else {
            throw ConversionError.unavailable
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let result = await run(
            executablePath: executablePath,
            arguments: [
                "-nostdin", "-hide_banner", "-loglevel", "error",
                "-i", inputURL.path,
                "-vn", "-ac", "1", "-ar", "16000", "-sample_fmt", "s16",
                "-f", "wav", outputURL.path,
            ]
        )

        guard result.exitCode == 0, FileManager.default.fileExists(atPath: outputURL.path) else {
            try? FileManager.default.removeItem(at: outputURL)
            let details = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConversionError.failed(details.isEmpty ? "unknown error" : details)
        }

        return outputURL
    }

    private static func findExecutable() async -> String? {
        let knownInstallPaths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/local/bin/ffmpeg",
        ]
        if let path = knownInstallPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }

        return await Task.detached(priority: .utility) {
            let path = ShellCommandEnvironment.preferredPATH(fallback: ProcessInfo.processInfo.environment["PATH"])
            return path.split(separator: ":")
                .map { "\($0)/ffmpeg" }
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        }.value
    }

    private struct ProcessResult {
        let exitCode: Int32
        let output: String
    }

    private static func run(executablePath: String, arguments: [String]) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let output = String(
                        data: pipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                    continuation.resume(
                        returning: ProcessResult(exitCode: process.terminationStatus, output: output)
                    )
                } catch {
                    continuation.resume(
                        returning: ProcessResult(exitCode: -1, output: error.localizedDescription)
                    )
                }
            }
        }
    }
}
