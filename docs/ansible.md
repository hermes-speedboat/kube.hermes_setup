# Persistent Ansible setup

This installer does not need a custom Agent image for a basic Ansible control setup. Use the persistent Python addon venv and the workspace bootstrap examples.

## Install Ansible into the persistent addon venv

Copy the example bootstrap tree and point the installer at the Ansible requirements file:

```bash
cp -a examples/bootstrap ./bootstrap
cat >> hermes.env <<'EOF'
HERMES_ADDON_REQUIREMENTS=./bootstrap/requirements-ansible.txt
HERMES_ADDON_VENV=/opt/data/addon-venv
HERMES_BOOTSTRAP_DIR=./bootstrap
HERMES_BOOTSTRAP_MODE=missing
HERMES_HOME_AS_HOME=true
HERMES_SSH_SETUP=true
EOF
ENV_FILE=./hermes.env ./install.sh
```

The packages are installed into `/opt/data/addon-venv`, which is PVC-backed and survives Pod recreation. The example Ansible project is copied to:

```text
/workspace/ansible/
```

## Verify

```bash
kubectl -n <namespace> exec deploy/hermes-agent -- ansible --version
kubectl -n <namespace> exec deploy/hermes-agent -- sh -lc 'cd /workspace/ansible && ansible-inventory --list'
kubectl -n <namespace> exec deploy/hermes-agent -- sh -lc 'cd /workspace/ansible && ansible-playbook playbooks/ping-local.yml'
```

If an interactive shell resets `PATH`, use:

```bash
export PATH=/opt/data/addon-venv/bin:$PATH
```

or call `/opt/data/addon-venv/bin/ansible-playbook` explicitly.

## SSH and persistence

The Agent HOME/SSH feature sets `HOME=/opt/data` and prepares `/opt/data/.ssh`. With `HERMES_SSH_SETUP=true`, the init job creates `/opt/data/.ssh/id_ed25519` only if it is missing. Install the public key on managed hosts:

```bash
kubectl -n <namespace> exec deploy/hermes-agent -- cat /opt/data/.ssh/id_ed25519.pub
```

Keep host key checking enabled. Maintain `/opt/data/.ssh/known_hosts` or use reviewed per-host `accept-new` entries in `/opt/data/.ssh/config`; do not set global `StrictHostKeyChecking=no`.

## Suggested layout

```text
/workspace/ansible/                  # playbooks, inventories, group_vars
/opt/data/ansible/roles              # persistent roles outside the repo/workspace
/opt/data/ansible/collections        # persistent collections
/opt/data/ansible/tmp                # local Ansible temp
/opt/data/ansible/cp                 # SSH control path dir
/opt/data/.ssh                       # persistent SSH keys/config/known_hosts
```
