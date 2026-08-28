import { describe, it, expect } from "vitest";
import {
  AMPLITUDE_PROJECT,
  FORBIDDEN_AMPLITUDE_PROJECTS,
  FUNNEL_CMO_ALIAS,
  FUNNEL_EVENT,
  FUNNEL_EVENT_NAMES,
  FUNNEL_PRODUCT,
  isAllowedAmplitudeProject,
  isForbiddenAmplitudeProject,
  isFunnelEventName,
  resolveAmplitudeProjectId,
} from "../../analytics/funnel-contract";
import { EVENT } from "../src/lib/analytics/events";

describe("funnel contract", () => {
  it("maps every CMO logical name to a taxonomy-legal wire name", () => {
    expect(FUNNEL_CMO_ALIAS.page_viewed).toBe("page.viewed");
    expect(FUNNEL_CMO_ALIAS.app_opened).toBe("app.opened");
    expect(FUNNEL_CMO_ALIAS.cta_clicked).toBe("cta.clicked");
    expect(FUNNEL_CMO_ALIAS.download_clicked).toBe("download.clicked");
    expect(FUNNEL_CMO_ALIAS.install_started).toBe("install.started");
    expect(FUNNEL_CMO_ALIAS.email_captured).toBe("email.captured");
    expect(FUNNEL_EVENT_NAMES).toHaveLength(6);
  });

  it("registers every funnel wire name on the website EVENT object", () => {
    for (const name of FUNNEL_EVENT_NAMES) {
      expect(Object.values(EVENT), `website EVENT missing ${name}`).toContain(name);
    }
  });

  it("locks product to burnbar", () => {
    expect(FUNNEL_PRODUCT).toBe("burnbar");
  });
});

describe("Amplitude project routing", () => {
  it("allows only OpenBurnBar prod 830583 and Dev 830581", () => {
    expect(AMPLITUDE_PROJECT.production).toBe(830583);
    expect(AMPLITUDE_PROJECT.development).toBe(830581);
    expect(isAllowedAmplitudeProject(830583)).toBe(true);
    expect(isAllowedAmplitudeProject(830581)).toBe(true);
    expect(resolveAmplitudeProjectId("830583")).toBe(830583);
    expect(resolveAmplitudeProjectId("830581")).toBe(830581);
  });

  it("rejects CubeLove and Hormiga project ids", () => {
    expect(FORBIDDEN_AMPLITUDE_PROJECTS.cubelove).toBe(852537);
    expect(FORBIDDEN_AMPLITUDE_PROJECTS.hormigaDefault).toBe(703455);
    expect(FORBIDDEN_AMPLITUDE_PROJECTS.hormigaDesktop).toBe(799824);
    expect(isForbiddenAmplitudeProject(852537)).toBe(true);
    expect(isForbiddenAmplitudeProject(703455)).toBe(true);
    expect(isForbiddenAmplitudeProject(799824)).toBe(true);
    expect(resolveAmplitudeProjectId(852537)).toBeNull();
    expect(resolveAmplitudeProjectId("703455")).toBeNull();
    expect(resolveAmplitudeProjectId("799824")).toBeNull();
    expect(isAllowedAmplitudeProject(852537)).toBe(false);
    expect(isAllowedAmplitudeProject(703455)).toBe(false);
  });

  it("rejects empty, non-numeric, and unknown project ids", () => {
    expect(resolveAmplitudeProjectId(undefined)).toBeNull();
    expect(resolveAmplitudeProjectId("")).toBeNull();
    expect(resolveAmplitudeProjectId("not-a-number")).toBeNull();
    expect(resolveAmplitudeProjectId(1)).toBeNull();
  });

  it("treats only the six funnel names as funnel events", () => {
    expect(isFunnelEventName(FUNNEL_EVENT.pageViewed)).toBe(true);
    expect(isFunnelEventName("screen.viewed")).toBe(false);
    expect(isFunnelEventName("page_viewed")).toBe(false);
  });
});
