import assert from "node:assert/strict";
import test from "node:test";

import {
  ALLOWED_CHANNEL_TYPES,
  VERIFIABLE_CHANNEL_TYPES,
  channelTarget,
  checkAlertPolicies,
  evaluateChannel,
  isPlaceholderTarget,
  notificationChannelStatus,
} from "./ops-alerts-gate.mjs";

const expectedPolicy = {
  displayName: "OpenBurnBar Callable error spike",
  requiredMetricTypes: ["logging.googleapis.com/user/openburnbar_callable_error"],
};

function fakeRunner({ policies, channels }) {
  return (_command, args) => {
    if (args[1] === "policies") {
      return { ok: true, status: 0, stdout: JSON.stringify(policies), stderr: "" };
    }
    if (args[1] === "channels") {
      return { ok: true, status: 0, stdout: JSON.stringify(channels), stderr: "" };
    }
    return { ok: false, status: 1, stdout: "", stderr: `unexpected gcloud args: ${args.join(" ")}` };
  };
}

function policyWithChannel(channelName) {
  return {
    displayName: expectedPolicy.displayName,
    enabled: true,
    notificationChannels: [channelName],
    conditions: [
      {
        conditionThreshold: {
          filter: `metric.type="${expectedPolicy.requiredMetricTypes[0]}"`,
        },
      },
    ],
  };
}

function status(overrides = {}) {
  return {
    name: "projects/burnbar/notificationChannels/1",
    present: true,
    enabled: true,
    type: "email",
    displayName: "Ops email",
    verificationStatus: "VERIFIED",
    target: "ops@burnbar.ai",
    ...overrides,
  };
}

test("channelTarget reads the type-specific label and trims it", () => {
  assert.equal(
    channelTarget({ type: "email", labels: { email_address: "  ops@burnbar.ai  " } }),
    "ops@burnbar.ai",
  );
  assert.equal(channelTarget({ type: "sms", labels: { number: "+15551234567" } }), "+15551234567");
  assert.equal(channelTarget({ type: "pubsub", labels: { topic: "projects/p/topics/t" } }), "projects/p/topics/t");
  assert.equal(channelTarget({ type: "email", labels: { email_address: "" } }), null);
  assert.equal(channelTarget({ type: "email", labels: {} }), null);
  assert.equal(channelTarget(null), null);
});

test("isPlaceholderTarget flags empty and known unresolvable/placeholder targets", () => {
  assert.equal(isPlaceholderTarget(null), true);
  assert.equal(isPlaceholderTarget(""), true);
  assert.equal(isPlaceholderTarget("ops@example.com"), true);
  assert.equal(isPlaceholderTarget("ops@example.org"), true);
  assert.equal(isPlaceholderTarget("alerts@nxdomain.invalid"), true);
  assert.equal(isPlaceholderTarget("root@localhost"), true);
  assert.equal(isPlaceholderTarget("changeme@burnbar.ai"), true);
  assert.equal(isPlaceholderTarget("ops@burnbar.ai"), false);
  assert.equal(isPlaceholderTarget("+15551234567"), false);
});

test("evaluateChannel passes a verified email channel with a real target", () => {
  assert.deepEqual(evaluateChannel(status()), { ok: true, reason: null });
});

test("evaluateChannel fails closed on an enabled but unverified email channel", () => {
  const result = evaluateChannel(status({ verificationStatus: "UNVERIFIED" }));
  assert.equal(result.ok, false);
  assert.equal(result.reason, "unverified:UNVERIFIED");
});

test("evaluateChannel fails closed when verificationStatus is missing or unspecified", () => {
  assert.equal(evaluateChannel(status({ verificationStatus: null })).ok, false);
  assert.equal(
    evaluateChannel(status({ verificationStatus: "VERIFICATION_STATUS_UNSPECIFIED" })).reason,
    "unverified:VERIFICATION_STATUS_UNSPECIFIED",
  );
});

