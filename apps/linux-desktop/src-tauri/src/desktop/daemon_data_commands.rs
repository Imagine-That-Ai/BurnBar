fn compose_usage_summary_response(
    projection_response: serde_json::Value,
    recent_response: serde_json::Value,
) -> Result<serde_json::Value, String> {
    let projection = projection_response
        .get("projection")
        .cloned()
        .ok_or_else(|| "daemon.usage.projection response is missing projection".to_string())?;
    if !projection.is_object() {
        return Err("daemon.usage.projection projection must be an object".to_string());
    }
    Ok(serde_json::json!({
        "projection": projection,
        "recent": recent_response,
    }))
}

#[tauri::command]
fn usage_summary() -> Result<serde_json::Value, String> {
    let projection = call_daemon_method("daemon.usage.projection", Some(serde_json::json!({})))?;
    let recent = call_daemon_method(
        "daemon.usage.recent",
        Some(serde_json::json!({"limit": 12})),
    )?;
    compose_usage_summary_response(projection, recent)
}

// ───────────────── P02: provider catalog ─────────────────
// Wire: daemon.config.get + daemon.catalog (BurnBarRPCMethod.configGet/catalog)
//
// `daemon.config.get` owns user configuration, while `daemon.catalog` owns the
// canonical provider/model metadata. Keep those authorities separate on the
// wire so the renderer can distinguish a verified catalog from config-only
// fallback instead of silently presenting configured models as canonical.
fn compose_provider_catalog_response(
    config: serde_json::Value,
    catalog: Result<serde_json::Value, String>,
    quota: Result<serde_json::Value, String>,
) -> serde_json::Value {
    let mut response = serde_json::Map::new();
    response.insert("config".to_string(), config);
    match catalog {
        Ok(catalog) => {
            response.insert("catalog".to_string(), catalog);
            response.insert(
                "catalogAvailable".to_string(),
                serde_json::Value::Bool(true),
            );
        }
        Err(error) => {
            response.insert(
                "catalogAvailable".to_string(),
                serde_json::Value::Bool(false),
            );
            response.insert("catalogError".to_string(), serde_json::Value::String(error));
        }
    }
    match quota {
        Ok(quota) => {
            response.insert("quota".to_string(), quota);
            response.insert("quotaAvailable".to_string(), serde_json::Value::Bool(true));
        }
        Err(error) => {
            response.insert("quotaAvailable".to_string(), serde_json::Value::Bool(false));
            response.insert("quotaError".to_string(), serde_json::Value::String(error));
        }
    }
    serde_json::Value::Object(response)
}

#[tauri::command]
fn provider_catalog() -> Result<serde_json::Value, String> {
    let config = call_daemon_method("daemon.config.get", None)?;
    let catalog = call_daemon_method("daemon.catalog", None);
    let quota = call_daemon_method(
        "daemon.quota.signals.recent",
        Some(serde_json::json!({"limit": 200})),
    );
    Ok(compose_provider_catalog_response(config, catalog, quota))
}

// ───────────────── P03: session list ─────────────────
// Wire: daemon.usage.recent (BurnBarRPCMethod.usageRecent)
// BurnBarRecentUsageRequest has ONLY `limit` — no offset field exists.
// Fetch a large batch; the TS store paginates client-side (page size 50).
#[tauri::command]
fn session_list() -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.usage.recent",
        Some(serde_json::json!({"limit": 500})),
    )
}

// Full-history export uses a daemon-owned indexed-conversation snapshot. The
// response must carry `historyComplete: true`; the renderer never infers it
// from the bounded recent-usage result.
#[tauri::command]
fn session_history() -> Result<serde_json::Value, String> {
    call_daemon_method(
        DAEMON_USAGE_HISTORY_METHOD,
        Some(serde_json::json!({"limit": 500})),
    )
}

// ───────────────── P03: session search ─────────────────
// Wire: daemon.search.query (BurnBarRPCMethod.searchQuery)
#[tauri::command]
fn session_search(query: String) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.search.query",
        Some(serde_json::json!({"query": query})),
    )
}

// ───────────────── P03: persisted session body / resume ─────────────────
// BurnBarResumeService reads the indexed conversations table and returns either
// a bounded historical briefing (print) or an explicit native/fallback launch
// result (spawn). The shell never fabricates transcript content.
fn validated_session_id(session_id: String) -> Result<String, String> {
    let trimmed = session_id.trim();
    if trimmed.is_empty() {
        return Err("session_id_must_not_be_empty".to_string());
    }
    if trimmed.len() > 512 || trimmed.chars().any(|character| character.is_control()) {
        return Err("session_id_invalid".to_string());
    }
    Ok(trimmed.to_string())
}

fn session_resume_params(
    session_id: String,
    mode: &'static str,
) -> Result<serde_json::Value, String> {
    let session_id = validated_session_id(session_id)?;
    Ok(serde_json::json!({
        "sessionID": session_id,
        "mode": mode,
    }))
}

fn session_resume_wire(
    session_id: String,
    mode: &'static str,
) -> Result<serde_json::Value, String> {
    let params = session_resume_params(session_id, mode)?;
    call_daemon_method(DAEMON_RUN_RESUME_METHOD, Some(params))
}

#[tauri::command]
fn session_replay(session_id: String) -> Result<serde_json::Value, String> {
    session_resume_wire(session_id, "print")
}

#[tauri::command]
fn session_resume(session_id: String) -> Result<serde_json::Value, String> {
    session_resume_wire(session_id, "spawn")
}

// ───────────── Exact persisted chat threads ─────────────

fn chat_thread_list_wire(query: Option<String>, limit: u32) -> (&'static str, serde_json::Value) {
    let mut params = serde_json::Map::from_iter([("limit".into(), serde_json::json!(limit))]);
    if let Some(query) = query {
        params.insert("query".into(), serde_json::json!(query));
    }
    ("daemon.chat.thread.list", serde_json::Value::Object(params))
}

