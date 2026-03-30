use chorograph_plugin_sdk_rust::prelude::*;
use serde_json::json;

struct CodexCLI;

impl CodexCLI {
    /// Formats all messages before the final user turn into a conversation transcript
    /// so that the CLI has full context when replying. Returns an empty string when
    /// there is only one message (first-turn / "chat" action — no history yet).
    fn format_history(&self, messages: &[serde_json::Value]) -> String {
        // Drop the last message (the new user prompt — already included in the prompt itself).
        let prior: Vec<&serde_json::Value> = messages
            .iter()
            .rev()
            .skip(1) // skip the final user message
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();

        if prior.is_empty() {
            return String::new();
        }

        let mut history = String::from("\n\n### Conversation History (most recent context):\n");
        for msg in &prior {
            let role = msg
                .get("role")
                .and_then(|r| r.as_str())
                .unwrap_or("unknown");
            let text = msg.get("text").and_then(|t| t.as_str()).unwrap_or("");
            let label = if role == "user" { "User" } else { "Assistant" };
            history.push_str(&format!("\n**{}:** {}\n", label, text));
        }
        history.push_str("\n---\nContinue the conversation based on the history above.\n");
        history
    }

    fn format_skeletons(&self, payload: &serde_json::Value) -> String {
        let mut context = String::new();
        if let Some(skeletons) = payload.get("skeletons").and_then(|s| s.as_array()) {
            if !skeletons.is_empty() {
                context.push_str("\n\n### Project Structure Context (AST Skeletons):\n");
                for skel in skeletons {
                    if let (Some(path), Some(symbols)) = (
                        skel.get("path").and_then(|p| p.as_str()),
                        skel.get("symbols").and_then(|s| s.as_array()),
                    ) {
                        context.push_str(&format!("\nFile: `{}`\n", path));
                        for sym in symbols {
                            if let (Some(name), Some(kind), Some(line)) = (
                                sym.get("name").and_then(|n| n.as_str()),
                                sym.get("kind").and_then(|k| k.as_str()),
                                sym.get("line").and_then(|l| l.as_u64()),
                            ) {
                                context.push_str(&format!(
                                    "  - {} `{}` (line {})\n",
                                    kind, name, line
                                ));
                            }
                        }
                    }
                }
            }
        }
        context
    }
}

impl AIProvider for CodexCLI {
    fn id(&self) -> String {
        "codex-cli".to_string()
    }
    fn display_name(&self) -> String {
        "Codex CLI (Rust)".to_string()
    }
    fn get_models(&self) -> Vec<ModelInfo> {
        vec![ModelInfo {
            id: "default".to_string(),
            name: "Default Model".to_string(),
        }]
    }

