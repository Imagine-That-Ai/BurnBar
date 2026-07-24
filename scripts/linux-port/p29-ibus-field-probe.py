#!/usr/bin/python3
"""Live GTK input fields used to verify the installed OpenBurnBar IBus engine."""

import argparse
import importlib
import json
import os
import tempfile
import time
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
_gi_repository = importlib.import_module("gi.repository")
GLib = _gi_repository.GLib
Gtk = _gi_repository.Gtk


def write_state(path, marker, normal, secure):
    document = {
        "producer": "openburnbar-p29-ibus-field-probe-v1",
        "marker": marker,
        "pid": os.getpid(),
        "normalText": normal.get_text(),
        "secureText": secure.get_text(),
        "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=".p29-field-", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(document, output, separators=(",", ":"))
            output.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-file", required=True)
    parser.add_argument("--marker", required=True)
    args = parser.parse_args()
    state_path = Path(args.state_file).resolve()

    GLib.set_application_name("OpenBurnBar P29 IBus Probe")
    window = Gtk.Window(title="OpenBurnBar P29 IBus Probe")
    window.set_default_size(620, 220)
    window.set_border_width(24)
    window.connect("destroy", Gtk.main_quit)

    layout = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
    heading = Gtk.Label(label="OpenBurnBar input-method engine verification")
    heading.set_xalign(0)
    normal = Gtk.Entry()
    normal.set_placeholder_text("P-29 nonsecure expansion field")
    normal.get_accessible().set_name("P-29 nonsecure expansion field")
    normal.set_input_purpose(Gtk.InputPurpose.FREE_FORM)
    secure = Gtk.Entry()
    secure.set_placeholder_text("P-29 secure password field")
    secure.get_accessible().set_name("P-29 secure password field")
    secure.set_visibility(False)
    secure.set_input_purpose(Gtk.InputPurpose.PASSWORD)
    layout.pack_start(heading, False, False, 0)
    layout.pack_start(normal, False, False, 0)
    layout.pack_start(secure, False, False, 0)
    window.add(layout)

    def persist(*_args):
        write_state(state_path, args.marker, normal, secure)

    normal.connect("changed", persist)
    secure.connect("changed", persist)
    window.show_all()
    normal.grab_focus()
    persist()
    Gtk.main()


if __name__ == "__main__":
    main()
