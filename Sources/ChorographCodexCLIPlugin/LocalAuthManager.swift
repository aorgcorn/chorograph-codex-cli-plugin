// LocalAuthManager.swift
// Validates that a local CLI binary exists, is a regular file, and is executable.

import Foundation

actor LocalAuthManager {

    struct ValidationResult: Sendable {
        let isValid: Bool
        let version: String?
        let errorMessage: String?
    }

    func validate(binaryPath: String) async -> ValidationResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: binaryPath, isDirectory: &isDir),
              !isDir.boolValue else {
            return ValidationResult(
                isValid: false,
                version: nil,
                errorMessage: "Binary not found at '\(binaryPath)'."
            )
        }

        guard fm.isExecutableFile(atPath: binaryPath) else {
            return ValidationResult(
                isValid: false,
                version: nil,
                errorMessage: "File at '\(binaryPath)' is not executable."
            )
        }

        let version = await runVersion(binaryPath: binaryPath)
        return ValidationResult(isValid: true, version: version, errorMessage: nil)
    }

    private func runVersion(binaryPath: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = ["--version"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError  = Pipe()

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: output?.isEmpty == false ? output : nil)
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
