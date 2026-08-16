#!/usr/bin/env bash
set -euo pipefail

alias_name="${1:-hostinger-vps}"
echo "Testing non-interactive key authentication to $alias_name"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$alias_name" \
  'printf "user=%s\nhost=%s\nkernel=%s\n" "$(id -un)" "$(hostname)" "$(uname -sr)"; uptime'
echo "PASS: SSH key access to $alias_name"