#[tauri::command]
fn chat_thread_list(query: Option<String>, limit: u32) -> Result<serde_json::Value, String> {
    let (method, params) = chat_thread_list_wire(query, limit);
    call_daemon_method(method, Some(params))
}

fn chat_thread_get_wire(
    thread_id: String,
    max_messages: u32,
    before_timestamp: Option<String>,
    before_message_id: Option<String>,
) -> (&'static str, serde_json::Value) {
    let mut params = serde_json::Map::from_iter([
        ("threadID".into(), serde_json::json!(thread_id)),
        ("maxMessages".into(), serde_json::json!(max_messages)),
    ]);
    if let Some(before_timestamp) = before_timestamp {
        params.insert(
            "beforeTimestamp".into(),
            serde_json::json!(before_timestamp),
        );
    }
    if let Some(before_message_id) = before_message_id {
        params.insert(
            "beforeMessageID".into(),
            serde_json::json!(before_message_id),
        );
    }
    ("daemon.chat.thread.get", serde_json::Value::Object(params))
}

#[tauri::command]
fn chat_thread_get(
    thread_id: String,
    max_messages: u32,
    before_timestamp: Option<String>,
    before_message_id: Option<String>,
) -> Result<serde_json::Value, String> {
    let (method, params) =
        chat_thread_get_wire(thread_id, max_messages, before_timestamp, before_message_id);
    call_daemon_method(method, Some(params))
}

#[tauri::command]
fn chat_message_append(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.chat.message.append", Some(request))
}

// ───────────── AI Inbox / Founder Lens daemon authority ─────────────
//
// These commands are intentionally thin. Swift owns validation, persistence,
// egress, budget, and approval policy; the Linux shell preserves the canonical
// Codable field names and forwards one typed renderer request object as the
// daemon RPC `params` object.
#[tauri::command]
fn inbox_list(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.list", Some(request))
}

#[tauri::command]
fn inbox_get(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.get", Some(request))
}

#[tauri::command]
fn inbox_presentation_list(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.presentation.list", Some(request))
}

#[tauri::command]
fn inbox_presentation_get(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.presentation.get", Some(request))
}

#[tauri::command]
fn inbox_presentation_mutate(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.presentation.mutate", Some(request))
}

#[tauri::command]
fn inbox_presentation_mark_all_read(
    request: serde_json::Value,
) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.presentation.mark_all_read", Some(request))
}

#[tauri::command]
fn inbox_runs_recent(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.runs.recent", Some(request))
}

#[tauri::command]
fn inbox_config_get() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.config.get", None)
}

#[tauri::command]
fn inbox_config_update(config: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.config.update", Some(config))
}

#[tauri::command]
fn inbox_run_now(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.run_now", Some(request))
}

#[tauri::command]
fn inbox_thread_get(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.thread.get", Some(request))
}

#[tauri::command]
fn inbox_reply(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.reply", Some(request))
}

#[tauri::command]
fn inbox_plans_list(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.plans.list", Some(request))
}

#[tauri::command]
fn inbox_plans_get(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.plans.get", Some(request))
}

#[tauri::command]
fn inbox_plans_accept(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.plans.accept", Some(request))
}

#[tauri::command]
fn inbox_plans_update_step(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.plans.update_step", Some(request))
}

#[tauri::command]
fn inbox_plans_grade(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.plans.grade", Some(request))
}

#[tauri::command]
fn inbox_memory_candidate_approve(
    request: serde_json::Value,
) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.memory_candidate.approve", Some(request))
}

#[tauri::command]
fn inbox_plans_remember_step(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.plans.remember_step", Some(request))
}

#[tauri::command]
fn inbox_plans_create_followup(
    request: serde_json::Value,
) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.plans.create_followup", Some(request))
}

#[tauri::command]
fn inbox_memory_export(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.inbox.memory.export", Some(request))
}

// ───────────────── P05: usage insights ─────────────────
// Wire: daemon.usage.insights. The daemon owns the bounded digest and local
// rules analysis; the renderer only receives the typed usage/analysis result.
#[tauri::command]
fn usage_insights() -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.usage.insights",
        Some(serde_json::json!({
            "limit": 200,
            "windowSeconds": 604800,
            "prompt": "Summarize the most important usage changes and actions."
        })),
    )
}

// ───────────────── P06: mission list ─────────────────
// Wire: daemon.mission.list (BurnBarRPCMethod.missionsList)
#[tauri::command]
fn mission_list() -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.mission.list",
        Some(serde_json::json!({
            "projectSlug": null,
            "statuses": [
                "draft",
                "awaiting_approval",
                "approved",
                "dispatching",
                "in_progress",
                "partially_completed",
                "completed",
                "failed",
                "cancelled"
            ],
            "limit": 100
        })),
    )
}

// ───────────────── P20: mission detail ─────────────────
// Wire: daemon.mission.get (BurnBarRPCMethod.missionGet)
#[tauri::command]
fn mission_get(mission_id: String) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.mission.get",
        Some(serde_json::json!({"missionID": mission_id})),
    )
}

// ───────────────── P20: mission health/history ─────────────────
// Wire: daemon.mission.health (BurnBarRPCMethod.missionHealth)
#[tauri::command]
fn mission_health(mission_id: String) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.mission.health",
        Some(serde_json::json!({"missionID": mission_id})),
    )
}

