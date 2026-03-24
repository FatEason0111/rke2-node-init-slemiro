#!/usr/bin/env bash
set -euo pipefail

############################################################
# Basic node settings
############################################################
export NODE_HOSTNAME="rke2-cp-01"
export NODE_IP="192.168.202.151"
export TIMEZONE="Asia/Shanghai"

# Whether reboot automatically after transactional-update
export DO_REBOOT="false"

############################################################
# Package behavior
############################################################
# If kernel supports AppArmor, RKE2 recommends AppArmor tools.
# On some newer SUSE repos, apparmor-parser may not exist as a package name,
# so this script treats it as optional and auto-detects package name when possible.
export INSTALL_OPTIONAL_APPARMOR_TOOLS="true"

############################################################
# Optional: continue automatically after reboot
############################################################
# If true, the script will create a one-shot systemd service that runs once
# after reboot and executes a user-provided Rancher registration command.
export AUTO_CONTINUE_AFTER_REBOOT="false"
export POST_REBOOT_DELAY_SECONDS="15"

# If true, and AUTO_CONTINUE_AFTER_REBOOT=true, the registration command below
# will run once after reboot.
export RUN_RANCHER_REGISTRATION_COMMAND="false"

# Paste the full Rancher UI generated registration command below if needed.
# Keep it empty by default to avoid storing sensitive data in the repository.
export RANCHER_REGISTRATION_COMMAND=""
