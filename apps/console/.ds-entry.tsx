// Design-system bundle entry for /design-sync (claude.ai/design).
// A scoped barrel: re-exports ONLY the components synced as the BurnBar design
// system, so esbuild bundles these (and their deps) into window.OpenBurnBarConsole
// without dragging in the app's feature/firebase code. Not used by the app.
// Regenerate/extend by editing .design-sync/config.json's componentSrcMap to match.
export { Button, buttonVariants } from "@/components/ui/button";
export { Badge } from "@/components/ui/badge";
export {
  Card,
  CardHeader,
  CardTitle,
  CardDescription,
  CardContent,
} from "@/components/ui/card";
export {
  Dialog,
  DialogTrigger,
  DialogClose,
  DialogContent,
  DialogHeader,
  DialogFooter,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
export { Progress } from "@/components/ui/progress";
export { BrandMark } from "@/components/BrandMark";
export { TierGlyph } from "@/components/basin/TierGlyph";
export { TierBadge } from "@/components/inventory/TierBadge";
export { DotCrestField } from "@/components/DotCrestField";