// ───────────────── P20: mission resume/dispatch ─────────────────
// Wire: daemon.mission.packet.dispatch
//
// Linux does not invent execution state in the renderer. A resume action
// submits a fresh, daemon-owned packet and lets the daemon enforce approval,
// terminal-state, enterprise-policy, and runtime-readiness gates before any
// side effect. The readiness gate is intentionally fail-closed when the
// packaged daemon is not configured for execution.
fn mission_resume_wire(mission_id: &str) -> Result<(&'static str, serde_json::Value), String> {
    let mission_id = mission_id.trim();
    if mission_id.is_empty() || mission_id.len() > 256 {
        return Err("Mission id must contain between 1 and 256 bytes.".to_string());
    }
    let packet_id = format!("linux-resume-{}", uuid::Uuid::new_v4());
    Ok((
        "daemon.mission.packet.dispatch",
        serde_json::json!({
            "missionID": mission_id,
            "actor": "linux-shell",
            "packet": {
                "id": packet_id,
                "missionID": mission_id,
                "workerName": "linux-shell",
                "objective": "Resume the mission from its latest daemon checkpoint.",
                "status": "queued",
                "runID": null,
                "dispatchedAt": null,
                "completedAt": null,
                "metadata": {
                    "source": "linux-shell",
                    "surface": "missions",
                    "action": "resume"
                }
            }
        }),
    ))
}

#[tauri::command]
fn mission_resume(mission_id: String) -> Result<serde_json::Value, String> {
    let (method, params) = mission_resume_wire(&mission_id)?;
    call_daemon_method(method, Some(params))
}

// ───────────────── P20: pending controller questions ─────────────────
// Wire: daemon.question.list / daemon.question.answer
#[tauri::command]
fn question_list() -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.question.list",
        Some(serde_json::json!({
            "projectSlug": null,
            "statuses": ["pending"],
            "limit": 100
        })),
    )
}

#[tauri::command]
fn question_answer(
    question_id: String,
    answer: String,
    selected_option_id: Option<String>,
) -> Result<serde_json::Value, String> {
    let (method, params) = question_answer_wire(&question_id, &answer, selected_option_id.as_deref())?;
    call_daemon_method(method, Some(params))
}

fn question_answer_wire(
    question_id: &str,
    answer: &str,
    selected_option_id: Option<&str>,
) -> Result<(&'static str, serde_json::Value), String> {
    let question_id = question_id.trim();
    if question_id.is_empty() || question_id.len() > 256 {
        return Err("Question id must contain between 1 and 256 bytes.".to_string());
    }
    let answer = answer.trim();
    if answer.is_empty() || answer.len() > 16_384 {
        return Err("Question answer must contain between 1 and 16384 bytes.".to_string());
    }
    let selected_option_id = selected_option_id
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    if selected_option_id.as_ref().is_some_and(|value| value.len() > 256) {
        return Err("Selected option id must not exceed 256 bytes.".to_string());
    }
    Ok((
        "daemon.question.answer",
        serde_json::json!({
            "questionID": question_id,
            "answeredBy": "linux-shell",
            "answer": answer,
            "selectedOptionID": selected_option_id,
            "markFollowupDone": true,
            "metadata": {
                "source": "linux-shell",
                "surface": "missions"
            }
        }),
    ))
}

// ───────────────── P06: mission create ─────────────────
// Wire: daemon.mission.create (BurnBarRPCMethod.missionCreate)
// BurnBarMissionCreateRequest requires projectSlug, title, summary,
// createdBy, recommendation, and metadata.
#[tauri::command]
fn mission_create(
    project_slug: String,
    title: String,
    summary: String,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.mission.create",
        Some(serde_json::json!({
            "projectSlug": project_slug,
            "title": title,
            "summary": summary,
            "createdBy": "linux-shell",
            "recommendation": "review",
            "metadata": {
                "source": "linux-shell",
                "surface": "missions"
            }
        })),
    )
}

// ───────────────── P06: mission approval decision ─────────────────
// Wire: daemon.mission.approve / daemon.mission.cancel
// (BurnBarRPCMethod.missionApprove / .missionCancel)
// BurnBarMissionApproveRequest/CancelRequest require `missionID` (capital ID —
// matches the Swift property name verbatim, no CodingKeys remap) and a
// non-optional `actor: String`. Missing either → Swift Codable decode throws.
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum MissionApprovalDecision { Approve, Deny }

impl MissionApprovalDecision {
    fn parse(decision: &str) -> Result<Self, String> {
        match decision {
            "approve" => Ok(Self::Approve),
            "deny" => Ok(Self::Deny),
            _ => Err("Mission approval decision must be exactly 'approve' or 'deny'.".to_string()),
        }
    }
}

fn mission_decision_wire(id: &str, decision: MissionApprovalDecision) -> (&'static str, serde_json::Value) {
    let method = match decision {
        MissionApprovalDecision::Approve => "daemon.mission.approve",
        MissionApprovalDecision::Deny => "daemon.mission.cancel",
    };
    (
        method,
        serde_json::json!({"missionID": id, "actor": "linux-shell"}),
    )
}

// Wire truth (Swift daemon): `daemon.mission.list` encodes
// `BurnBarMissionListResponse { missions: [BurnBarMissionSnapshot] }` — there are
// NO top-level `pendingApprovals`/`approvals`/`questions` arrays. Approval state
// lives per mission: `id` (BurnBarMissionID encodes as a bare string), `status`
// (BurnBarMissionStatus raw value, `"awaiting_approval"` when decidable) and
// `approval: BurnBarMissionApprovalSnapshot { approved, approvedAt, approvedBy,
// note }`. The daemon's JSONEncoder uses default keys, so property names arrive
// verbatim camelCase.
fn mission_pending_approval<'a>(mission_list: &'a serde_json::Value, mission_id: &str) -> Option<&'a serde_json::Value> {
    let pending_mission = mission_list.get("missions").and_then(|value| value.as_array())
        .and_then(|missions| missions.iter().find(|mission| {
            mission.get("id").and_then(|value| value.as_str()) == Some(mission_id)
                && mission.get("status").and_then(|value| value.as_str()) == Some("awaiting_approval")
                && mission.get("approval").and_then(|approval| approval.get("approved"))
                    .and_then(|value| value.as_bool()) != Some(true)
        }));
    // Fallback for flat approval feeds (shell fixtures / future daemon payloads):
    // top-level pendingApprovals/approvals/questions entries keyed by missionId.
    pending_mission.or_else(|| {
        mission_list.get("pendingApprovals").or_else(|| mission_list.get("approvals"))
            .or_else(|| mission_list.get("questions")).and_then(|value| value.as_array())
            .and_then(|approvals| approvals.iter().find(|approval| {
                approval.get("missionId").or_else(|| approval.get("mission_id"))
                    .and_then(|value| value.as_str()) == Some(mission_id)
            }))
    })
}

