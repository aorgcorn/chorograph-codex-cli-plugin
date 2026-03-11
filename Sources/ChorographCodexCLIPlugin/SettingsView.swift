// SettingsView.swift — Codex CLI settings panel

import SwiftUI
import ChorographPluginSDK

struct CodexCLISettingsView: View {
    @AppStorage("codexCLIPath") private var binaryPath = CodexCLIProvider.defaultBinaryPath
    @AppStorage("codexModel")   private var selectedModel = ""
    @State private var healthStatus: HealthStatus = .unknown
    @State private var availableModels: [ProviderModel] = []
    @State private var isLoadingModels = false

    private let provider = CodexCLIProvider()

    enum HealthStatus {
        case unknown, checking, ok(String), failed(String)
        var isChecking: Bool { if case .checking = self { return true }; return false }
        var label: String {
            switch self {
            case .unknown:         return "Not checked"
            case .checking:        return "Checking…"
            case .ok(let v):       return v.isEmpty ? "Found" : "Found — \(v)"
            case .failed(let msg): return msg
            }
        }
        var color: Color {
            switch self {
            case .unknown, .checking: return .secondary
            case .ok:                 return .green
            case .failed:             return .red
            }
        }
    }

    var body: some View {
        Form {
            Section("Binary") {
                TextField("Path to codex binary", text: $binaryPath)
                    .onSubmit { Task { await checkHealth() } }

                HStack {
                    Button("Check") { Task { await checkHealth() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(healthStatus.isChecking)

                    if healthStatus.isChecking { ProgressView().scaleEffect(0.7) }

                    Text(healthStatus.label)
                        .font(.caption)
                        .foregroundStyle(healthStatus.color)
                }
            }

            Section("Model") {
                if isLoadingModels {
                    HStack {
                        ProgressView().scaleEffect(0.7)
                        Text("Loading models…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if availableModels.isEmpty {
                    Text("No models available.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: $selectedModel) {
                        Text("CLI default").tag("")
                        ForEach(availableModels) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .onChange(of: selectedModel) { newValue in
                        Task { await provider.setSelectedModel(newValue.isEmpty ? nil : newValue) }
                    }
                }
            }

            Section("Info") {
                Text("Install via: npm install -g @openai/codex")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Set OPENAI_API_KEY in your environment before use.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .task { await checkHealth() }
        .task { await loadModels() }
    }

    private func checkHealth() async {
        healthStatus = .checking
        let h = await provider.health()
        if h.isReachable {
            healthStatus = .ok(h.version ?? "")
        } else {
            healthStatus = .failed(h.detail ?? "Not found")
        }
    }

    private func loadModels() async {
        isLoadingModels = true
        do {
            availableModels = try await provider.availableModels()
        } catch {
            availableModels = []
        }
        isLoadingModels = false
    }
}
