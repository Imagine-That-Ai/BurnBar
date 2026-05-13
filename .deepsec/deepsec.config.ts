import { defineConfig } from "deepsec/config";

export default defineConfig({
  projects: [
    {
      id: "BurnBar",
      root: "..",
      priorityPaths: [
        "functions/src/",
        "services/hermes-realtime-relay/src/",
        "OpenBurnBarDaemon/Sources/",
        "AgentLens/Services/",
        "firestore.rules",
      ],
    },
    // <deepsec:projects-insert-above>
  ],
});