fn mission_approval_is_high_risk(approval: &serde_json::Value) -> bool {
    // Mission snapshots carry risk in `metadata` (the daemon's enterprise policy
    // key, see BurnBarEnterprisePolicyMetadataKey.defaultPacketRiskLevel); flat
    // approval entries carry `risk`/`severity` directly. Treat "high" anywhere as
    // high risk.
    let metadata = approval.get("metadata");
    [
        approval.get("risk"),
        approval.get("severity"),
        metadata.and_then(|m| m.get("enterprise_default_packet_risk_level")),
        metadata.and_then(|m| m.get("risk")),
        metadata.and_then(|m| m.get("severity")),
    ]
    .into_iter()
    .flatten()
    .filter_map(|value| value.as_str())
    .any(|risk| risk.to_ascii_lowercase().contains("high"))
}

#[tauri::command]
fn mission_approval_decision(id: String, decision: String) -> Result<serde_json::Value, String> {
    let id = id.trim();
    if id.is_empty() { return Err("Mission id is required for approval decisions.".to_string()); }
    let decision = MissionApprovalDecision::parse(&decision)?;
    let mission_list = mission_list()?;
    let approval = mission_pending_approval(&mission_list, id).ok_or_else(||
        "Mission approval decision rejected: no matching pending approval.".to_string())?;
    if decision == MissionApprovalDecision::Approve && mission_approval_is_high_risk(approval) {
        return Err("High-risk mission approval requires trusted-device step-up and cannot be approved from the Linux shell.".to_string());
    }
    let (method, params) = mission_decision_wire(id, decision);
    call_daemon_method(method, Some(params))
}

// ───────────────── P20: explicit mission cancellation ─────────────────
// Wire: daemon.mission.cancel (BurnBarMissionCancelRequest)
#[tauri::command]
fn mission_cancel(mission_id: String, note: Option<String>) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.mission.cancel",
        Some(serde_json::json!({
            "missionID": mission_id,
            "actor": "linux-shell",
            "note": note
        })),
    )
}

// ───────────────── P07: config snapshot ─────────────────
// Wire: daemon.config.get (BurnBarRPCMethod.configGet)
#[tauri::command]
fn config_snapshot() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.config.get", None)
}

#[tauri::command]
fn onboarding_snapshot() -> Result<serde_json::Value, String> {
    call_daemon_method(DAEMON_ONBOARDING_SNAPSHOT_METHOD, None)
}

#[tauri::command]
fn onboarding_action(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method(DAEMON_ONBOARDING_ACTION_METHOD, Some(request))
}

#[tauri::command]
fn onboarding_reset() -> Result<serde_json::Value, String> {
    call_daemon_method(DAEMON_ONBOARDING_RESET_METHOD, None)
}

#[tauri::command]
fn subscription_start(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method(DAEMON_SUBSCRIPTION_START_METHOD, Some(request))
}

#[tauri::command]
fn subscription_resume(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method(DAEMON_SUBSCRIPTION_RESUME_METHOD, Some(request))
}

#[tauri::command]
fn subscription_stop(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method(DAEMON_SUBSCRIPTION_STOP_METHOD, Some(request))
}

#[tauri::command]
fn config_update(snapshot: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.config.update",
        Some(serde_json::json!({ "snapshot": snapshot })),
    )
}

#[tauri::command]
fn provider_credential_slot_upsert(params: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.provider.credential_slot.upsert", Some(params))
}

#[tauri::command]
fn provider_credential_slot_remove(
    provider_id: String,
    slot_id: String,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.provider.credential_slot.remove",
        Some(serde_json::json!({ "providerID": provider_id, "slotID": slot_id })),
    )
}

#[tauri::command]
fn provider_model_variant_upsert(
    provider_id: String,
    variant: serde_json::Value,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.provider.model_variant.upsert",
        Some(serde_json::json!({ "providerID": provider_id, "variant": variant })),
    )
}

#[tauri::command]
fn provider_model_variant_remove(
    provider_id: String,
    variant_id: String,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.provider.model_variant.remove",
        Some(serde_json::json!({ "providerID": provider_id, "variantID": variant_id })),
    )
}

#[tauri::command]
fn provider_model_alias_upsert(
    provider_id: String,
    alias: serde_json::Value,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.provider.model_alias.upsert",
        Some(serde_json::json!({ "providerID": provider_id, "alias": alias })),
    )
}

#[tauri::command]
fn provider_model_alias_remove(
    provider_id: String,
    alias_id: String,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.provider.model_alias.remove",
        Some(serde_json::json!({ "providerID": provider_id, "aliasID": alias_id })),
    )
}

#[tauri::command]
fn provider_custom_model_upsert(
    provider_id: String,
    custom_model: serde_json::Value,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.provider.custom_model.upsert",
        Some(serde_json::json!({ "providerID": provider_id, "customModel": custom_model })),
    )
}

#[tauri::command]
fn provider_custom_model_remove(
    provider_id: String,
    model_id: String,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.provider.custom_model.remove",
        Some(serde_json::json!({ "providerID": provider_id, "modelID": model_id })),
    )
}

