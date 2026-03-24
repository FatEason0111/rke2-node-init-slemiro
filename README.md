# rke2-node-init-slemiro

Automation scripts to prepare a SLE Micro 6.2 node before it joins an RKE2 cluster.

## Included files

- `00-vars.sh`: configurable variables
- `01-init-rke2-node.sh`: main initialization script
- `run.sh`: one-command entrypoint

## What it does

- Sets timezone and hostname
- Updates `/etc/hosts`
- Configures NetworkManager to ignore RKE2/CNI interfaces
- Disables `nm-cloud-setup` when present
- Disables `firewalld` when present
- Writes forwarding sysctl settings
- Prepares PATH and KUBECONFIG for future RKE2 tools
- Installs required packages through `transactional-update`
- Optionally prepares a one-shot post-reboot Rancher registration hook

## Notes

- This repository intentionally contains no real tokens, passwords, or production endpoints.
- `RANCHER_REGISTRATION_COMMAND` in `00-vars.sh` is a placeholder and must be replaced manually if you want post-reboot automatic registration.
- A reboot is required after package installation because SLE Micro uses `transactional-update`.

## Usage

Edit `00-vars.sh` first, then run:

```bash
chmod +x 00-vars.sh 01-init-rke2-node.sh run.sh
bash run.sh
```
