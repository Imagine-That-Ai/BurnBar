#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
python3 -m venv .venv
./.venv/bin/pip install -U pip
./.venv/bin/pip install -r requirements.txt
echo "OK: use $(pwd)/.venv/bin/python $(pwd)/server.py in MCP config"