#[tauri::command]
fn provider_model_display_name_set(
    provider_id: String,
    model_id: String,
    display_name: String,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.provider.model_display_name.set",
        Some(
            serde_json::json!({ "providerID": provider_id, "modelID": model_id, "displayName": display_name }),
        ),
    )
}

#[tauri::command]
fn provider_model_display_name_clear(
    provider_id: String,
    model_id: String,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.provider.model_display_name.clear",
        Some(serde_json::json!({ "providerID": provider_id, "modelID": model_id })),
    )
}

#[tauri::command]
fn proxy_route_log_recent(limit: i32) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.proxy.route_log.recent",
        Some(serde_json::json!({ "limit": limit })),
    )
}

#[tauri::command]
fn proxy_route_log_clear() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.proxy.route_log.clear", Some(serde_json::json!({})))
}

#[tauri::command]
fn linux_privacy_inventory() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.privacy.inventory", None)
}

#[tauri::command]
fn linux_privacy_deletion_preview(stores: Vec<String>) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.privacy.deletion.preview",
        Some(serde_json::json!({ "stores": stores })),
    )
}

#[tauri::command]
fn linux_privacy_deletion_execute(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.privacy.deletion.execute", Some(request))
}

#[tauri::command]
fn linux_privacy_export(request: serde_json::Value) -> Result<serde_json::Value, String> {
    let object = request
        .as_object()
        .ok_or_else(|| "privacy export request must be an object".to_string())?;
    let stores = object
        .get("stores")
        .and_then(|value| value.as_array())
        .ok_or_else(|| "privacy export stores are required".to_string())?;
    if stores.is_empty() || stores.len() > 2 {
        return Err("privacy export must select one or two supported stores".to_string());
    }
    let destination_path = object
        .get("destinationPath")
        .and_then(|value| value.as_str())
        .ok_or_else(|| "privacy export destinationPath is required".to_string())?;
    let passphrase = object
        .get("passphrase")
        .and_then(|value| value.as_str())
        .ok_or_else(|| "privacy export passphrase is required".to_string())?;
    if destination_path.trim().is_empty()
        || destination_path.len() > 4096
        || !destination_path.starts_with('/')
        || destination_path
            .chars()
            .any(|character| character == '\0' || character == '\n' || character == '\r')
    {
        return Err("privacy export destinationPath is invalid".to_string());
    }
    if passphrase.len() < 8 || passphrase.len() > 4096 || passphrase.contains('\0') {
        return Err("privacy export passphrase must be between 8 and 4096 bytes".to_string());
    }
    call_daemon_method("daemon.privacy.export", Some(request))
}

#[tauri::command]
fn linux_privacy_retention_status() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.privacy.retention.status", None)
}

#[tauri::command]
fn linux_privacy_retention_apply(request: serde_json::Value) -> Result<serde_json::Value, String> {
    let object = request
        .as_object()
        .ok_or_else(|| "privacy retention request must be an object".to_string())?;
    let rules = object
        .get("rules")
        .and_then(|value| value.as_array())
        .ok_or_else(|| "privacy retention rules are required".to_string())?;
    if rules.len() != 2 {
        return Err("privacy retention must cover both supported stores".to_string());
    }
    let confirmation = object
        .get("confirmation")
        .and_then(|value| value.as_str())
        .ok_or_else(|| "privacy retention confirmation is required".to_string())?;
    if confirmation != "APPLY RETENTION POLICY" {
        return Err("privacy retention confirmation is invalid".to_string());
    }
    let mut stores = std::collections::HashSet::new();
    for rule in rules {
        let rule = rule
            .as_object()
            .ok_or_else(|| "privacy retention rule must be an object".to_string())?;
        let store = rule
            .get("store")
            .and_then(|value| value.as_str())
            .ok_or_else(|| "privacy retention rule store is required".to_string())?;
        if !matches!(store, "proxy_route_log" | "text_expansion_store") || !stores.insert(store) {
            return Err("privacy retention rules must cover each supported store once".to_string());
        }
        let max_age_seconds = rule
            .get("maxAgeSeconds")
            .and_then(|value| value.as_i64())
            .ok_or_else(|| "privacy retention maxAgeSeconds is required".to_string())?;
        let max_bytes = rule
            .get("maxBytes")
            .and_then(|value| value.as_i64())
            .ok_or_else(|| "privacy retention maxBytes is required".to_string())?;
        if !(3_600..=31_536_000).contains(&max_age_seconds)
            || !(65_536..=67_108_864).contains(&max_bytes)
        {
            return Err("privacy retention rule is outside safe bounds".to_string());
        }
    }
    call_daemon_method("daemon.privacy.retention.apply", Some(request))
}

#[tauri::command]
fn notification_config_get() -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.notification.config.get",
        Some(serde_json::json!({})),
    )
}

#[tauri::command]
fn notification_config_update(config: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.notification.config.update",
        Some(serde_json::json!({ "config": config })),
    )
}

#[tauri::command]
fn notification_health() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.notification.health", Some(serde_json::json!({})))
}

#[tauri::command]
fn notification_command(
    command: String,
    arguments: Vec<String>,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.notification.command",
        Some(
            serde_json::json!({ "command": command, "arguments": arguments, "actor": "linux-shell" }),
        ),
    )
}

// ───────────────── P07: db status ─────────────────
// Derived from daemon.config.get — no dedicated db RPC exists in the enum.
#[tauri::command]
fn db_status() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.config.get", None)
}

// ───────────────── P07: project list ─────────────────
// Wire: daemon.controller.project.list (BurnBarRPCMethod.controllerProjectsList)
#[tauri::command]
fn project_list() -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.controller.project.list",
        Some(serde_json::json!({
            "includePaused": true,
            "limit": 200
        })),
    )
}

