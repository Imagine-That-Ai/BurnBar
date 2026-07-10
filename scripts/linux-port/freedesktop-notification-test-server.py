#!/usr/bin/env python3
"""Minimal freedesktop notification server for installed-session evidence.

The desktop-session harness runs this inside the isolated D-Bus session. It
owns org.freedesktop.Notifications, records Notify calls, and emits an
ActionInvoked signal for the configured action so the packaged app exercises
the same notify-rust response path it uses with real desktop notification
servers.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--log-jsonl", required=True)
    parser.add_argument("--auto-action", default="open")
    parser.add_argument("--action-delay-ms", type=int, default=500)
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def write_jsonl(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, sort_keys=True) + "\n")


def self_test() -> int:
    payload = {
        "event": "Notify",
        "summary": "OpenBurnBar notification evidence",
        "actions": ["default", "Open", "open", "Open"],
    }
    if "open" not in payload["actions"]:
        print(json.dumps({"selfTest": "fail", "payload": payload}))
        return 1
    print(json.dumps({"selfTest": "pass", "payload": payload}, indent=2))
    return 0


def main() -> int:
    args = parse_args()
    if args.self_test:
        return self_test()

    import dbus
    import dbus.service
    from dbus.mainloop.glib import DBusGMainLoop
    from gi.repository import GLib

    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    log_path = Path(args.log_jsonl)
    ready_path = Path(args.ready_file)

    class NotificationServer(dbus.service.Object):
        def __init__(self) -> None:
            self.loop = GLib.MainLoop()
            self.next_id = 1
            self.bus_name = dbus.service.BusName("org.freedesktop.Notifications", bus)
            super().__init__(self.bus_name, "/org/freedesktop/Notifications")

        @dbus.service.method("org.freedesktop.Notifications", in_signature="", out_signature="as")
        def GetCapabilities(self):  # noqa: N802 - D-Bus API name
            capabilities = ["actions", "body", "persistence"]
            write_jsonl(log_path, {"event": "GetCapabilities", "capabilities": capabilities})
            return capabilities

        @dbus.service.method("org.freedesktop.Notifications", in_signature="", out_signature="ssss")
        def GetServerInformation(self):  # noqa: N802 - D-Bus API name
            info = ("OpenBurnBar Test Notifications", "OpenBurnBar", "1.0", "1.2")
            write_jsonl(log_path, {"event": "GetServerInformation", "serverName": info[0]})
            return info

        @dbus.service.method("org.freedesktop.Notifications", in_signature="u", out_signature="")
        def CloseNotification(self, notification_id):  # noqa: N802 - D-Bus API name
            write_jsonl(log_path, {"event": "CloseNotification", "notificationId": int(notification_id)})
            self.NotificationClosed(notification_id, 3)

        @dbus.service.method(
            "org.freedesktop.Notifications",
            in_signature="susssasa{sv}i",
            out_signature="u",
        )
        def Notify(  # noqa: N802 - D-Bus API name
            self,
            app_name,
            replaces_id,
            app_icon,
            summary,
            body,
            actions,
            hints,
            expire_timeout,
        ):
            notification_id = int(replaces_id) if int(replaces_id) else self.next_id
            self.next_id = max(self.next_id + 1, notification_id + 1)
            action_list = [str(value) for value in actions]
            write_jsonl(
                log_path,
                {
                    "event": "Notify",
                    "notificationId": notification_id,
                    "appName": str(app_name),
                    "summary": str(summary),
                    "body": str(body),
                    "actions": action_list,
                    "expireTimeout": int(expire_timeout),
                },
            )
            action = args.auto_action if args.auto_action in action_list else "default"
            GLib.timeout_add(args.action_delay_ms, self._emit_action, notification_id, action)
            return dbus.UInt32(notification_id)

        def _emit_action(self, notification_id: int, action: str):
            write_jsonl(
                log_path,
                {"event": "ActionInvoked", "notificationId": notification_id, "action": action},
            )
            self.ActionInvoked(notification_id, action)
            return False

        @dbus.service.signal("org.freedesktop.Notifications", signature="us")
        def ActionInvoked(self, notification_id, action):  # noqa: N802 - D-Bus API name
            pass

        @dbus.service.signal("org.freedesktop.Notifications", signature="uu")
        def NotificationClosed(self, notification_id, reason):  # noqa: N802 - D-Bus API name
            pass

    server = NotificationServer()
    ready_path.write_text(
        json.dumps(
            {
                "ready": True,
                "service": "org.freedesktop.Notifications",
                "serverName": "OpenBurnBar Test Notifications",
                "pid": __import__("os").getpid(),
                "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    server.loop.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
