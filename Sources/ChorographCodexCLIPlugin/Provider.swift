// Provider.swift — CodexCLIProvider
// AIProvider implementation that runs the OpenAI Codex CLI as a subprocess with
// `codex exec --json` (non-interactive JSONL mode).

import Foundation
import ChorographPluginSDK

actor CodexCLIProvider: AIProvider {

    // MARK: - Identity

    nonisolated let id: ProviderID = "codex-cli"
    nonisolated let displayName: String = "Codex CLI"
    nonisolated let supportsSymbolSearch: Bool = false

    // MARK: - Configuration

    static let defaultBinaryPath: String = {
        let homebrew = "/opt/homebrew/bin/codex"
        let usrLocal  = "/usr/local/bin/codex"
        return FileManager.default.fileExists(atPath: homebrew) ? homebrew : usrLocal
    }()

    var binaryPath: String {
        get { UserDefaults.standard.string(forKey: "codexCLIPath") ?? Self.defaultBinaryPath }
        set { UserDefaults.standard.set(newValue, forKey: "codexCLIPath") }
    }

    var selectedModel: String? {
        get { UserDefaults.standard.string(forKey: "codexModel") }
        set { UserDefaults.standard.set(newValue, forKey: "codexModel") }
    }

    // MARK: - Internal state

    private let localAuth: LocalAuthManager
    private var eventContinuation: AsyncStream<any ProviderEvent>.Continuation?
    private var isStopped = false

    private var activeProcesses: [String: Process] = [:]
    private var sessionResults: [String: String] = [:]

    var shimSocketPath: String = ""
    var shimDirPath: String = ""

    // MARK: - Init

    init(localAuth: LocalAuthManager = LocalAuthManager()) {
        self.localAuth = localAuth
    }

    // MARK: - Health

    func health() async -> ProviderHealth {
        let result = await localAuth.validate(binaryPath: binaryPath)
        return ProviderHealth(
            isReachable: result.isValid,
            version: result.version,
            detail: result.errorMessage,
            activeModel: nil
        )
    }

    // MARK: - Sessions

    func createSession(title: String?) async throws -> ProviderSession {
        let validation = await localAuth.validate(binaryPath: binaryPath)
        guard validation.isValid else {
            throw ProviderError.binaryNotFound(binaryPath)
        }
        let id = UUID().uuidString
        sessionResults[id] = ""
        return ProviderSession(id: id, title: title)
    }

    func sendMessage(sessionID: String, text: String) async throws {
        let path = binaryPath
        let validation = await localAuth.validate(binaryPath: path)
        guard validation.isValid else {
            throw ProviderError.binaryNotFound(path)
        }

        let continuation = self.eventContinuation
        Task {
            await self.runCodexProcess(
                sessionID: sessionID,
                prompt: text,
                binaryPath: path,
                continuation: continuation
            )
        }
    }

    func abortSession(id: String) async throws {
        activeProcesses[id]?.terminate()
        activeProcesses.removeValue(forKey: id)
        eventContinuation?.yield(TurnFinishedEvent(sessionID: id))
    }

    func fetchLastAssistantText(sessionID: String) async throws -> String {
        sessionResults[sessionID] ?? ""
    }

    func availableModels() async throws -> [ProviderModel] {
        return [
            ProviderModel(id: "o4-mini",           displayName: "o4 Mini"),
            ProviderModel(id: "o3",                displayName: "o3"),
            ProviderModel(id: "o3-mini",           displayName: "o3 Mini"),
            ProviderModel(id: "codex-mini-latest",  displayName: "Codex Mini (latest)"),
        ]
    }

    func setSelectedModel(_ modelID: String?) {
        selectedModel = modelID
    }

    func setShimEnvironment(socketPath: String, shimDirPath: String) {
        self.shimSocketPath = socketPath
        self.shimDirPath    = shimDirPath
    }

    // MARK: - Event stream

    func eventStream() -> AsyncStream<any ProviderEvent> {
        isStopped = false
        var capturedCont: AsyncStream<any ProviderEvent>.Continuation?
        let stream = AsyncStream<any ProviderEvent> { cont in
            capturedCont = cont
        }
        self.eventContinuation = capturedCont
        capturedCont?.yield(ConnectedEvent())
        return stream
    }

    func stopEventStream() {
        isStopped = true
        for process in activeProcesses.values { process.terminate() }
        activeProcesses.removeAll()
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // MARK: - Subprocess execution

    private func runCodexProcess(
        sessionID: String,
        prompt: String,
        binaryPath: String,
        continuation: AsyncStream<any ProviderEvent>.Continuation?
    ) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)

        var args: [String] = [
            "exec",
            "--json",
            "--dangerously-bypass-approvals-and-sandbox",
            "--skip-git-repo-check",
        ]
        if let model = selectedModel, !model.isEmpty {
            args += ["--model", model]
        }
        args.append(prompt)
        process.arguments = args

        let workDir = UserDefaults.standard.string(forKey: "serverDirectory")
            ?? FileManager.default.currentDirectoryPath
        process.currentDirectoryURL = URL(fileURLWithPath: workDir)

        let pipe    = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = errPipe
        process.standardInput  = FileHandle.nullDevice

        activeProcesses[sessionID] = process

        if !shimSocketPath.isEmpty, !shimDirPath.isEmpty {
            var env = ProcessInfo.processInfo.environment
            let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = shimDirPath + ":" + existingPath
            env["CHOROGRAPH_SHIM_SOCKET"] = shimSocketPath
            env["CHOROGRAPH_REAL_BASH"] = "/bin/bash"
            process.environment = env
        }

        var outCont: AsyncStream<Data>.Continuation?
        var errCont: AsyncStream<Data>.Continuation?

        let outputStream = AsyncStream<Data> { cont in outCont = cont }
        let errorStream  = AsyncStream<Data> { cont in errCont = cont }

        pipe.fileHandleForReading.readabilityHandler = { [outCont] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                outCont?.finish()
            } else {
                outCont?.yield(data)
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [errCont] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                errCont?.finish()
            } else {
                errCont?.yield(data)
            }
        }

        process.terminationHandler = { [outCont, errCont] _ in
            outCont?.finish()
            errCont?.finish()
        }

        Task {
            var stderrBuffer = ""
            for await chunk in errorStream {
                guard let text = String(data: chunk, encoding: .utf8) else { continue }
                stderrBuffer += text
                while let newlineRange = stderrBuffer.range(of: "\n") {
                    let line = String(stderrBuffer[stderrBuffer.startIndex..<newlineRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    stderrBuffer = String(stderrBuffer[newlineRange.upperBound...])
                    if !line.isEmpty { continuation?.yield(ErrorEvent(line)) }
                }
            }
            let remaining = stderrBuffer.trimmingCharacters(in: .whitespaces)
            if !remaining.isEmpty { continuation?.yield(ErrorEvent(remaining)) }
        }

        do {
            try process.run()
        } catch {
            continuation?.yield(ErrorEvent("Failed to launch Codex CLI: \(error.localizedDescription)"))
            continuation?.yield(TurnFinishedEvent(sessionID: sessionID))
            activeProcesses.removeValue(forKey: sessionID)
            return
        }

        var lineBuffer = ""
        for await chunk in outputStream {
            guard let text = String(data: chunk, encoding: .utf8) else { continue }
            lineBuffer += text
            while let newlineRange = lineBuffer.range(of: "\n") {
                let line = String(lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound])
                lineBuffer = String(lineBuffer[newlineRange.upperBound...])
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    handleJSONLLine(line, sessionID: sessionID, continuation: continuation)
                }
            }
        }
        if !lineBuffer.trimmingCharacters(in: .whitespaces).isEmpty {
            handleJSONLLine(lineBuffer, sessionID: sessionID, continuation: continuation)
        }

        process.waitUntilExit()
        activeProcesses.removeValue(forKey: sessionID)

        let exitCode = process.terminationStatus
        if exitCode != 0 {
            continuation?.yield(ErrorEvent("Codex CLI exited with code \(exitCode)."))
        }

        let finalText = sessionResults[sessionID] ?? ""
        continuation?.yield(AssistantReplyEvent(sessionID: sessionID, text: finalText))
        continuation?.yield(TurnFinishedEvent(sessionID: sessionID))
    }

    // MARK: - JSONL parsing

    func handleJSONLLine(
        _ line: String,
        sessionID: String,
        continuation: AsyncStream<any ProviderEvent>.Continuation?
    ) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "thread.started", "turn.started", "item.started":
            break

        case "item.completed":
            guard let item = json["item"] as? [String: Any] else { return }
            handleItem(item, sessionID: sessionID, continuation: continuation)

        case "turn.completed":
            continuation?.yield(TurnFinishedEvent(sessionID: sessionID))

        case "error":
            if let msg = json["message"] as? String {
                continuation?.yield(ErrorEvent("codex: \(msg)"))
            }

        default:
            continuation?.yield(OtherEvent(type: type))
        }
    }

    private func handleItem(
        _ item: [String: Any],
        sessionID: String,
        continuation: AsyncStream<any ProviderEvent>.Continuation?
    ) {
        guard let itemType = item["type"] as? String else { return }

        switch itemType {
        case "agent_message":
            if let text = item["text"] as? String {
                var existing = sessionResults[sessionID] ?? ""
                existing += text
                sessionResults[sessionID] = existing
            }

        case "command_execution":
            if !shimSocketPath.isEmpty { break }
            if let command = item["command"] as? String,
               let event = codexCommandEvent(command: command) {
                continuation?.yield(event)
            } else if let command = item["command"] as? String {
                continuation?.yield(ToolCallEvent(name: "shell", input: ["command": command]))
            }

        case "reasoning":
            break

        default:
            break
        }
    }

    func codexCommandEvent(command: String) -> (any ProviderEvent)? {
        let workDir = UserDefaults.standard.string(forKey: "serverDirectory")
            ?? FileManager.default.currentDirectoryPath

        let inner = ShellCommandParser.strippedBashWrapper(command)

        if let path = ShellCommandParser.matchSimpleReadCommand(inner, tools: ["cat", "head", "tail", "less", "more", "wc"]) {
            return ReadFileEvent(path: resolvedAbsolutePath(path, workDir: workDir))
        }

        if let path = ShellCommandParser.matchSimpleReadCommand(inner, tools: ["tee", "touch", "truncate"]) {
            return WriteFileEvent(path: resolvedAbsolutePath(path, workDir: workDir))
        }

        if inner.hasPrefix("sed "), inner.contains(" -i") {
            if let path = ShellCommandParser.lastNonFlagArg(inner) {
                return PatchFileEvent(path: resolvedAbsolutePath(path, workDir: workDir))
            }
        }

        if inner.hasPrefix("patch ") {
            if let path = ShellCommandParser.lastNonFlagArg(inner) {
                return PatchFileEvent(path: resolvedAbsolutePath(path, workDir: workDir))
            }
        }

        return nil
    }

    private func resolvedAbsolutePath(_ path: String, workDir: String) -> String {
        guard !path.hasPrefix("/") else { return path }
        return (workDir as NSString).appendingPathComponent(path)
    }
}
