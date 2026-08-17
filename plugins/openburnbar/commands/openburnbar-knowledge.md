---
name: openburnbar-knowledge
description: Check whether hosted knowledge search has the required scope and local preprocessing.
---

Run the `openburnbar-knowledge` skill workflow:

1. Call `burnbar_resolve_capabilities` first and read the returned tool list.
2. Check whether the grant includes `knowledge:read`; a default grant lacks
   it, so state that caveat before calling
   `burnbar_search_knowledge` / `burnbar_get_knowledge_document`.
3. Require a trusted local shim to supply the cloaked 384-element
   `queryVector`; the HTTP-only marketplace plugin cannot derive it.
4. If either requirement is missing, stop and name the blocker instead of
   sending plaintext or claiming no matches.
