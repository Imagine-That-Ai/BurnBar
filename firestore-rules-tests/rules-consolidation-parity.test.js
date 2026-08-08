import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  setDoc,
  updateDoc,
  writeBatch,
} from "firebase/firestore";

const PROJECT_ID = process.env.FIRESTORE_TEST_PROJECT_ID || "burnbar-test";
const RULES_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "..", "firestore.rules");
const FIRESTORE_HOST = process.env.FIRESTORE_TEST_HOST || "127.0.0.1";
const FIRESTORE_PORT = Number.parseInt(process.env.FIRESTORE_TEST_PORT || "8080", 10);

const aliceUid = "alice-rules-consolidation";
const bobUid = "bob-rules-consolidation";

// Every direct user child collection that had an exact owner-read allow before
// the compiler-budget consolidation. Keeping the full set here makes an omitted
// collection a visible emulator failure instead of a mobile sync regression.
const OWNER_READABLE_COLLECTIONS = [
  "usage", "budgetRules", "budgetEvents", "conversations",
  "chat_threads", "text_snippets", "mobile_assistant_chats",
  "cli_sessions", "cli_agent_mission_requests", "agent_import_jobs",
  "ai_inbox_items", "ai_inbox_item_state",
  "mission_groups", "approval_policies", "rollback_requests",
  "agent_identities", "subscription_topics", "session_logs",
  "project_memory_snapshots", "cloud_search_documents",
  "cloud_search_chunks", "cloud_search_postings", "cloud_search_index_state",
  "cloud_search_index_manifest", "cloud_search_knowledge", "memory_facts",
  "memory_forget_receipts", "knowledge_sync_manifests", "knowledge_repos",
  "unified_audit_log", "audit_meta", "account_recovery_methods",
  "cloud_vault_state", "cloud_vault_key_wrappers", "cloud_vault_rotation_jobs",
  "cloud_vault_rotation_requirements", "devices", "agent_notification_events",
  "agent_notification_replies", "quota_snapshots", "provider_connections",
  "provider_accounts", "roaming_profile", "provider_account_device_links",
  "runtime_connection_preferences", "hermes_connections", "hermes_pairings",
  "hermes_relay_requests", "hermes_session_cache", "hermes_audit_events",
  "hermes_gateway_clients", "hermes_gateway_destinations",
  "hermes_gateway_events", "hermes_gateway_messages", "hermes_gateway_typing",
  "hermes_gateway_attachments", "hermes_gateway_state",
  "hermes_gateway_approvals", "iroh_pairing_keys", "iroh_pairing",
  "iroh_audit_events", "incoming_call_contexts", "media_session_events",
  "relay_sender_keys", "agent_grant_authorities",
  "agent_capability_grant_requests", "computer_use_sessions",
  "computer_use_actions", "computer_use_quota_usage", "media_quota_usage",
  "media_attachment_manifests", "pi_agent_connections", "pi_agent_pairings",
  "pi_agent_relay_requests", "pi_agent_audit_events", "smart_hub_config",
  "smart_display_actions", "cast_actions", "cast_discovery_results",
  "usage_rollups", "projects", "remote_mcp_clients",
  "remote_mcp_audit_events", "entitlements", "entitlement_events",
  "escrow_devices", "escrow_public_keys", "signal_identity_public_keys",
  "escrow_envelopes", "escrow_audit_events", "cloud_profile",
  "sync_watermarks", "sync_status", "cloud_settings", "recent_usage",
];

const SERVER_WRITTEN_COLLECTIONS = [
  "cloud_search_index_manifest", "cloud_search_knowledge",
  "knowledge_sync_manifests", "knowledge_repos", "unified_audit_log",
  "audit_meta", "account_recovery_methods", "cloud_vault_rotation_requirements",
  "agent_notification_events", "provider_account_device_links",
  "hermes_pairings", "hermes_session_cache", "hermes_audit_events",
  "hermes_gateway_clients", "hermes_gateway_destinations",
  "hermes_gateway_events", "hermes_gateway_messages", "hermes_gateway_typing",
  "hermes_gateway_attachments", "hermes_gateway_state",
  "hermes_gateway_approvals", "iroh_pairing_keys", "iroh_pairing",
  "incoming_call_contexts", "relay_sender_keys", "agent_grant_authorities",
  "computer_use_quota_usage", "media_quota_usage", "pi_agent_pairings",
  "pi_agent_audit_events", "usage_rollups", "projects", "remote_mcp_clients",
  "remote_mcp_audit_events", "entitlements", "entitlement_events",
];

