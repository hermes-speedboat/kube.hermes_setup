#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/hermes.env}"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
HERMES_NAMESPACE="${HERMES_NAMESPACE:-hermes}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
rand_hex() { openssl rand -hex "${1:-32}"; }
credential_output_file() { mkdir -p "$ROOT_DIR/.rendered"; chmod 700 "$ROOT_DIR/.rendered"; printf "%s/rotated-credentials-%s.txt" "$ROOT_DIR/.rendered" "$(date -u +%Y%m%dT%H%M%SZ)"; }

usage() {
  cat <<'EOF'
Usage:
  ./maintain.sh status
  ./maintain.sh restart
  ./maintain.sh upgrade
  ./maintain.sh backup <backup.tgz>
  ./maintain.sh restore <backup.tgz>
  ./maintain.sh rotate-passwords [--lab] [--generate] [--skip-ingress] [--skip-dashboard]
  ./maintain.sh rotate-browser-token

Environment:
  ENV_FILE=./hermes.env
  HERMES_NAMESPACE=hermes
  HERMES_PASSWORD_POLICY=production|lab
  BASIC_AUTH_USER/BASIC_AUTH_PASSWORD for optional Traefik Ingress BasicAuth
  DASHBOARD_AUTH_USER/DASHBOARD_AUTH_PASSWORD for Dashboard internal BasicAuth
EOF
}

status() {
  kubectl -n "$HERMES_NAMESPACE" get pods,svc,ingress,networkpolicy -o wide
}

restart() {
  kubectl -n "$HERMES_NAMESPACE" rollout restart deploy/hermes-agent deploy/hermes-dashboard deploy/hermes-webui deploy/hermes-browser
  for d in hermes-agent hermes-dashboard hermes-webui hermes-browser; do
    kubectl -n "$HERMES_NAMESPACE" rollout status "deploy/$d" --timeout=600s
  done
}

upgrade() {
  log "Pulling fresh images by restarting deployments. Pin image tags in hermes.env for controlled production upgrades."
  restart
}

backup() {
  local out="${1:-}"
  [[ -n "$out" ]] || fail "backup path required"
  mkdir -p "$(dirname "$out")"
  kubectl -n "$HERMES_NAMESPACE" delete pod hermes-backup --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
  cat <<JSON | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: hermes-backup
  namespace: ${HERMES_NAMESPACE}
spec:
  restartPolicy: Never
  containers:
  - name: backup
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: home
      mountPath: /opt/data
    - name: workspace
      mountPath: /workspace
  volumes:
  - name: home
    persistentVolumeClaim:
      claimName: hermes-home
  - name: workspace
    persistentVolumeClaim:
      claimName: hermes-workspace
JSON
  kubectl -n "$HERMES_NAMESPACE" wait --for=condition=Ready pod/hermes-backup --timeout=120s >/dev/null
  kubectl -n "$HERMES_NAMESPACE" exec hermes-backup -- sh -c 'tar czf /tmp/hermes-backup.tgz -C / opt/data workspace'
  kubectl -n "$HERMES_NAMESPACE" cp hermes-backup:/tmp/hermes-backup.tgz "$out" -c backup >/dev/null
  kubectl -n "$HERMES_NAMESPACE" delete pod hermes-backup --ignore-not-found=true --wait=true >/dev/null
  sha256sum "$out"
  ls -lh "$out"
}

