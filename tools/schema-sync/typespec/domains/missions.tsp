/** Mission dispatch and approval policy contracts. */
namespace OpenBurnBar.Firestore.Missions;

model MissionDispatchDoc {
  missionId: string;
  status: string;
  createdAt: string;
  updatedAt?: string;
  payloadSummary?: string;
}

model ApprovalPolicyDoc {
  policyVersion: int32;
  updatedAt: string;
}
