#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/hermes.env}"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
HERMES_NAMESPACE="${HERMES_NAMESPACE:-hermes}"
WEBUI_HOST="${WEBUI_HOST:-}"
DASHBOARD_HOST="${DASHBOARD_HOST:-}"

ok() { printf '\033[1;32mOK\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*"; }
fail_count=0
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; fail_count=$((fail_count+1)); }

check_cmd() { command -v "$1" >/dev/null 2>&1 && ok "command $1" || fail "missing command $1"; }

check_k8s() {
  kubectl cluster-info >/dev/null 2>&1 && ok "kubectl can reach cluster" || fail "kubectl cannot reach cluster"
  kubectl get ns "$HERMES_NAMESPACE" >/dev/null 2>&1 && ok "namespace $HERMES_NAMESPACE exists" || fail "namespace $HERMES_NAMESPACE missing"
}

check_rollouts() {
  for d in hermes-agent hermes-dashboard hermes-webui hermes-browser; do
    if kubectl -n "$HERMES_NAMESPACE" rollout status "deploy/$d" --timeout=5s >/dev/null 2>&1; then
      ok "deployment $d ready"
    else
      fail "deployment $d not ready"
    fi
  done
}

check_internal_health() {
  local image="curlimages/curl:8.11.1"
  if kubectl -n "$HERMES_NAMESPACE" run hermes-doctor-curl --rm -i --restart=Never --image="$image" -- sh -lc '
    set -e
    curl -fsS http://hermes-agent:8642/health >/dev/null
    curl -fsS http://hermes-webui:8787/health >/dev/null
    curl -fsS -o /dev/null -w "%{http_code}" http://hermes-dashboard:9119/ | grep -Eq "^(200|302)$"
  ' >/dev/null 2>&1; then
    ok "internal service health"
  else
    fail "internal service health failed"
  fi
}

check_browser_cdp() {
  local pod timeout_seconds browser_pod cdp token pressure pressure_state running max_concurrent queued is_available
  timeout_seconds="${DOCTOR_CDP_TIMEOUT_SECONDS:-15}"

  browser_pod="$(kubectl -n "$HERMES_NAMESPACE" get pods -l app=hermes-browser --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  cdp="$(kubectl -n "$HERMES_NAMESPACE" get secret hermes-browser-cdp -o jsonpath='{.data.BROWSER_CDP_URL}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  token="${cdp##*token=}"
  if [[ -n "$browser_pod" && -n "$token" && "$token" != "$cdp" ]]; then
    pressure="$(timeout 8s kubectl -n "$HERMES_NAMESPACE" exec "$browser_pod" -- sh -lc 'TOKEN="$0"; wget -qO- "http://127.0.0.1:3000/pressure?token=$TOKEN"' "$token" 2>/dev/null || true)"
    if [[ -n "$pressure" ]]; then
      pressure_state="$(PRESSURE_JSON="$pressure" python3 - <<'PY'
import json, os
try:
    p=json.loads(os.environ.get('PRESSURE_JSON','{}')).get('pressure', {})
    print(p.get('running', ''), p.get('maxConcurrent', ''), p.get('queued', ''), str(p.get('isAvailable', '')).lower())
except Exception:
    print('', '', '', '')
PY
)"
      read -r running max_concurrent queued is_available <<<"$pressure_state"
      if [[ "$is_available" == "true" ]]; then
        ok "browserless pressure available running=${running:-?} max=${max_concurrent:-?} queued=${queued:-?}"
      fi
      if [[ "${queued:-0}" =~ ^[0-9]+$ && "${queued:-0}" -gt 0 ]]; then
        warn "browserless has queued CDP sessions; skipping active navigation test to avoid doctor hanging"
        return 0
      fi
      if [[ "${max_concurrent:-}" =~ ^[0-9]+$ && "$max_concurrent" -lt 2 ]]; then
        warn "browserless maxConcurrent=${max_concurrent}; skipping active navigation test because Hermes browser_navigate can open multiple CDP sessions"
        return 0
      fi
      if [[ "${running:-}" =~ ^[0-9]+$ && "${max_concurrent:-}" =~ ^[0-9]+$ && "$max_concurrent" -gt 0 && "$running" -ge "$max_concurrent" ]]; then
        warn "browserless is at concurrency limit (${running}/${max_concurrent}); skipping active navigation test"
        return 0
      fi
    fi
  fi

  pod="$(kubectl -n "$HERMES_NAMESPACE" get pods -l app=hermes-agent --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || { fail "no running hermes-agent pod"; return; }
  if timeout "${timeout_seconds}s" kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc '/opt/hermes/.venv/bin/python - <<PY
from tools.browser_tool import _get_cdp_override, browser_navigate
url=_get_cdp_override()
assert url and "/chromium" in url
r=browser_navigate("https://example.com", task_id="doctor-cdp")
assert "Example Domain" in r and "cdp_override" in r
print("ok")
PY' >/dev/null 2>&1; then
    ok "browser CDP from hermes-agent"
  else
    fail "browser CDP from hermes-agent failed or timed out after ${timeout_seconds}s"
  fi
}