    fn send_message(&self, session_id: &str, text: &str) -> Result<()> {
        log!(
            "[Codex Plugin] Spawning codex exec for session={}",
            session_id
        );
        let child = match ChildProcess::spawn(
            "codex",
            vec![
                "exec",
                "--json",
                "--dangerously-bypass-approvals-and-sandbox",
                "--skip-git-repo-check",
                text,
            ],
            None,
            std::collections::HashMap::new(),
        ) {
            Ok(c) => c,
            Err(e) => {
                log!("[Codex Plugin] Failed to spawn codex: {:?}", e);
                push_ai_event(
                    session_id,
                    &AIEvent::Error {
                        message: format!("Failed to spawn codex: {:?}", e),
                    },
                );
                push_ai_event(
                    session_id,
                    &AIEvent::TurnCompleted {
                        session_id: session_id.to_string(),
                    },
                );
                return Err(e);
            }
        };

        let mut buffer = Vec::new();
        while child.wait_for_data(60000) {
            if let Ok(ReadResult::Data(err_data)) = child.read(PipeType::Stderr) {
                if !err_data.is_empty() {
                    let err_msg = String::from_utf8_lossy(&err_data);
                    log!("[Codex Plugin] Stderr: {}", err_msg);
                    push_ai_event(
                        session_id,
                        &AIEvent::Error {
                            message: err_msg.to_string(),
                        },
                    );
                }
            }

            match child.read(PipeType::Stdout)? {
                ReadResult::Data(data) => {
                    log!("[Codex Plugin] Read {} bytes from stdout", data.len());
                    buffer.extend(data);
                    while let Some(pos) = buffer.iter().position(|&b| b == b'\n') {
                        let line = buffer.drain(..=pos).collect::<Vec<_>>();
                        if let Ok(val) = serde_json::from_slice::<serde_json::Value>(&line) {
                            // command_execution items are intercepted by chorograph-shim at the
                            // bash level and streamed line-by-line via the Unix socket — no need
                            // to forward them here.
                            if val.get("type") == Some(&json!("item.completed")) {
                                if let Some(item) = val.get("item") {
                                    let item_type = item.get("type").and_then(|t| t.as_str());
                                    if item_type == Some("agent_message") {
                                        if let Some(msg) = item.get("text").and_then(|t| t.as_str())
                                        {
                                            push_ai_event(
                                                session_id,
                                                &AIEvent::AssistantReply {
                                                    session_id: session_id.to_string(),
                                                    text: msg.to_string(),
                                                },
                                            );
                                        }
                                    } else if item_type == Some("reasoning") {
                                        if let Some(msg) = item.get("text").and_then(|t| t.as_str())
                                        {
                                            push_ai_event(
                                                session_id,
                                                &AIEvent::Reasoning {
                                                    session_id: session_id.to_string(),
                                                    text: msg.trim_matches('*').trim().to_string(),
                                                },
                                            );
                                        }
                                    } else if item_type == Some("file_change") {
                                        // Codex has written files to disk.  Emit a ToolCall for the
                                        // activity log AND a CrdtWrite so the host captures the
                                        // content into the CRDT VFS as a speculative write that the
                                        // user can approve or reject from the canvas overlay card.
                                        if let Some(changes) =
                                            item.get("changes").and_then(|c| c.as_array())
                                        {
                                            for change in changes {
                                                if let Some(path) =
                                                    change.get("path").and_then(|p| p.as_str())
                                                {
                                                    push_ai_event(
                                                        session_id,
                                                        &AIEvent::ToolCall {
                                                            name: format!("WRITE {}", path),
                                                        },
                                                    );
                                                    match read_host_file(path) {
                                                        Ok(content) => {
                                                            push_ai_event(
                                                                session_id,
                                                                &AIEvent::CrdtWrite {
                                                                    session_id: session_id
                                                                        .to_string(),
                                                                    path: path.to_string(),
                                                                    content,
                                                                },
                                                            );
                                                        }
                                                        Err(e) => {
                                                            log!(
                                                                "[Codex Plugin] Failed to read file {} for CrdtWrite: {:?}",
                                                                path,
                                                                e
                                                            );
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            if val.get("type") == Some(&json!("item.delta")) {
                                if let Some(delta) = val
                                    .get("delta")
                                    .and_then(|d| d.get("text"))
                                    .and_then(|t| t.as_str())
                                {
                                    push_ai_event(
                                        session_id,
                                        &AIEvent::StreamingDelta {
                                            session_id: session_id.to_string(),
                                            text: delta.to_string(),
                                        },
                                    );
                                }
                            }
                        }
                    }
                }
                ReadResult::EOF => {
                    log!("[Codex Plugin] Stdout EOF reached");
                    break;
                }
                ReadResult::Empty => continue,
            }
        }

        log!("[Codex Plugin] Turn completed");
        push_ai_event(
            session_id,
            &AIEvent::TurnCompleted {
                session_id: session_id.to_string(),
            },
        );

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
pub fn handle_action(action_id: String, payload: serde_json::Value) {
    let provider = CodexCLI;
    log!(
        "[Codex Plugin] handle_action id={} payload={}",
        action_id,
        payload
    );

    let context = provider.format_skeletons(&payload);

    if action_id == "send_test" {
        let _ = provider.send_message("test-session", "echo Ported to Rust WASM!");
    } else if action_id == "chat"
        || action_id == "reply"
        || action_id == "plan"
        || action_id == "engage"
    {
        // All action variants use the same messages-array protocol.
        // Every turn is speculative: CrdtWrite events are always emitted so the
        // host shows overlay cards on the canvas for user approval/discard.
        if let Some(session_id) = payload.get("session_id").and_then(|s| s.as_str()) {
            let messages = payload
                .get("messages")
                .and_then(|m| m.as_array())
                .map(|v| v.as_slice())
                .unwrap_or(&[]);

            let last_user_text = messages
                .iter()
                .rev()
                .find(|m| m.get("role").and_then(|r| r.as_str()) == Some("user"))
                .and_then(|m| m.get("text").and_then(|t| t.as_str()))
                .unwrap_or("");

            if !last_user_text.is_empty() {
                let history = provider.format_history(messages);
                let final_prompt = format!("{}{}{}", last_user_text, history, context);
                let _ = provider.send_message(session_id, &final_prompt);
            } else {
                log!(
                    "[Codex Plugin] {}: no user message found in payload",
                    action_id
                );
            }
        }
    }
}
