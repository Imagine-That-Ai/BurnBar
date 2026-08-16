---
name: openburnbar-doctor
description: Diagnose OpenBurnBar MCP auth, capabilities, and sealed fields.
---

Use the `openburnbar-doctor` skill to diagnose OpenBurnBar MCP connectivity,
auth, and sealed-field behavior. Call `burnbar_resolve_capabilities` first,
check index status, and compare the HTTP marketplace path with the optional
local decrypt shim.
