import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter, Button,
} from "@openburnbar/console";

// Rendered open (defaultOpen) so the card shows the modal on its dimmed
// backdrop. cfg.overrides.Dialog pins cardMode "single" so the portal'd
// overlay renders inside the card instead of escaping it.
export const Default = () => (
  <Dialog defaultOpen>
    <DialogContent>
      <DialogHeader>
        <DialogTitle>Connect a repository</DialogTitle>
        <DialogDescription>
          Grant Pensieve read access to index your code for recall. You can revoke this anytime.
        </DialogDescription>
      </DialogHeader>
      <DialogFooter>
        <Button variant="ghost">Cancel</Button>
        <Button variant="primary">Authorize</Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
);