check_agent_home_ssh() {
  local pod home xdg_config xdg_cache ssh_setup ssh_generate key_path ssh_dir_mode key_mode pub_mode
  pod="$(kubectl -n "$HERMES_NAMESPACE" get pods -l app=hermes-agent --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || { fail "no running hermes-agent pod for HOME/SSH check"; return; }

  home="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc 'printf %s "${HOME:-}"' 2>/dev/null || true)"
  xdg_config="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc 'printf %s "${XDG_CONFIG_HOME:-}"' 2>/dev/null || true)"
  xdg_cache="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc 'printf %s "${XDG_CACHE_HOME:-}"' 2>/dev/null || true)"

  if [[ "${HERMES_HOME_AS_HOME:-true}" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]]; then
    if [[ "$home" == "/opt/data" && "$xdg_config" == "/opt/data/.config" && "$xdg_cache" == "/opt/data/.cache" ]]; then
      ok "agent HOME/XDG point to persistent /opt/data"
    else
      fail "agent HOME/XDG are not persistent (HOME=${home:-unset}, XDG_CONFIG_HOME=${xdg_config:-unset}, XDG_CACHE_HOME=${xdg_cache:-unset})"
    fi
  fi

  ssh_setup="${HERMES_SSH_SETUP:-true}"
  [[ "$ssh_setup" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]] || return 0

  ssh_dir_mode="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc 'test -d /opt/data/.ssh && stat -c %a /opt/data/.ssh' 2>/dev/null || true)"
  if [[ "$ssh_dir_mode" == "700" ]]; then
    ok "persistent SSH directory /opt/data/.ssh mode 700"
  else
    fail "persistent SSH directory invalid or wrong mode (${ssh_dir_mode:-missing})"
  fi

  key_path="${HERMES_SSH_KEY_PATH:-/opt/data/.ssh/id_ed25519}"
  key_mode="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc 'p="$0"; test -s "$p" && stat -c %a "$p"' "$key_path" 2>/dev/null || true)"
  pub_mode="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc 'p="$0.pub"; test -s "$p" && stat -c %a "$p"' "$key_path" 2>/dev/null || true)"
  if [[ "$key_mode" == "600" && "$pub_mode" == "644" ]]; then
    ok "persistent SSH keypair exists with safe modes"
  else
    fail "persistent SSH keypair missing or wrong modes (private=${key_mode:-missing}, public=${pub_mode:-missing})"
  fi
}

check_webui_agent_source() {
  local pod
  pod="$(kubectl -n "$HERMES_NAMESPACE" get pods -l app=hermes-webui --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || { fail "no running hermes-webui pod"; return; }
  if kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc 'test -f /home/hermeswebui/.hermes/hermes-agent/run_agent.py && test -n "$BROWSER_CDP_URL"' >/dev/null 2>&1; then
    ok "webui agent source mount and BROWSER_CDP_URL"
  else
    fail "webui agent source mount or BROWSER_CDP_URL missing"
  fi
}



