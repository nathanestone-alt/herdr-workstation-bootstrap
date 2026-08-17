#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
payload="$repo_root/payload"

if [[ ! -d "$payload" ]]; then
  echo "No payload directory found. Export and review it on the Surface first." >&2
  exit 2
fi

copy_tree() {
  local source="$1"
  local destination="$2"
  if [[ -d "$source" ]]; then
    mkdir -p "$destination"
    cp -a "$source"/. "$destination"/
  fi
}

if [[ -d "$payload/agents-skills/herdr-coordination" ]]; then
  if grep -RqsE 'C:\\|USERPROFILE|-WindowStyle|@echo off|\.cmd\b' "$payload/agents-skills/herdr-coordination"; then
    echo 'BLOCKED: herdr-coordination still contains Windows-specific behavior.' >&2
    echo 'Port it and run its regression suite under native Ubuntu pwsh before installing the agents skill payload.' >&2
    exit 30
  fi
fi

copy_tree "$payload/agents-skills" "$HOME/.agents/skills"
copy_tree "$payload/claude-skills" "$HOME/.claude/skills"
echo 'Skill payload copied after Linux portability preflight. Run every included regression suite before enabling coordination.'