// ───────────────── P19: project lifecycle ─────────────────
// Wire: daemon.controller.project.get / daemon.controller.project.upsert /
// daemon.controller.project.delete / daemon.controller.project.reassign.
// (BurnBarRPCMethod.controllerProjectGet / controllerProjectUpsert /
// controllerProjectDelete / controllerProjectReassign).
fn validate_project_identifier(value: &str, field: &str) -> Result<String, String> {
    let value = value.trim();
    if value.is_empty() || value.len() > 160 || value != value.trim() {
        return Err(format!("{field} must be a canonical non-empty identifier"));
    }
    if !value.is_ascii()
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
    {
        return Err(format!(
            "{field} must contain only ASCII letters, digits, '-', '_', '.', or ':'"
        ));
    }
    Ok(value.to_owned())
}

fn validate_project_slug(value: &str, field: &str) -> Result<String, String> {
    let slug = validate_project_identifier(value, field)?;
    if slug.len() > 96
        || slug != slug.to_ascii_lowercase()
        || !slug
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphanumeric)
        || !slug
            .as_bytes()
            .last()
            .is_some_and(u8::is_ascii_alphanumeric)
    {
        return Err(format!(
            "{field} must be a lowercase canonical project slug"
        ));
    }
    Ok(slug)
}

#[tauri::command]
fn project_get(project_slug: String) -> Result<serde_json::Value, String> {
    let project_slug = validate_project_slug(&project_slug, "projectSlug")?;
    call_daemon_method(
        "daemon.controller.project.get",
        Some(serde_json::json!({ "projectSlug": project_slug })),
    )
}

fn validate_project_upsert_payload(project: &serde_json::Value) -> Result<(), String> {
    let object = project
        .as_object()
        .ok_or_else(|| "project must be a JSON object".to_string())?;
    for field in ["projectSlug", "displayName", "summary", "id"] {
        let value = object
            .get(field)
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty());
        if value.is_none() {
            return Err(format!("project.{field} must be a non-empty string"));
        }
    }
    let project_slug = object
        .get("projectSlug")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "project.projectSlug must be a non-empty string".to_string())?;
    validate_project_slug(project_slug, "project.projectSlug")?;
    let project_id = object
        .get("id")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "project.id must be a non-empty string".to_string())?;
    validate_project_identifier(project_id, "project.id")?;
    Ok(())
}

#[tauri::command]
fn project_upsert(project: serde_json::Value) -> Result<serde_json::Value, String> {
    validate_project_upsert_payload(&project)?;
    call_daemon_method(
        "daemon.controller.project.upsert",
        Some(serde_json::json!({ "project": project })),
    )
}

#[tauri::command]
fn project_delete(project_slug: String) -> Result<serde_json::Value, String> {
    let project_slug = validate_project_slug(&project_slug, "projectSlug")?;
    call_daemon_method(
        "daemon.controller.project.delete",
        Some(serde_json::json!({ "projectSlug": project_slug })),
    )
}

#[tauri::command]
fn project_reassign(
    source_project_slug: String,
    target_project_slug: String,
) -> Result<serde_json::Value, String> {
    let source_project_slug = validate_project_slug(&source_project_slug, "sourceProjectSlug")?;
    let target_project_slug = validate_project_slug(&target_project_slug, "targetProjectSlug")?;
    if source_project_slug == target_project_slug {
        return Err("sourceProjectSlug and targetProjectSlug must differ".to_string());
    }
    call_daemon_method(
        "daemon.controller.project.reassign",
        Some(serde_json::json!({
            "sourceProjectSlug": source_project_slug,
            "targetProjectSlug": target_project_slug
        })),
    )
}

/// Returns the daemon-owned recent controller events for one canonical project.
/// The summary RPC is the existing authoritative history surface; this wrapper
/// only scopes it and deliberately omits the larger projection-status payload.
#[tauri::command]
fn project_history(project_slug: String) -> Result<serde_json::Value, String> {
    let project_slug = validate_project_slug(&project_slug, "projectSlug")?;
    call_daemon_method(
        "daemon.controller.summary",
        Some(serde_json::json!({
            "projectSlug": project_slug,
            "includeRecentEvents": true,
            "includeProjectionStatus": false
        })),
    )
}

// ───────────────── P07: memory boundaries ─────────────────
// Wire: daemon.memory.analytics (BurnBarRPCMethod.memoryAnalytics)
#[tauri::command]
fn memory_boundaries() -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.memory.analytics",
        Some(serde_json::json!({"projectPath": null})),
    )
}

// ───────────────── P07: memory review inbox ─────────────────
// Wire: daemon.memory.recall + daemon.memory.audit_trail.
// The review feed opts into the daemon-owned quarantine lifecycle explicitly;
// normal memory recall remains approved-only in the daemon.
#[tauri::command]
fn memory_review_inbox() -> serde_json::Value {
    let recall = call_daemon_method_report(
        "daemon.memory.recall",
        Some(serde_json::json!({
            "query": "project memory",
            "projectPath": null,
            "limit": 50,
            "scope": "all",
            "includeCrossProject": true,
            "includeQuarantined": true,
            "includeForgotten": true
        })),
    );
    let audit = call_daemon_method_report(
        "daemon.memory.audit_trail",
        Some(serde_json::json!({
            "projectPath": null,
            "limit": 50
        })),
    );
    serde_json::json!({
        "recall": recall,
        "auditTrail": audit
    })
}

// ───────────────── P07: memory forget / revoke ─────────────────
// Wire: daemon.memory.forget (BurnBarRPCMethod.memoryForget)
#[tauri::command]
fn memory_forget(memory_id: String) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.memory.forget",
        Some(serde_json::json!({
            "memoryID": memory_id,
            "projectPath": null,
            "requireCloudDelete": false
        })),
    )
}