const BASIC_OWNER_WRITABLE_COLLECTIONS = [
  "devices",
  "quota_snapshots",
  "provider_connections",
];

const ESCROW_OWNER_WRITABLE_COLLECTIONS = [
  "cloud_profile",
  "sync_watermarks",
  "sync_status",
  "cloud_settings",
  "recent_usage",
];

const testEnv = await initializeTestEnvironment({
  projectId: PROJECT_ID,
  firestore: {
    rules: readFileSync(RULES_PATH, "utf8"),
    host: FIRESTORE_HOST,
    port: FIRESTORE_PORT,
  },
});

try {
  await testEnv.clearFirestore();
  const alice = testEnv.authenticatedContext(aliceUid).firestore();
  const bob = testEnv.authenticatedContext(bobUid).firestore();

  await testEnv.withSecurityRulesDisabled(async (context) => {
    const admin = context.firestore();
    const batch = writeBatch(admin);
    for (const collectionId of OWNER_READABLE_COLLECTIONS) {
      batch.set(doc(admin, `users/${aliceUid}/${collectionId}/probe`), {
        collectionId,
      });
    }
    batch.set(doc(admin, `users/${aliceUid}/not_allowlisted/probe`), {
      collectionId: "not_allowlisted",
    });
    await batch.commit();
  });

  for (const collectionId of OWNER_READABLE_COLLECTIONS) {
    const path = `users/${aliceUid}/${collectionId}/probe`;
    await assertSucceeds(getDoc(doc(alice, path)));
    await assertFails(getDoc(doc(bob, path)));
  }

  // Android listens to the complete entitlement collection so it can resolve
  // Cloud, Pro, and Ultra atomically. Prove the owner-scoped list/query rule,
  // not only individual document reads.
  await assertSucceeds(
    getDocs(collection(alice, `users/${aliceUid}/entitlements`)),
  );
  await assertFails(
    getDocs(collection(bob, `users/${aliceUid}/entitlements`)),
  );

  await assertFails(getDoc(doc(alice, `users/${aliceUid}/not_allowlisted/probe`)));
  await assertFails(
    setDoc(doc(alice, `users/${aliceUid}/not_allowlisted/new`), { safe: true }),
  );

  for (const collectionId of SERVER_WRITTEN_COLLECTIONS) {
    await assertFails(
      setDoc(doc(alice, `users/${aliceUid}/${collectionId}/client-write`), {
        safe: true,
      }),
    );
  }

  for (const collectionId of BASIC_OWNER_WRITABLE_COLLECTIONS) {
    const ref = doc(alice, `users/${aliceUid}/${collectionId}/owner-write`);
    await assertSucceeds(setDoc(ref, { safe: true }));
    await assertSucceeds(updateDoc(ref, { updated: true }));
    await assertFails(setDoc(ref, { apiKey: "plaintext-secret" }));
    await assertSucceeds(deleteDoc(ref));
  }

  for (const collectionId of ESCROW_OWNER_WRITABLE_COLLECTIONS) {
    const ref = doc(alice, `users/${aliceUid}/${collectionId}/owner-write`);
    await assertSucceeds(setDoc(ref, { safe: true }));
    await assertSucceeds(updateDoc(ref, { updated: true }));
    await assertFails(setDoc(ref, { token: "plaintext-secret" }));
    await assertSucceeds(deleteDoc(ref));
  }

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `account_erasure_tombstones/${aliceUid}`), {
      pending: true,
      schemaVersion: 2,
    });
  });

  for (const collectionId of OWNER_READABLE_COLLECTIONS) {
    await assertFails(
      getDoc(doc(alice, `users/${aliceUid}/${collectionId}/probe`)),
    );
  }
  await assertFails(
    getDocs(collection(alice, `users/${aliceUid}/entitlements`)),
  );

  console.log(
    `rules consolidation parity passed for ${OWNER_READABLE_COLLECTIONS.length} owner-readable collections`,
  );
} finally {
  await testEnv.cleanup();
}
