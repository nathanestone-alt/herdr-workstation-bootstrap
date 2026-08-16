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

copy_tree "$payload/agents-skills" "$HOME/.agents/skills"
copy_tree "$payload/claude-skills" "$HOME/.claude/skills"
echo 'Skill payload copied. Review Windows paths and validate each skill before enabling it.'