// ───────────────── P07: database workspace status ─────────────────
// Wire: daemon.code.index_status / explore / diagnostics / ops_diagnostics.
#[tauri::command]
fn database_workspace_status(project_path: Option<String>) -> serde_json::Value {
    let status = call_daemon_method_report(
        "daemon.code.index_status",
        Some(serde_json::json!({"projectPath": project_path.clone()})),
    );
    let explore = call_daemon_method_report(
        "daemon.code.explore",
        Some(serde_json::json!({
            "projectPath": project_path.clone(),
            "query": null,
            "limit": 50,
            "maxBytes": 24000
        })),
    );
    let diagnostics = call_daemon_method_report(
        "daemon.code.diagnostics",
        Some(serde_json::json!({
            "projectPath": project_path.clone(),
            "filePath": null
        })),
    );
    let ops = call_daemon_method_report("daemon.code.ops_diagnostics", Some(serde_json::json!({})));
    serde_json::json!({
        "indexStatus": status,
        "explore": explore,
        "diagnostics": diagnostics,
        "opsDiagnostics": ops
    })
}

// ───────────────── P07: database indexing controls ─────────────────
// Wire: daemon.code.index_project (BurnBarRPCMethod.codeIndexProject)
#[tauri::command]
fn database_index_project(project_path: Option<String>) -> Result<serde_json::Value, String> {
    call_daemon_method_with_timeout(
        "daemon.code.index_project",
        Some(serde_json::json!({
            "projectPath": project_path,
            "maxFiles": 2500,
            "maxFileBytes": 512000,
            "storageBudgetBytes": null
        })),
        Duration::from_secs(120),
    )
}

// Wire: daemon.code.watch_project (BurnBarRPCMethod.codeWatchProject).
// Linux watcher is poll-only; Darwin FSEvents nudges are not available here.
#[tauri::command]
fn database_watch_project(project_path: Option<String>) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.code.watch_project",
        Some(serde_json::json!({
            "projectPath": project_path,
            "maxFiles": 2500,
            "maxFileBytes": 512000,
            "storageBudgetBytes": null,
            "pollIntervalSeconds": 2.0
        })),
    )
}

fn bounded_database_snapshot_bytes(max_bytes: Option<u64>) -> Result<u64, String> {
    const MAX: u64 = 512 * 1024 * 1024;
    match max_bytes {
        Some(value) if value > 0 && value <= MAX => Ok(value),
        Some(_) => Err("database snapshot byte limit must be between 1 and 536870912".to_string()),
        None => Ok(MAX),
    }
}

#[tauri::command]
fn database_snapshot(
    destination_path: String,
    max_bytes: Option<u64>,
) -> Result<serde_json::Value, String> {
    let limit = bounded_database_snapshot_bytes(max_bytes)?;
    call_daemon_method_with_timeout(
        "daemon.code.database_snapshot",
        Some(serde_json::json!({
            "destinationPath": destination_path,
            "maxBytes": limit
        })),
        Duration::from_secs(120),
    )
}

#[tauri::command]
fn database_restore(
    snapshot_path: String,
    max_bytes: Option<u64>,
) -> Result<serde_json::Value, String> {
    let limit = bounded_database_snapshot_bytes(max_bytes)?;
    call_daemon_method_with_timeout(
        "daemon.code.database_restore",
        Some(serde_json::json!({
            "snapshotPath": snapshot_path,
            "maxBytes": limit
        })),
        Duration::from_secs(120),
    )
}

// ───────────────── P22: bounded code retrieval ─────────────────
// Wire: daemon.code.search / daemon.code.context_pack.
// Keep the shell read-only and bounded; index ownership and trust wrapping
// remain in OpenBurnBarDaemon.
fn bounded_code_query(query: String) -> Result<String, String> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return Err("Code search query must not be empty.".to_string());
    }
    Ok(trimmed.chars().take(512).collect())
}

fn bounded_code_limit(limit: Option<u32>, default: u32) -> u32 {
    limit.unwrap_or(default).clamp(1, 50)
}

fn bounded_context_bytes(max_bytes: Option<u32>) -> u32 {
    max_bytes.unwrap_or(24_000).clamp(1_024, 24_000)
}

#[tauri::command]
fn database_code_search(
    query: String,
    project_path: Option<String>,
    limit: Option<u32>,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.code.search",
        Some(serde_json::json!({
            "query": bounded_code_query(query)?,
            "projectPath": project_path,
            "limit": bounded_code_limit(limit, 20)
        })),
    )
}

#[tauri::command]
fn database_code_context_pack(
    query: String,
    project_path: Option<String>,
    limit: Option<u32>,
    max_bytes: Option<u32>,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.code.context_pack",
        Some(serde_json::json!({
            "query": bounded_code_query(query)?,
            "projectPath": project_path,
            "limit": bounded_code_limit(limit, 10),
            "maxBytes": bounded_context_bytes(max_bytes)
        })),
    )
}

fn bounded_recovery_path(path: String) -> Result<String, String> {
    let trimmed = path.trim();
    if trimmed.is_empty() || trimmed.len() > 4096 || !trimmed.starts_with('/') {
        return Err(
            "Recovery bundle path must be an absolute local path under 4096 bytes.".to_string(),
        );
    }
    if trimmed
        .chars()
        .any(|character| character == '\0' || character == '\n' || character == '\r')
    {
        return Err("Recovery bundle path contains a prohibited control character.".to_string());
    }
    Ok(trimmed.to_string())
}

fn bounded_recovery_passphrase(passphrase: String) -> Result<String, String> {
    if passphrase.trim().is_empty() || passphrase.len() > 4096 {
        return Err("Recovery bundle passphrase must be between 1 and 4096 bytes.".to_string());
    }
    if passphrase.contains('\0') {
        return Err("Recovery bundle passphrase contains a prohibited NUL character.".to_string());
    }
    // Preserve intentional leading/trailing spaces: they are part of the
    // macOS passphrase input and therefore part of the PBKDF2 password.
    Ok(passphrase)
}