test("evaluateChannel rejects placeholder and disallowed targets", () => {
  assert.equal(
    evaluateChannel(status({ target: "ops@example.com", verificationStatus: "VERIFIED" })).reason,
    "placeholder-target:ops@example.com",
  );
  assert.equal(
    evaluateChannel(status({ target: "support@openburnbar.app", verificationStatus: "VERIFIED" })).reason,
    "disallowed-email:support@openburnbar.app",
  );
});

test("evaluateChannel fails closed on missing, disabled, unknown, and empty-target channels", () => {
  assert.equal(evaluateChannel(status({ present: false })).reason, "missing");
  assert.equal(evaluateChannel(status({ enabled: false })).reason, "disabled");
  assert.equal(evaluateChannel(status({ target: null })).reason, "empty-target");
  assert.equal(evaluateChannel(status({ type: "pager", target: "burnbar-ops" })).reason, "unsupported-type:pager");
  assert.equal(evaluateChannel(status({ type: null })).reason, "unsupported-type:null");
});

test("evaluateChannel does not demand verification for non-verifiable allowed types", () => {
  assert.deepEqual(
    evaluateChannel(status({ type: "pubsub", target: "projects/burnbar/topics/ops", verificationStatus: null })),
    { ok: true, reason: null },
  );
  assert.equal(
    evaluateChannel(status({ type: "slack", target: "#ops-alerts", verificationStatus: "UNVERIFIED" })).ok,
    true,
  );
});

test("verifiable types are a subset of allowed types", () => {
  for (const type of VERIFIABLE_CHANNEL_TYPES) {
    assert.ok(ALLOWED_CHANNEL_TYPES.has(type), `${type} must also be an allowed channel type`);
  }
});

test("notificationChannelStatus rejects the historical support-address black hole", () => {
  const channel = notificationChannelStatus(
    "projects/burnbar/notificationChannels/dead",
    {
      name: "projects/burnbar/notificationChannels/dead",
      displayName: "Old support email",
      type: "email",
      enabled: true,
      verificationStatus: "VERIFIED",
      labels: { email_address: "support@openburnbar.app" },
    },
  );

  assert.equal(channel.ok, false);
  assert.match(channel.problems.join("\n"), /black-hole address support@openburnbar\.app/);
});

test("checkAlertPolicies fails when a policy references a disabled channel", () => {
  const result = checkAlertPolicies([expectedPolicy], {
    project: "burnbar-test",
    runner: fakeRunner({
      policies: [policyWithChannel("projects/burnbar/notificationChannels/disabled")],
      channels: [
        {
          name: "projects/burnbar/notificationChannels/disabled",
          type: "email",
          enabled: false,
          verificationStatus: "VERIFIED",
          labels: { email_address: "ops@burnbar.ai" },
        },
      ],
    }),
  });

  assert.equal(result.ok, false);
  assert.equal(result.required[0].liveNotificationChannelCount, 0);
  assert.deepEqual(result.required[0].notificationChannelProblems, [
    "projects/burnbar/notificationChannels/disabled: notification channel is disabled",
  ]);
});

test("checkAlertPolicies passes when policy, metric, and verified channel all match", () => {
  const result = checkAlertPolicies([expectedPolicy], {
    project: "burnbar-test",
    runner: fakeRunner({
      policies: [policyWithChannel("projects/burnbar/notificationChannels/operator")],
      channels: [
        {
          name: "projects/burnbar/notificationChannels/operator",
          displayName: "OpenBurnBar Ops",
          type: "email",
          enabled: true,
          verificationStatus: "VERIFIED",
          labels: { email_address: "ops@burnbar.ai" },
        },
      ],
    }),
  });

  assert.equal(result.ok, true);
  assert.equal(result.required[0].liveNotificationChannelCount, 1);
  assert.equal(result.required[0].notificationChannelStatuses[0].emailAddress, "ops@burnbar.ai");
});