restore() {
  local in="${1:-}"
  [[ -f "$in" ]] || fail "backup file required"
  log "Scaling down write-heavy deployments"
  kubectl -n "$HERMES_NAMESPACE" scale deploy/hermes-agent deploy/hermes-dashboard deploy/hermes-webui --replicas=0
  kubectl -n "$HERMES_NAMESPACE" rollout status deploy/hermes-agent --timeout=120s >/dev/null 2>&1 || true
  kubectl -n "$HERMES_NAMESPACE" delete pod hermes-restore --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
  cat <<JSON | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: hermes-restore
  namespace: ${HERMES_NAMESPACE}
spec:
  restartPolicy: Never
  containers:
  - name: restore
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: home
      mountPath: /opt/data
    - name: workspace
      mountPath: /workspace
  volumes:
  - name: home
    persistentVolumeClaim:
      claimName: hermes-home
  - name: workspace
    persistentVolumeClaim:
      claimName: hermes-workspace
JSON
  kubectl -n "$HERMES_NAMESPACE" wait --for=condition=Ready pod/hermes-restore --timeout=120s >/dev/null
  kubectl -n "$HERMES_NAMESPACE" cp "$in" hermes-restore:/tmp/hermes-backup.tgz -c restore >/dev/null
  kubectl -n "$HERMES_NAMESPACE" exec hermes-restore -- sh -c 'rm -rf /opt/data/* /workspace/*; tar xzf /tmp/hermes-backup.tgz -C /; chown -R 1000:1000 /opt/data /workspace || true'
  kubectl -n "$HERMES_NAMESPACE" delete pod hermes-restore --ignore-not-found=true --wait=true >/dev/null
  log "Scaling deployments up"
  kubectl -n "$HERMES_NAMESPACE" scale deploy/hermes-agent deploy/hermes-dashboard deploy/hermes-webui --replicas=1
  for d in hermes-agent hermes-dashboard hermes-webui; do
    kubectl -n "$HERMES_NAMESPACE" rollout status "deploy/$d" --timeout=600s
  done
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_secret() {
  local var_name="$1" label="$2" value=""
  value="$(printenv "$var_name" 2>/dev/null || true)"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi
  [[ -t 0 ]] || fail "$var_name is required in non-interactive mode. Export it or run from a TTY."
  local first second
  while true; do
    read -r -s -p "$label: " first; printf '\n' >&2
    read -r -s -p "Confirm $label: " second; printf '\n' >&2
    [[ "$first" == "$second" ]] || { printf 'Passwords did not match. Try again.\n' >&2; continue; }
    [[ -n "$first" ]] || { printf 'Password must not be empty.\n' >&2; continue; }
    printf '%s' "$first"
    return 0
  done
}

password_is_strong() {
  local pass="$1"
  [[ ${#pass} -ge 14 ]] || return 1
  [[ "$pass" =~ [a-z] ]] || return 1
  [[ "$pass" =~ [A-Z] ]] || return 1
  [[ "$pass" =~ [0-9] ]] || return 1
  [[ "$pass" =~ [^a-zA-Z0-9] ]] || return 1
}

allow_weak_password() {
  local mode="${HERMES_PASSWORD_POLICY:-production}"
  [[ "$mode" == "lab" ]] && return 0
  is_truthy "${HERMES_ALLOW_WEAK_PASSWORD:-}" && return 0
  return 1
}

confirm_weak_password_if_interactive() {
  local label="$1" pass="$2" mode="${HERMES_PASSWORD_POLICY:-production}"
  if password_is_strong "$pass"; then
    return 0
  fi
  if allow_weak_password; then
    warn "Weak $label accepted because HERMES_PASSWORD_POLICY=$mode or HERMES_ALLOW_WEAK_PASSWORD is set. Use this only for labs."
    return 0
  fi
  if [[ -t 0 ]]; then
    warn "$label does not meet the production recommendation: >=14 chars with lower/upper/digit/symbol."
    read -r -p "Accept weak $label for a lab/test install? Type 'lab' to continue: " answer
    if [[ "$answer" == "lab" ]]; then
      export HERMES_PASSWORD_POLICY=lab
      warn "Proceeding in lab password mode for this run."
      return 0
    fi
  fi
  fail "Weak $label rejected. Use a stronger value, or set HERMES_PASSWORD_POLICY=lab / HERMES_ALLOW_WEAK_PASSWORD=true for lab systems."
}

htpasswd_apr1() {
  local pass="$1"
  # stdin avoids exposing the plaintext password in the process list.
  printf '%s\n' "$pass" | openssl passwd -apr1 -stdin
}

apply_basic_auth_secret() {
  local user="$1" pass="$2" hash tmpdir
  hash="$(htpasswd_apr1 "$pass")"
  tmpdir="$(mktemp -d)"
  chmod 700 "$tmpdir"
  printf '%s:%s\n' "$user" "$hash" > "$tmpdir/users"
  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-basic-auth-users \
    --from-file=users="$tmpdir/users" \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -rf "$tmpdir"
}

apply_dashboard_auth_secret() {
  local user="$1" pass="$2" tmpdir
  tmpdir="$(mktemp -d)"
  chmod 700 "$tmpdir"
  printf '%s' "$user" > "$tmpdir/username"
  printf '%s' "$pass" > "$tmpdir/password"
  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-dashboard-auth \
    --from-file=username="$tmpdir/username" \
    --from-file=password="$tmpdir/password" \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -rf "$tmpdir"
}

rotate_passwords() {
  local rotate_ingress=1 rotate_dashboard=1 generated=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lab) export HERMES_PASSWORD_POLICY=lab ;;
      --generate) generated=1 ;;
      --skip-ingress) rotate_ingress=0 ;;
      --skip-dashboard) rotate_dashboard=0 ;;
      --help|-h)
        cat <<'EOF'
Usage:
  ./maintain.sh rotate-passwords [--lab] [--generate] [--skip-ingress] [--skip-dashboard]