/// Read the daemon-owned recovery posture without exposing key material or
/// implying success from custody alone.
#[tauri::command]
fn database_recovery_bundle_status() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.database.recovery.status", None)
}

#[tauri::command]
fn database_recovery_bundle_export(
    destination_path: String,
    passphrase: String,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.database.recovery_bundle.export",
        Some(serde_json::json!({
            "destinationPath": bounded_recovery_path(destination_path)?,
            "passphrase": bounded_recovery_passphrase(passphrase)?
        })),
    )
}

#[tauri::command]
fn database_recovery_bundle_import(
    source_path: String,
    passphrase: String,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.database.recovery_bundle.import",
        Some(serde_json::json!({
            "sourcePath": bounded_recovery_path(source_path)?,
            "passphrase": bounded_recovery_passphrase(passphrase)?
        })),
    )
}

// ───────────────── P08: daemon-owned account authority ─────────────────
#[tauri::command]
fn account_status() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.auth.status", None)
}

fn bounded_trusted_device_id(device_id: String) -> Result<String, String> {
    let value = device_id.trim().to_string();
    if value.is_empty()
        || value.len() > 160
        || value.chars().any(|character| character.is_control())
        || !value
            .chars()
            .all(|character| character.is_alphanumeric() || "._:+-/=".contains(character))
    {
        return Err("trusted_device_id_invalid".to_string());
    }
    Ok(value)
}

#[tauri::command]
fn trusted_device_list() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.account.trusted_devices.list", None)
}

#[tauri::command]
fn trusted_device_approve(device_id: String) -> Result<serde_json::Value, String> {
    let device_id = bounded_trusted_device_id(device_id)?;
    call_daemon_method(
        "daemon.account.trusted_device.approve",
        Some(serde_json::json!({ "deviceID": device_id })),
    )
}

#[tauri::command]
fn trusted_device_revoke(device_id: String) -> Result<serde_json::Value, String> {
    let device_id = bounded_trusted_device_id(device_id)?;
    call_daemon_method(
        "daemon.account.trusted_device.revoke",
        Some(serde_json::json!({ "deviceID": device_id })),
    )
}

/// Daemon-owned cloud account erasure. The shell forwards only the exact
/// confirmation phrase; the daemon owns trusted-device approval and all cloud
/// credentials. Error text is intentionally returned only from the daemon's
/// redacted RPC mapping.
#[tauri::command]
fn account_delete_cloud_data(confirmation: String) -> Result<serde_json::Value, String> {
    let confirmation = confirmation.trim();
    if confirmation != "DELETE MY ACCOUNT" {
        return Err("account_erasure_confirmation_invalid".to_string());
    }
    call_daemon_method(
        "daemon.account.cloud_data.delete",
        Some(serde_json::json!({ "confirmation": confirmation })),
    )
    .map_err(|error| match error.as_str() {
        "Account erasure confirmation is invalid."
        | "An account erasure request is already in progress."
        | "Account erasure needs a connected trusted-device approval bridge."
        | "Account erasure is unavailable until Linux cloud authentication is configured."
        | "Sign in again before deleting cloud data."
        | "Unlock Linux secure credential storage, then retry account erasure."
        | "Trusted-device authorization was not approved; retry from an approved device."
        | "Account erasure did not complete; retry." => error,
        _ => "account_erasure_rpc_unavailable".to_string(),
    })
}

/// Daemon-owned cloud account export. The shell forwards only an optional
/// domain selection and a local destination; trusted-device approval and
/// cloud credentials remain daemon-owned.
fn validate_account_export_request(request: &serde_json::Value) -> Result<(), String> {
    let object = request
        .as_object()
        .ok_or_else(|| "account export request must be an object".to_string())?;
    let destination_path = object
        .get("destinationPath")
        .and_then(|value| value.as_str())
        .ok_or_else(|| "account export destinationPath is required".to_string())?;
    if destination_path.trim() != destination_path
        || destination_path.is_empty()
        || destination_path.len() > 4096
        || !destination_path.starts_with('/')
        || destination_path
            .chars()
            .any(|character| character == '\0' || character == '\n' || character == '\r')
    {
        return Err("account export destinationPath is invalid".to_string());
    }
    let domains = object.get("domains").cloned().unwrap_or(serde_json::Value::Null);
    if !domains.is_null() {
        let values = domains
            .as_array()
            .ok_or_else(|| "account export domains must be an array".to_string())?;
        if values.len() > 24 || values.iter().any(|value| {
            value.as_str().map(|domain| {
                domain.is_empty()
                    || domain.len() > 64
                    || domain.trim() != domain
                    || domain.chars().any(|character| character == '\0' || character == '\n' || character == '\r')
            }).unwrap_or(true)
        }) {
            return Err("account export domains are invalid".to_string());
        }
    }
    Ok(())
}

#[tauri::command]
fn account_export_cloud_data(request: serde_json::Value) -> Result<serde_json::Value, String> {
    validate_account_export_request(&request)?;
    call_daemon_method(
        "daemon.account.cloud_data.export",
        Some(request),
    )
    .map_err(|error| match error.as_str() {
        "Account export needs a connected trusted-device approval bridge."
        | "Account export is unavailable until Linux cloud authentication is configured."
        | "Sign in again before exporting cloud data."
        | "Unlock Linux secure credential storage, then retry account export."
        | "Trusted-device authorization was not approved; retry from an approved device."
        | "Account export did not complete; retry."
        | "An account export request is already in progress."
        | "Account export destination is unsafe."
        | "Account export exceeded the daemon size limit."
        | "Account export could not be written; retry." => error,
        _ => "account_export_rpc_unavailable".to_string(),
    })
}
