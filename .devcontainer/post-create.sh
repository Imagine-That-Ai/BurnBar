#!/usr/bin/env bash
# Post-create setup for devcontainer
# Installs all dependencies and configures local development environment

set -euo pipefail

cd /workspaces/burnbar

echo "==> Installing Node.js dependencies..."
npm ci --prefix functions
npm ci --prefix extensions/openburnbar
npm ci --prefix website 2>/dev/null || true

echo "==> Installing pre-commit hooks..."
pip install pre-commit 2>/dev/null || pip3 install pre-commit 2>/dev/null || true
pre-commit install --install-hooks 2>/dev/null || echo "pre-commit install skipped (macOS hooks not applicable in devcontainer)"

echo "==> Installing Firebase CLI..."
npm install -g firebase-tools@latest

echo "==> Installing Android SDK tools..."
if command -v sdkmanager &>/dev/null; then
  sdkmanager "platforms;android-35" "build-tools;35.0.0" --no_https
fi

echo "==> Setting up .env files..."
if [[ ! -f functions/.env ]]; then
  cat > functions/.env << 'EOF'
# Copy from Firebase Console — never commit real credentials
FIREBASE_PROJECT_ID=openburnbar-dev
STRIPE_SECRET_KEY=sk_test_placeholder
EOF
  echo "Created functions/.env (placeholder — update with real dev credentials)"
fi

if [[ ! -f website/.env ]]; then
  cp website/.env.example website/.env 2>/dev/null || echo "No website/.env.example found"
fi

echo ""
echo "==> DevContainer ready!"
echo ""
echo "Quick start:"
echo "  Functions emulator: npm --prefix functions run serve"
echo "  Website dev server: npm --prefix website run dev"
echo "  Run all tests:      make test"
echo ""
