import { describe, expect, it } from "vitest";
import { FieldValue } from "firebase-admin/firestore";

import { missionApprovalResolutionWrite } from "../callables/agentGrantCallables.js";

describe("missionApprovalResolutionWrite (respondMissionApproval persist contract)", () => {
  it("keeps Approve parked in waiting_for_approval so the Mac listener can claim it", () => {
    const write = missionApprovalResolutionWrite({
      approve: true,
      deviceId: "iphone-trusted-1",
    });

    expect(write.approvalStatus).toBe("approved");
    expect(write.approvedByDeviceId).toBe("iphone-trusted-1");
    expect(write).not.toHaveProperty("status");
    expect(write.approvalRespondedAt).toEqual(FieldValue.serverTimestamp());
    expect(write.updatedAt).toEqual(FieldValue.serverTimestamp());
  });

  it("makes Deny leave waiting_for_approval so the inbox cannot re-hydrate the card", () => {
    const write = missionApprovalResolutionWrite({
      approve: false,
      deviceId: "iphone-trusted-1",
    });

    expect(write.approvalStatus).toBe("rejected");
    expect(write.status).toBe("canceled");
    expect(write.approvedByDeviceId).toBe("iphone-trusted-1");
    expect(write.approvalRespondedAt).toEqual(FieldValue.serverTimestamp());
    expect(write.updatedAt).toEqual(FieldValue.serverTimestamp());
  });
});
