#!/usr/bin/env bash
# Quick operator discovery for production ops activation.
set -euo pipefail

PROJECT="${GCLOUD_PROJECT:-burnbar}"

echo "==> gcloud auth"
gcloud auth list 2>&1 || true

echo "==> active project"
gcloud config get-value project 2>&1 || true

echo "==> monitoring notification channels (project=${PROJECT})"
gcloud alpha monitoring channels list --project="$PROJECT" --format='table(displayName,name,type)' 2>&1 \
  || gcloud beta monitoring channels list --project="$PROJECT" --format='table(displayName,name,type)' 2>&1 \
  || true

echo "==> ops alert policies (display names)"
gcloud monitoring policies list --project="$PROJECT" --format='value(displayName)' 2>&1 | sort || true

echo "==> health functions deployed"
firebase functions:list --project "$PROJECT" --json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for name in ('healthLive', 'healthReady', 'healthCheck'):
    found = next((f for f in data.get('result', []) if f.get('id') == name), None)
    print(f'{name}:', 'DEPLOYED' if found else 'MISSING', found.get('uri','') if found else '')
" 2>&1 || echo "firebase CLI unavailable"
