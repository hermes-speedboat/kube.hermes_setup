# Security notes

## Do not commit secrets

Never commit:

- `hermes.env`
- rendered manifests under `.rendered/`
- backups
- kubeconfigs
- OAuth files such as `auth.json`
- tokens/passwords/API keys

The repository `.gitignore` excludes the common local files, but operators are still responsible for review before commit.

## Browserless/CDP

Browserless is powerful: it can fetch websites from inside your cluster. This repository therefore:

- exposes Browserless as `ClusterIP` only;
- uses a token;
- stores the CDP URL in a Kubernetes Secret;
- injects `BROWSER_CDP_URL` into Hermes containers;
- restricts access using NetworkPolicy.

The expected redacted endpoint is:

```text
ws://hermes-browser:3000/chromium?token=<redacted>
```

Never print the full value in logs or docs.

## Ingress authentication

The setup has two separate auth layers:

| Layer | Scope | Controlled by | Notes |
|---|---|---|---|
| Traefik Ingress BasicAuth | WebUI + Dashboard edge access | `ENABLE_TRAEFIK_BASIC_AUTH=true|false` | Optional, recommended for public exposure |
| Hermes Dashboard BasicAuth | Dashboard application login | `DASHBOARD_AUTH_USER` / `DASHBOARD_AUTH_PASSWORD` | Always configured |

Traefik BasicAuth follows the normal Traefik pattern: an `htpasswd`-style users file stored in a Kubernetes Secret and referenced by a Traefik `Middleware` on the Ingress.

Disable Traefik BasicAuth only if another trusted layer protects the Ingress, for example VPN, Cloudflare Access, corporate SSO, or a private lab network.

## TLS

Terminate TLS at your Ingress controller. This template supports Ingress TLS references but does not manage certificates.

## Backups

Backups include OAuth state and possibly user/session data. Store them encrypted and restrict access.

## Password policy

`maintain.sh rotate-passwords` defaults to production policy:

- minimum 14 characters;
- lower-case, upper-case, digit, and symbol required;
- weak values are rejected unless lab mode is explicit.

For lab systems only:

```bash
./maintain.sh rotate-passwords --lab
# or
HERMES_PASSWORD_POLICY=lab ./maintain.sh rotate-passwords
```

The scripts avoid passing plaintext passwords as command-line arguments to `openssl` or `kubectl`.

## Local generated credential files

`install.sh` writes `.rendered/generated-credentials.txt` with mode `0600` so operators can save generated initial values before deleting the file.

`maintain.sh rotate-passwords --generate` writes `.rendered/rotated-credentials-*.txt` with mode `0600` for the same reason.

`.rendered/` is gitignored. Treat these files as secrets and remove them after storing values in a password manager.


## Default edge authentication

The repo default is `ENABLE_TRAEFIK_BASIC_AUTH=false`. Enable it explicitly for public environments where an additional Traefik edge BasicAuth layer is desired. Dashboard internal authentication remains independent.
