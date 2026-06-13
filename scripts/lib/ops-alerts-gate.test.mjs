import assert from "node:assert/strict";
import test from "node:test";

import { checkAlertPolicies, notificationChannelStatus } from "./ops-alerts-gate.mjs";

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

test("notificationChannelStatus rejects the historical support-address black hole", () => {
  const status = notificationChannelStatus(
    "projects/burnbar/notificationChannels/dead",
    {
      name: "projects/burnbar/notificationChannels/dead",
      displayName: "Old support email",
      type: "email",
      enabled: true,
      labels: { email_address: "support@openburnbar.app" },
    },
  );

  assert.equal(status.ok, false);
  assert.match(status.problems.join("\n"), /black-hole address support@openburnbar\.app/);
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
          labels: { email_address: "ops@example.com" },
        },
      ],
    }),
  });

  assert.equal(result.ok, false);
  assert.deepEqual(result.required[0].notificationChannelProblems, [
    "projects/burnbar/notificationChannels/disabled: notification channel is disabled",
  ]);
});

test("checkAlertPolicies passes when policy, metric, and enabled channel all match", () => {
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
          labels: { email_address: "alberto8793@gmail.com" },
        },
      ],
    }),
  });

  assert.equal(result.ok, true);
  assert.equal(result.required[0].notificationChannelStatuses[0].emailAddress, "alberto8793@gmail.com");
});
