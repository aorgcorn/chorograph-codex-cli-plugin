use chorograph_plugin_sdk_rust::prelude::*;
use serde_json::json;

struct CodexCLI;

impl AIProvider for CodexCLI {
    fn id(&self) -> String { "codex-cli".to_string() }
    fn display_name(&self) -> String { "Codex CLI (Rust)".to_string() }
    fn get_models(&self) -> Vec<ModelInfo> {
        vec![ModelInfo { id: "default".to_string(), name: "Default Model".to_string() }]
    }

    fn send_message(&self, session_id: &str, text: &str) -> Result<()> {
        let child = ChildProcess::spawn(
            "codex",
            vec![
                "exec",
                "--json",
                "--dangerously-bypass-approvals-and-sandbox",
                "--skip-git-repo-check",
                text
            ],
            None,
            std::collections::HashMap::new()
        )?;

        let mut buffer = Vec::new();
        // Use a longer timeout for thinking steps
        while child.wait_for_data(60000) {
            // Handle Stderr for errors
            if let Ok(ReadResult::Data(err_data)) = child.read(PipeType::Stderr) {
                if !err_data.is_empty() {
                    let err_msg = String::from_utf8_lossy(&err_data);
                    push_ai_event(session_id, &AIEvent::Error { message: err_msg.to_string() });
                }
            }

            match child.read(PipeType::Stdout)? {
                ReadResult::Data(data) => {
                    buffer.extend(data);
                    while let Some(pos) = buffer.iter().position(|&b| b == b'\n') {
                        let line = buffer.drain(..=pos).collect::<Vec<_>>();
                        if let Ok(val) = serde_json::from_slice::<serde_json::Value>(&line) {
                            // Robust JSONL parsing matching Swift logic
                            if val.get("type") == Some(&json!("item.completed")) {
                                if let Some(item) = val.get("item") {
                                    if item.get("type") == Some(&json!("agent_message")) {
                                        if let Some(msg) = item.get("text").and_then(|t| t.as_str()) {
                                            push_ai_event(session_id, &AIEvent::AssistantReply {
                                                session_id: session_id.to_string(),
                                                text: msg.to_string(),
                                            });
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                ReadResult::EOF => break,
                ReadResult::Empty => continue,
            }
        }

        push_ai_event(session_id, &AIEvent::TurnCompleted {
            session_id: session_id.to_string(),
        });

        Ok(())
    }
}

#[chorograph_plugin]
pub fn init() {
    let ui = json!([
        { "type": "label", "text": "Codex CLI (Rust WASM)" },
        { "type": "button", "text": "Send Test Prompt", "action": "send_test" }
    ]);
    push_ui(&ui.to_string());
}

#[chorograph_plugin]
pub fn handle_action(action_id: String, _payload: serde_json::Value) {
    if action_id == "send_test" {
        let provider = CodexCLI;
        let _ = provider.send_message("test-session", "echo Ported to Rust WASM!");
    }
}
