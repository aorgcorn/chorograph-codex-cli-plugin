// Plugin.swift — ChorographCodexCLIPlugin
// Entry point for the Codex CLI Chorograph plugin.
// Registers CodexCLIProvider as an AI provider and a settings panel.

import ChorographPluginSDK
import SwiftUI

public final class CodexCLIPlugin: ChorographPlugin, @unchecked Sendable {

    public let manifest = PluginManifest(
        id: "com.chorograph.plugin.codex-cli",
        displayName: "Codex CLI",
        description: "Drives the OpenAI Codex CLI subprocess and streams JSONL events.",
        version: "1.1.2",
        capabilities: [.aiProvider, .settingsPanel]
    )

    public init() {}

    public func bootstrap(context: any PluginContextProviding) async throws {
        context.registerProvider(CodexCLIProvider())
        context.registerSettingsPanel(title: "Codex CLI", AnyView(CodexCLISettingsView()))
    }
}

// MARK: - C-ABI factory (required for dlopen-based loading)

@_cdecl("chorograph_plugin_create")
public func chorographPluginCreate() -> UnsafeMutableRawPointer {
    let plugin = CodexCLIPlugin()
    return Unmanaged.passRetained(plugin as AnyObject).toOpaque()
}
