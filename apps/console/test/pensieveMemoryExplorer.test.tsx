// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PensieveMemoryExplorer } from "../components/pensieve/PensieveMemoryExplorer";
import { PensieveDashboard } from "../components/pensieve/PensieveDashboard";
import { PensieveMcpDoctorCard } from "../components/pensieve/PensieveMcpDoctorCard";
import { PensieveMemoryFeed } from "../components/pensieve/PensieveMemoryFeed";

vi.mock("@/lib/useAuth", () => ({
  useAuth: () => ({ user: { uid: "test-user-123" }, loading: false }),
}));

vi.mock("@/lib/useDomainUsage", () => ({
  useDomainUsage: () => ({
    data: {
      tier: "ultra",
      limits: { pensieve: { sources: 100, chunks: 500000, bytes: 10737418240 } },
      domains: { pensieve: { count: 84219, bytes: 14200000 } },
    },
    loading: false,
    reload: vi.fn(),
  }),
  usageById: () => ({
    pensieve: { count: 84219, bytes: 14200000 },
  }),
}));

vi.mock("@/lib/usePensieveRepos", () => ({
  usePensieveRepos: () => ({
    repos: [{ id: "repo-1", name: "Ajnunezg/BurnBar", isConnected: true }],
    loading: false,
    reload: vi.fn(),
  }),
}));

vi.mock("@/lib/api", () => ({
  listKnowledgeChunks: vi.fn().mockResolvedValue({
    ok: true,
    chunks: [
      {
        vectorId: "vec_001",
        sourceKind: "chat_memory",
        byteCount: 84,
        updatedAtMillis: Date.now(),
      },
    ],
    hasMore: false,
    nextStartAfterId: null,
  }),
  searchKnowledge: vi.fn(),
}));

describe("Pensieve Memory Components", () => {
  let container: HTMLDivElement | null = null;
  let root: Root | null = null;

  beforeEach(() => {
    container = document.createElement("div");
    document.body.appendChild(container);
    root = createRoot(container);
  });

  afterEach(() => {
    if (root && container) {
      act(() => {
        root!.unmount();
      });
      container.remove();
    }
    container = null;
    root = null;
  });

  it("renders PensieveMemoryExplorer with total memory count and search filter", async () => {
    await act(async () => {
      root!.render(<PensieveMemoryExplorer totalCount={84219} />);
    });

    expect(container?.textContent).toContain("Memory Explorer");
    expect(container?.textContent).toContain("84,219");
    expect(container?.textContent).toContain("Total Memories");
    expect(container?.textContent).toContain("Kind:");
  });

  it("renders PensieveMemoryFeed with live stream timeline", async () => {
    await act(async () => {
      root!.render(<PensieveMemoryFeed />);
    });

    expect(container?.textContent).toContain("Live Memory Stream");
    expect(container?.textContent).toContain("Live Sync Active");
  });

  it("renders PensieveMcpDoctorCard with system health and test recording", async () => {
    await act(async () => {
      root!.render(<PensieveMcpDoctorCard />);
    });

    expect(container?.textContent).toContain("Memory MCP Health & Diagnostics");
    expect(container?.textContent).toContain("84,219 records indexed");
    expect(container?.textContent).toContain("Test Memory Ingestion");
  });

  it("renders PensieveDashboard with top-right 3-way view toggle", async () => {
    await act(async () => {
      root!.render(<PensieveDashboard />);
    });

    expect(container?.textContent).toContain("Explorer");
    expect(container?.textContent).toContain("Feed");
    expect(container?.textContent).toContain("Diagnostics & MCP");
    expect(container?.textContent).toContain("84,219");
  });
});