check_addon_python_runtime() {
  [[ -n "${HERMES_ADDON_REQUIREMENTS:-}" ]] || return 0
  local app pod py_out ansible_out
  for app in hermes-agent hermes-webui; do
    pod="$(kubectl -n "$HERMES_NAMESPACE" get pods -l app="$app" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "$pod" ]] || { fail "no running $app pod for addon Python check"; continue; }
    py_out="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -c 'test -x /opt/data/uv/bin/uv && test -f /opt/data/addon-venv/.hermes-uv-managed && /opt/data/addon-venv/bin/python --version' 2>/dev/null || true)"
    if [[ "$py_out" == Python\ * ]]; then
      ok "$app uv-managed addon Python ${py_out#Python }"
    else
      fail "$app uv-managed addon Python missing or broken"
    fi
    ansible_out="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -c 'if [ -x /opt/data/addon-venv/bin/ansible ]; then /opt/data/addon-venv/bin/ansible --version | sed -n "1p"; fi' 2>/dev/null || true)"
    if [[ "$ansible_out" == ansible\ * ]]; then
      ok "$app addon Ansible available (${ansible_out})"
    fi
  done
}

check_dashboard_workspace_root() {
  local pod root roots
  pod=$(kubectl -n "$HERMES_NAMESPACE" get pod -l app=hermes-dashboard --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "$pod" ]] || { warn "no running dashboard pod for workspace-root check"; return; }
  root=$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc 'printf %s "${HERMES_DASHBOARD_FILES_ROOT:-}"' 2>/dev/null || true)
  roots=$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc 'printf %s "${HERMES_WRITE_SAFE_ROOT:-}"' 2>/dev/null || true)
  if [[ "$root" == "/workspace" && "$roots" == *"/workspace"* ]]; then
    ok "dashboard files root is /workspace and write-safe roots include /workspace"
  else
    fail "dashboard workspace roots invalid (HERMES_DASHBOARD_FILES_ROOT=${root:-unset}, HERMES_WRITE_SAFE_ROOT=${roots:-unset})"
  fi
}

check_webui_upload_limit() {
  local pod expected actual
  expected="${HERMES_WEBUI_MAX_UPLOAD_MB:-220}"
  pod="$(kubectl -n "$HERMES_NAMESPACE" get pods -l app=hermes-webui --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || { fail "no running hermes-webui pod"; return; }
  actual="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc '/app/venv/bin/python - <<PY
from api.config import MAX_UPLOAD_BYTES
print(MAX_UPLOAD_BYTES // 1024 // 1024)
PY' 2>/dev/null || true)"
  if [[ "$actual" == "$expected" ]]; then
    ok "WebUI upload limit ${actual}MiB"
  else
    fail "WebUI upload limit expected ${expected}MiB but got '${actual:-unknown}'"
  fi
}

check_external() {
  if [[ -n "$WEBUI_HOST" ]]; then
    local code
    code="$(curl -k -sS -o /dev/null -w '%{http_code}' "https://$WEBUI_HOST/" 2>/dev/null || true)"
    [[ "$code" =~ ^(200|301|302|401)$ ]] && ok "external WebUI HTTP $code" || warn "external WebUI returned '$code'"
  fi
  if [[ -n "$DASHBOARD_HOST" ]]; then
    local code
    code="$(curl -k -sS -o /dev/null -w '%{http_code}' "https://$DASHBOARD_HOST/" 2>/dev/null || true)"
    [[ "$code" =~ ^(200|301|302|401)$ ]] && ok "external Dashboard HTTP $code" || warn "external Dashboard returned '$code'"
  fi
}

check_codex_auth() {
  local pod
  pod="$(kubectl -n "$HERMES_NAMESPACE" get pods -l app=hermes-agent --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || return
  if kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc 'test -s /opt/data/auth.json' >/dev/null 2>&1; then
    ok "Codex/OAuth auth.json exists"
  else
    warn "Codex/OAuth auth.json absent; run: kubectl -n $HERMES_NAMESPACE exec -it deploy/hermes-agent -- hermes model"
  fi
}

main() {
  check_cmd kubectl
  check_cmd curl
  check_cmd timeout
  check_k8s
  check_rollouts
  check_internal_health
  check_agent_home_ssh
  check_webui_agent_source
  check_addon_python_runtime
  check_dashboard_workspace_root
  check_webui_upload_limit
  check_browser_cdp
  check_external
  check_codex_auth
  if [[ "$fail_count" -gt 0 ]]; then
    printf '\n%s check(s) failed.\n' "$fail_count" >&2
    exit 1
  fi
  printf '\nAll mandatory checks passed.\n'
}
main "$@"
