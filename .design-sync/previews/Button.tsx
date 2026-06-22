import { Button } from "@openburnbar/console";
import { Save, Plus, Trash2 } from "lucide-react";

export const Variants = () => (
  <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center" }}>
    <Button variant="primary">Save changes</Button>
    <Button variant="secondary">Cancel</Button>
    <Button variant="ghost">Dismiss</Button>
    <Button variant="destructive">Delete domain</Button>
    <Button variant="link">Learn more</Button>
  </div>
);

export const Sizes = () => (
  <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
    <Button size="sm">Small</Button>
    <Button size="md">Medium</Button>
    <Button size="lg">Large</Button>
  </div>
);

export const WithIcons = () => (
  <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
    <Button variant="primary"><Save /> Save</Button>
    <Button variant="secondary"><Plus /> Add source</Button>
    <Button variant="destructive"><Trash2 /> Delete</Button>
    <Button variant="ghost" size="icon" aria-label="Add source"><Plus /></Button>
  </div>
);

export const Disabled = () => (
  <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
    <Button variant="primary" disabled>Save changes</Button>
    <Button variant="secondary" disabled>Cancel</Button>
  </div>
);