Password sources, in order:
  1. Environment variables: BASIC_AUTH_PASSWORD / DASHBOARD_AUTH_PASSWORD
  2. Interactive hidden prompt, if stdin is a TTY
  3. --generate for random values

Production policy rejects weak passwords by default. For labs, use --lab or:
  HERMES_PASSWORD_POLICY=lab ./maintain.sh rotate-passwords
EOF
        return 0 ;;
      *) fail "unknown rotate-passwords option: $1" ;;
    esac
    shift
  done

  local basic_user="${BASIC_AUTH_USER:-admin}"
  local dashboard_user="${DASHBOARD_AUTH_USER:-admin}"
  local basic_pass="" dashboard_pass="" generated_file=""
  if [[ "$generated" -eq 1 ]]; then
    generated_file="$(credential_output_file)"
    umask 077
    : > "$generated_file"
  fi

  if [[ "$rotate_ingress" -eq 1 ]]; then
    if [[ "$generated" -eq 1 && -z "${BASIC_AUTH_PASSWORD:-}" ]]; then
      basic_pass="$(rand_hex 18)"
      printf 'BASIC_AUTH_USER=%s
BASIC_AUTH_PASSWORD=%s
' "$basic_user" "$basic_pass" >> "$generated_file"
    else
      basic_pass="$(prompt_secret BASIC_AUTH_PASSWORD 'Ingress BasicAuth password')"
    fi
    confirm_weak_password_if_interactive "Ingress BasicAuth password" "$basic_pass"
    apply_basic_auth_secret "$basic_user" "$basic_pass"
  fi

  if [[ "$rotate_dashboard" -eq 1 ]]; then
    if [[ "$generated" -eq 1 && -z "${DASHBOARD_AUTH_PASSWORD:-}" ]]; then
      dashboard_pass="$(rand_hex 18)"
      printf 'DASHBOARD_AUTH_USER=%s
DASHBOARD_AUTH_PASSWORD=%s
' "$dashboard_user" "$dashboard_pass" >> "$generated_file"
    else
      dashboard_pass="$(prompt_secret DASHBOARD_AUTH_PASSWORD 'Dashboard internal password')"
    fi
    confirm_weak_password_if_interactive "Dashboard internal password" "$dashboard_pass"
    apply_dashboard_auth_secret "$dashboard_user" "$dashboard_pass"
    kubectl -n "$HERMES_NAMESPACE" rollout restart deploy/hermes-dashboard deploy/hermes-webui
    kubectl -n "$HERMES_NAMESPACE" rollout status deploy/hermes-dashboard --timeout=300s
    kubectl -n "$HERMES_NAMESPACE" rollout status deploy/hermes-webui --timeout=300s
  fi

  cat <<EOF
Rotated requested password secrets.
Ingress BasicAuth:   $([[ "$rotate_ingress" -eq 1 ]] && echo "updated for user '$basic_user'" || echo "skipped")
Dashboard/WebUI:    $([[ "$rotate_dashboard" -eq 1 ]] && echo "updated for dashboard user '$dashboard_user'; WebUI password uses the same secret" || echo "skipped")

Plaintext passwords were not printed. Store env-provided/generated values in your password manager.
For lab passwords use --lab or HERMES_PASSWORD_POLICY=lab explicitly.
EOF
  if [[ "$generated" -eq 1 ]]; then
    chmod 600 "$generated_file"
    warn "--generate was used. Generated plaintext values were written to $generated_file (gitignored, mode 600). Move them to your password manager and delete the file."
  fi
}
rotate_browser_token() {
  local token="${BROWSER_TOKEN:-$(rand_hex 32)}"
  local cdp="ws://hermes-browser:3000/chromium?token=${token}"
  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-browser-token --from-literal=token="$token" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-browser-cdp --from-literal=BROWSER_CDP_URL="$cdp" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$HERMES_NAMESPACE" rollout restart deploy/hermes-agent deploy/hermes-dashboard deploy/hermes-webui deploy/hermes-browser
  for d in hermes-agent hermes-dashboard hermes-webui hermes-browser; do
    kubectl -n "$HERMES_NAMESPACE" rollout status "deploy/$d" --timeout=600s
  done
  echo "Rotated Browserless token. CDP endpoint: ws://hermes-browser:3000/chromium?token=<redacted>"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  status) status "$@" ;;
  restart) restart "$@" ;;
  upgrade) upgrade "$@" ;;
  backup) backup "$@" ;;
  restore) restore "$@" ;;
  rotate-passwords) rotate_passwords "$@" ;;
  rotate-browser-token) rotate_browser_token "$@" ;;
  -h|--help|help|"") usage ;;
  *) usage; fail "unknown command: $cmd" ;;
esac
