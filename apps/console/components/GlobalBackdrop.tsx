"use client";

import { KernelBackdrop } from "@/components/dashboard/KernelBackdrop";
import { useBackdrop } from "@/lib/useBackdrop";

/** Mounts the console-wide animated kernel once, behind every tab. */
export function GlobalBackdrop() {
  const { kernelId } = useBackdrop();
  return <KernelBackdrop kernelId={kernelId} />;
}
