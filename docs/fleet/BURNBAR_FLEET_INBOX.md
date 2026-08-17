# Fleet Inbox

BurnBar-owned drop directory for **every** roster CLI and **every** thread.

```
~/Library/Application Support/BurnBar/fleet-inbox/<agent-id>/<sessionRef>.jsonl
```

Mode `0600`. One JSON object per line:

```json
{"createdAt":"...","id":"<directive-id>","kind":"askStatus","payload":"...","sessionRef":"<thread>","targetAgent":"claude-code"}
```

A successful append is **submitted**, never delivered. First-party CLI
skills should poll this directory and pull unread lines. That is the
documented multi-CLI, multi-thread write path.

Do not use Claude `/tmp/cc-socks`. Do not treat an OpenAI-shaped HTTP 200
as delivered.
