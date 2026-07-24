#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS="$ROOT_DIR/AGENTS.md"
QA_DOC="$ROOT_DIR/docs/qa.md"

for needle in \
  'live Linux/K3s or real-VM test is mandatory' \
  'static rendering, fake-`kubectl`, or Agent-only deployment is never sufficient' \
  'full-stack case is mandatory' \
  'CrashLoopBackOff' \
  '--previous' \
  'Secret hash stability' \
  'mark unavailable gates as blocked'; do
  grep -Fqi -- "$needle" "$AGENTS"
done

for needle in \
  'fresh disposable Linux/K3s VM' \
  'Agent-only' \
  'Dashboard' \
  'WebUI' \
  'Browserless' \
  'full' \
  'reinstall' \
  'CrashLoopBackOff' \
  'invalid credentials rejected' \
  'real Chromium'; do
  grep -Fqi "$needle" "$QA_DOC"
done

printf 'QA contract checks passed\n'
