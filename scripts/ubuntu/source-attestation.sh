#!/usr/bin/env bash

# Shared source-attestation primitives.  This file is sourced only after the
# caller has arranged for the exact committed copy to be available.  The
# functions deliberately do not use Git's worktree diff machinery: that
# machinery is allowed to consult attributes and clean filters.

attestation_git_bin='/usr/bin/git'
attestation_sha256_bin='/usr/bin/sha256sum'
attestation_realpath_bin='/usr/bin/realpath'
attestation_find_bin='/usr/bin/find'
attestation_mktemp_bin='/usr/bin/mktemp'
attestation_mkdir_bin='/usr/bin/mkdir'
attestation_chmod_bin='/usr/bin/chmod'
attestation_stat_bin='/usr/bin/stat'
attestation_awk_bin='/usr/bin/awk'
attestation_rm_bin='/usr/bin/rm'
attestation_readlink_bin='/usr/bin/readlink'
attestation_head_bin='/usr/bin/head'
attestation_sort_bin='/usr/bin/sort'
attestation_trusted_path='/usr/sbin:/usr/bin:/sbin:/bin'

attestation_snapshot_dir=''
attestation_snapshot_manifest=''
attestation_snapshot_commit=''
attestation_snapshot_url=''
attestation_snapshot_manifest_sha256=''

attestation_hash_file() {
  local path="$1"
  [[ -f "$path" && ! -L "$path" ]] || return 1
  "$attestation_sha256_bin" -- "$path" | "$attestation_awk_bin" '{print $1}'
}

attestation_reject_git_environment() {
  local variable
  while IFS= read -r variable; do
    case "$variable" in
      GIT_*)
        echo "Git environment override is not permitted: $variable" >&2
        return 1
        ;;
    esac
  done < <(compgen -e)
}

attestation_assert_canonical_git() {
  local resolved mode
  [[ -f "$attestation_git_bin" && ! -L "$attestation_git_bin" ]] || {
    echo "Trusted Git is not a regular file: $attestation_git_bin" >&2
    return 1
  }
  resolved="$($attestation_realpath_bin -e -- "$attestation_git_bin" 2>/dev/null || true)"
  [[ "$resolved" == "$attestation_git_bin" ]] || {
    echo "Trusted Git identity is not canonical: $attestation_git_bin -> $resolved" >&2
    return 1
  }
  mode="$($attestation_stat_bin -c '%a' -- "$attestation_git_bin" 2>/dev/null || true)"
  [[ "$mode" =~ ^[0-7]+$ && $((8#$mode & 022)) == 0 ]] || {
    echo "Trusted Git is writable by group or other users: $attestation_git_bin" >&2
    return 1
  }
}

attestation_git() {
  local source_path="$1"
  shift
  # env -i removes every GIT_* variable, including variables added after this
  # helper's explicit deny-list.  The only config sources left are /dev/null
  # and the repository-local file, which is never used for a filter-bearing
  # operation and is checked for dangerous keys before this wrapper is used.
  /usr/bin/env -i \
    HOME=/nonexistent \
    PATH="$attestation_trusted_path" \
    LC_ALL=C \
    TZ=UTC \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_CONFIG_COUNT=0 \
    "$attestation_git_bin" \
    --no-replace-objects \
    -C "$source_path" \
    --git-dir=.git \
    --work-tree=. \
    -c core.attributesfile=/dev/null \
    -c core.excludesfile=/dev/null \
    -c core.hooksPath=/dev/null \
    -c core.filemode=true \
    -c core.ignoreCase=false \
    "$@"
}

attestation_git_config() {
  local source_path="$1"
  shift
  /usr/bin/env -i \
    HOME=/nonexistent \
    PATH="$attestation_trusted_path" \
    LC_ALL=C \
    TZ=UTC \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_CONFIG_COUNT=0 \
    "$attestation_git_bin" \
    --no-replace-objects \
    -C "$source_path" \
    --git-dir=.git \
    --work-tree=. \
    "$@"
}

attestation_reject_symlink_components() {
  local path="$1"
  local current='/'
  local component
  local -a components
  [[ "$path" == /* ]] || return 1
  IFS='/' read -r -a components <<< "${path#/}"
  for component in "${components[@]}"; do
    [[ -z "$component" || "$component" == '.' ]] && continue
    [[ "$component" != '..' && "$component" != *'/'* ]] || return 1
    current="$current/$component"
    [[ ! -L "$current" ]] || return 1
  done
}

attestation_valid_relative_path() {
  local path="$1"
  local component
  local -a components
  [[ -n "$path" && "$path" != /* && "$path" != *$'\t'* && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
  IFS='/' read -r -a components <<< "$path"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != '.' && "$component" != '..' ]] || return 1
  done
}

attestation_config_is_safe() {
  local source_path="$1"
  local dangerous
  local sparse_checkout
  local sparse_index
  dangerous="$(attestation_git_config "$source_path" config --local --no-includes --name-only --get-regexp \
    '^(include|filter\.|diff\..*\.textconv$|merge\..*\.driver$|credential\.|url\..*\.insteadOf$|core\.(attributesfile|excludesfile|fsmonitor|hooksPath|worktree|alternateRefsCommand|askPass|gitProxy|sshCommand)$|extensions\.|remote\..*\.(promisor|partialclonefilter|uploadpack|receivepack)$)' 2>/dev/null || true)"
  [[ -z "$dangerous" ]] || {
    echo "Repository-local Git configuration is not permitted for attestation: $dangerous" >&2
    return 1
  }
  sparse_checkout="$(attestation_git_config "$source_path" config --local --no-includes --bool --get core.sparseCheckout 2>/dev/null || true)"
  [[ "$sparse_checkout" != true ]] || {
    echo "Repository-local sparse checkout is not permitted: $source_path" >&2
    return 1
  }
  sparse_index="$(attestation_git_config "$source_path" config --local --no-includes --bool --get index.sparse 2>/dev/null || true)"
  [[ "$sparse_index" != true ]] || {
    echo "Repository-local sparse index is not permitted: $source_path" >&2
    return 1
  }
  [[ ! -e "$source_path/.git/info/sparse-checkout" ]] || {
    echo "Sparse-checkout metadata is not permitted: $source_path" >&2
    return 1
  }
  [[ ! -e "$source_path/.git/shallow" ]] || {
    echo "Shallow repositories are not permitted: $source_path" >&2
    return 1
  }
  [[ ! -e "$source_path/.git/commondir" ]] || {
    echo "External Git common directories are not permitted: $source_path" >&2
    return 1
  }
  [[ ! -e "$source_path/.git/objects/info/alternates" ]] || {
    echo "External Git alternates are not permitted: $source_path" >&2
    return 1
  }
  [[ ! -e "$source_path/.git/objects/info/http-alternates" ]] || {
    echo "External Git HTTP alternates are not permitted: $source_path" >&2
    return 1
  }
  [[ -z "$("$attestation_find_bin" -P "$source_path/.git" -maxdepth 1 -name 'sharedindex.*' -print -quit 2>/dev/null || true)" ]] || {
    echo "Git split-index storage is not permitted: $source_path" >&2
    return 1
  }
  [[ "$(attestation_git_config "$source_path" config --local --no-includes --bool --get core.filemode 2>/dev/null || true)" != false ]] || {
    echo "Repository-local core.filemode=false is not permitted: $source_path" >&2
    return 1
  }
  [[ "$(attestation_git_config "$source_path" config --local --no-includes --bool --get core.bare 2>/dev/null || true)" != true ]] || {
    echo "Repository-local core.bare=true is not permitted: $source_path" >&2
    return 1
  }
  [[ "$(attestation_git_config "$source_path" config --local --no-includes --int --get core.repositoryformatversion 2>/dev/null || true)" == 0 ]] || {
    echo "Unsupported Git repository format: $source_path" >&2
    return 1
  }
  [[ "$(attestation_git_config "$source_path" config --local --no-includes --bool --get core.ignorecase 2>/dev/null || true)" != true ]] || {
    echo "Repository-local core.ignoreCase=true is not permitted: $source_path" >&2
    return 1
  }
}

attestation_snapshot_cleanup() {
  local path="${1:-${attestation_snapshot_dir:-}}"
  [[ -n "$path" && "$path" == /tmp/* && -d "$path" ]] || return 0
  "$attestation_rm_bin" -rf -- "$path"
}

attestation_snapshot_mode() {
  local git_mode="$1"
  case "$git_mode" in
    100644) printf '0644' ;;
    100755) printf '0755' ;;
    *) return 1 ;;
  esac
}

attestation_live_mode_matches_snapshot() {
  local actual_mode="$1"
  local expected_mode="$2"
  [[ "$actual_mode" =~ ^[0-7]+$ ]] || return 1
  if [[ "$expected_mode" == 0755 ]]; then
    (( (8#$actual_mode & 0111) != 0 ))
  else
    (( (8#$actual_mode & 0111) == 0 ))
  fi
}

attestation_add_expected_directories() {
  local path="$1"
  local current='.'
  local component
  local -a components
  IFS='/' read -r -a components <<< "$path"
  for component in "${components[@]}"; do
    current="$current/$component"
    current="${current#./}"
    attestation_expected_dirs["$current"]='1'
  done
}

attestation_compare_live_checkout() {
  local source_path="$1"
  local snapshot_path="$2"
  local relative full expected_mode actual_mode actual_sha
  local entry

  while IFS= read -r -d '' full; do
    relative="${full#"$source_path"/}"
    [[ "$relative" != .git && "$relative" != .git/* ]] || continue
    case "/$relative/" in
      */.git/*)
        echo "Git checkout contains nested repository metadata: $relative" >&2
        return 1
        ;;
    esac
    attestation_valid_relative_path "$relative" || {
      echo "Git checkout contains an unsafe path: $relative" >&2
      return 1
    }
    if [[ -L "$full" ]]; then
      echo "Git checkout contains a symlink: $relative" >&2
      return 1
    elif [[ -d "$full" ]]; then
      [[ -n "${attestation_expected_dirs[$relative]+x}" ]] || {
        echo "Git checkout contains an untracked or empty directory: $relative" >&2
        return 1
      }
    elif [[ -f "$full" ]]; then
      expected_mode="${attestation_expected_mode[$relative]:-}"
      [[ -n "$expected_mode" ]] || {
        echo "Git checkout contains an untracked or ignored path: $relative" >&2
        return 1
      }
      actual_mode="$($attestation_stat_bin -c '%a' -- "$full" 2>/dev/null || true)"
      attestation_live_mode_matches_snapshot "$actual_mode" "$expected_mode" || {
        echo "Git checkout file mode differs from the committed tree: $relative" >&2
        return 1
      }
      actual_sha="$(attestation_hash_file "$full" 2>/dev/null || true)"
      [[ "$actual_sha" == "${attestation_expected_sha[$relative]:-}" ]] || {
        echo "Git checkout file content differs from the committed blob: $relative" >&2
        return 1
      }
    else
      echo "Git checkout contains an unsupported filesystem entry: $relative" >&2
      return 1
    fi
  done < <("$attestation_find_bin" -P "$source_path" -mindepth 1 \
    \( -path "$source_path/.git" -o -path "$source_path/.git/*" \) -prune -o -print0)

  for relative in "${!attestation_expected_sha[@]}"; do
    full="$source_path/$relative"
    [[ -f "$full" && ! -L "$full" ]] || {
      echo "Committed source file is missing from the checkout: $relative" >&2
      return 1
    }
    actual_mode="$($attestation_stat_bin -c '%a' -- "$full" 2>/dev/null || true)"
    attestation_live_mode_matches_snapshot "$actual_mode" "${attestation_expected_mode[$relative]}" || return 1
    actual_sha="$(attestation_hash_file "$full" 2>/dev/null || true)"
    [[ "$actual_sha" == "${attestation_expected_sha[$relative]:-}" ]] || return 1
  done
}

attestation_create_git_snapshot() {
  local source_path="${1:-}"
  local expected_url="${2:-}"
  local expected_ref="${3:-}"
  local require_live="${4:-true}"
  local canonical_source_path git_dir git_toplevel actual_url actual_ref
  local tree_file index_file stage_file snapshot_path manifest_path
  local record meta path mode type oid digest snapshot_mode
  local index_meta index_path index_mode index_oid index_stage
  local config_file git_metadata_entry
  local file_count=0

  attestation_snapshot_dir=''
  attestation_snapshot_manifest=''
  attestation_snapshot_commit=''
  attestation_snapshot_url=''
  attestation_snapshot_manifest_sha256=''
  attestation_reject_git_environment || return 1
  attestation_assert_canonical_git || return 1
  [[ "$source_path" == /* && -d "$source_path" && ! -L "$source_path" ]] || {
    echo "Git checkout is not an absolute real directory: $source_path" >&2
    return 1
  }
  canonical_source_path="$($attestation_realpath_bin -e -- "$source_path" 2>/dev/null || true)"
  [[ -n "$canonical_source_path" && "$canonical_source_path" == "$source_path" ]] || {
    echo "Git checkout path is not lexically canonical: $source_path" >&2
    return 1
  }
  attestation_reject_symlink_components "$canonical_source_path" || {
    echo "Git checkout contains a symlinked path component: $source_path" >&2
    return 1
  }
  [[ -d "$canonical_source_path/.git" && ! -L "$canonical_source_path/.git" ]] || {
    echo "Git checkout metadata is missing or unsafe: $source_path" >&2
    return 1
  }
  git_dir="$canonical_source_path/.git"
  [[ -d "$git_dir/objects" && ! -L "$git_dir/objects" && -d "$git_dir/refs" && ! -L "$git_dir/refs" ]] || {
    echo "Git checkout object or ref storage is missing: $source_path" >&2
    return 1
  }
  git_metadata_entry="$("$attestation_find_bin" -P "$git_dir" -mindepth 1 \
    \( -type l -o \( ! -type f ! -type d \) \) -print -quit 2>/dev/null || true)"
  [[ -z "$git_metadata_entry" ]] || {
    echo "Git metadata contains a symlink: $git_metadata_entry" >&2
    return 1
  }
  config_file="$git_dir/config"
  [[ -f "$config_file" && ! -L "$config_file" ]] || {
    echo "Git checkout config is missing or not a regular file: $source_path" >&2
    return 1
  }
  attestation_config_is_safe "$canonical_source_path" || return 1

  git_toplevel="$(attestation_git "$canonical_source_path" rev-parse --show-toplevel 2>/dev/null || true)"
  git_toplevel="$($attestation_realpath_bin -e -- "$git_toplevel" 2>/dev/null || true)"
  [[ "$git_toplevel" == "$canonical_source_path" ]] || {
    echo "Git checkout top-level path is not canonical: $source_path" >&2
    return 1
  }
  [[ "$(attestation_git "$canonical_source_path" rev-parse --absolute-git-dir 2>/dev/null || true)" == "$git_dir" ]] || {
    echo "Git checkout uses an external common Git directory: $source_path" >&2
    return 1
  }
  [[ "$(attestation_git "$canonical_source_path" rev-parse --is-inside-work-tree 2>/dev/null || true)" == true ]] || {
    echo "Git checkout is not a worktree: $source_path" >&2
    return 1
  }
  [[ "$(attestation_git "$canonical_source_path" rev-parse --is-bare-repository 2>/dev/null || true)" == false ]] || {
    echo "Git checkout is bare: $source_path" >&2
    return 1
  }
  [[ "$(attestation_git "$canonical_source_path" rev-parse --is-shallow-repository 2>/dev/null || true)" == false ]] || {
    echo "Git checkout is shallow: $source_path" >&2
    return 1
  }

  actual_url="$(attestation_git_config "$canonical_source_path" config --local --no-includes --get-all remote.origin.url 2>/dev/null || true)"
  [[ "$actual_url" != *$'\n'* && "$actual_url" != *$'\r'* && "$actual_url" != *$'\t'* ]] || {
    echo "Git checkout origin contains manifest-unsafe control characters: $source_path" >&2
    return 1
  }
  if [[ -n "$expected_url" && "$actual_url" != "$expected_url" ]]; then
    echo "Git checkout origin differs from the locked URL: $actual_url" >&2
    return 1
  fi
  if [[ "$require_live" == true ]]; then
    actual_ref="$(attestation_git "$canonical_source_path" rev-parse --verify HEAD^{commit} 2>/dev/null || true)"
  else
    actual_ref="$(attestation_git "$canonical_source_path" rev-parse --verify "$expected_ref^{commit}" 2>/dev/null || true)"
  fi
  [[ "$actual_ref" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Git checkout HEAD is not a full commit: $source_path" >&2
    return 1
  }
  if [[ -n "$expected_ref" && "$actual_ref" != "$expected_ref" ]]; then
    echo "Git checkout does not match the locked commit: $actual_ref" >&2
    return 1
  fi

  tree_file="$($attestation_mktemp_bin)"
  index_file="$($attestation_mktemp_bin)"
  stage_file="$($attestation_mktemp_bin)"
  snapshot_path="$($attestation_mktemp_bin -d /tmp/herdr-source-snapshot.XXXXXX)"
  manifest_path="$snapshot_path/.source-attestation"
  attestation_snapshot_dir="$snapshot_path"
  attestation_snapshot_manifest="$manifest_path"
  if ! attestation_git "$canonical_source_path" ls-tree --full-tree -r -z "$actual_ref" > "$tree_file"; then
    echo "Git committed tree cannot be read: $source_path" >&2
    "$attestation_rm_bin" -f -- "$tree_file" "$index_file" "$stage_file"
    attestation_snapshot_cleanup
    return 1
  fi

  declare -A attestation_expected_mode=()
  declare -A attestation_expected_git_mode=()
  declare -A attestation_expected_oid=()
  declare -A attestation_expected_sha=()
  declare -A attestation_expected_dirs=()
  attestation_expected_dirs['.']='1'
  while IFS= read -r -d '' record; do
    meta="${record%%$'\t'*}"
    path="${record#*$'\t'}"
    read -r mode type oid <<< "$meta"
    attestation_valid_relative_path "$path" || {
      echo "Committed Git tree contains an unsafe path: $path" >&2
      "$attestation_rm_bin" -f -- "$tree_file" "$index_file" "$stage_file"
      attestation_snapshot_cleanup
      return 1
    }
    case "/$path/" in
      */.git/*)
        echo "Committed Git tree contains repository metadata: $path" >&2
        "$attestation_rm_bin" -f -- "$tree_file" "$index_file" "$stage_file"
        attestation_snapshot_cleanup
        return 1
        ;;
    esac
    [[ "$type" == blob && ( "$mode" == 100644 || "$mode" == 100755 ) ]] || {
      echo "Committed Git tree contains an unsupported mode or object: $path" >&2
      "$attestation_rm_bin" -f -- "$tree_file" "$index_file" "$stage_file"
      attestation_snapshot_cleanup
      return 1
    }
    snapshot_mode="$(attestation_snapshot_mode "$mode")" || return 1
    "$attestation_git_bin" --no-replace-objects --git-dir="$git_dir" -c core.attributesfile=/dev/null \
      -c core.hooksPath=/dev/null cat-file -e "$oid^{blob}" 2>/dev/null || {
      echo "Committed Git blob is missing: $path" >&2
      "$attestation_rm_bin" -f -- "$tree_file" "$index_file" "$stage_file"
      attestation_snapshot_cleanup
      return 1
    }
    "$attestation_mkdir_bin" -p -- "$snapshot_path/$(dirname -- "$path")"
    if ! /usr/bin/env -i HOME=/nonexistent PATH="$attestation_trusted_path" LC_ALL=C TZ=UTC \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_COUNT=0 \
      "$attestation_git_bin" --no-replace-objects --git-dir="$git_dir" cat-file blob "$oid" > "$snapshot_path/$path"; then
      echo "Committed Git blob cannot be materialized: $path" >&2
      "$attestation_rm_bin" -f -- "$tree_file" "$index_file" "$stage_file"
      attestation_snapshot_cleanup
      return 1
    fi
    "$attestation_chmod_bin" "$snapshot_mode" -- "$snapshot_path/$path"
    digest="$(attestation_hash_file "$snapshot_path/$path")" || return 1
    attestation_expected_mode["$path"]="$snapshot_mode"
    attestation_expected_git_mode["$path"]="$mode"
    attestation_expected_oid["$path"]="$oid"
    attestation_expected_sha["$path"]="$digest"
    attestation_add_expected_directories "$path"
    ((file_count += 1))
  done < "$tree_file"
  ((file_count > 0)) || {
    echo "Committed Git tree is empty: $source_path" >&2
    "$attestation_rm_bin" -f -- "$tree_file" "$index_file" "$stage_file"
    attestation_snapshot_cleanup
    return 1
  }

  if [[ "$require_live" == true ]]; then
    [[ -f "$git_dir/index" && ! -L "$git_dir/index" ]] || {
      echo "Git checkout index is missing or unsafe: $source_path" >&2
      return 1
    }
    if ! attestation_git "$canonical_source_path" ls-files --unmerged -z > "$stage_file"; then
      echo "Git index unmerged-state query failed: $source_path" >&2
      return 1
    fi
    [[ ! -s "$stage_file" ]] || {
      echo "Git checkout has staged or unmerged entries: $source_path" >&2
      return 1
    }
    if ! attestation_git "$canonical_source_path" ls-files -v -z > "$index_file"; then
      echo "Git index flag query failed: $source_path" >&2
      return 1
    fi
    while IFS= read -r -d '' index_path; do
      [[ "${index_path:0:1}" == H ]] || {
        echo "Git index contains an assume-unchanged, skip-worktree, or non-normal flag: $source_path" >&2
        return 1
      }
      index_path="${index_path:2}"
      [[ -n "${attestation_expected_oid[$index_path]+x}" ]] || {
        echo "Git index contains an unexpected path: $index_path" >&2
        return 1
      }
    done < "$index_file"
    if ! attestation_git "$canonical_source_path" ls-files --stage -z > "$stage_file"; then
      echo "Git index content query failed: $source_path" >&2
      return 1
    fi
    declare -A attestation_seen_index=()
    while IFS= read -r -d '' record; do
      index_meta="${record%%$'\t'*}"
      index_path="${record#*$'\t'}"
      read -r index_mode index_oid index_stage <<< "$index_meta"
      [[ "$index_stage" == 0 && -n "${attestation_expected_oid[$index_path]+x}" ]] || {
        echo "Git index differs from the committed tree: $index_path" >&2
        return 1
      }
      [[ "$index_mode" == "${attestation_expected_git_mode[$index_path]}" ]] || {
        echo "Git index mode differs from the committed tree: $index_path" >&2
        return 1
      }
      [[ "$index_oid" == "${attestation_expected_oid[$index_path]}" ]] || {
        echo "Git index blob differs from the committed tree: $index_path" >&2
        return 1
      }
      attestation_seen_index["$index_path"]='1'
    done < "$stage_file"
    [[ "${#attestation_seen_index[@]}" == "${#attestation_expected_oid[@]}" ]] || {
      echo "Git index does not contain exactly the committed paths: $source_path" >&2
      return 1
    }

    attestation_compare_live_checkout "$canonical_source_path" "$snapshot_path" || return 1
  fi

  while IFS= read -r -d '' entry; do
    [[ "$entry" == "$snapshot_path" ]] && continue
    "$attestation_chmod_bin" a-w -- "$entry"
  done < <("$attestation_find_bin" -P "$snapshot_path" -mindepth 1 -type f ! -name '.source-attestation' -print0)
  {
    printf 'herdr-source-snapshot-v2\n'
    printf 'commit=%s\n' "$actual_ref"
    printf 'repository_url=%s\n' "$actual_url"
    for path in "${!attestation_expected_oid[@]}"; do
      printf 'F\t%s\t%s\t%s\t%s\n' \
        "$($attestation_stat_bin -c '%a' -- "$snapshot_path/$path")" "${attestation_expected_oid[$path]}" \
        "${attestation_expected_sha[$path]}" "$path"
    done | "$attestation_awk_bin" 'BEGIN { OFS="\t" } /^F\t/ { print }' | LC_ALL=C "$attestation_sort_bin"
  } > "$manifest_path"
  "$attestation_chmod_bin" 0444 -- "$manifest_path"
  while IFS= read -r -d '' entry; do
    "$attestation_chmod_bin" 0555 -- "$entry"
  done < <("$attestation_find_bin" -P "$snapshot_path" -type d -print0)
  "$attestation_rm_bin" -f -- "$tree_file" "$index_file" "$stage_file"
  attestation_snapshot_commit="$actual_ref"
  attestation_snapshot_url="$actual_url"
  attestation_snapshot_manifest_sha256="$(attestation_hash_file "$manifest_path")" || return 1
}

attestation_manifest_value() {
  local manifest="$1"
  local key="$2"
  "$attestation_awk_bin" -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); found++ } END { exit(found == 1 ? 0 : 1) }' "$manifest"
}

attestation_snapshot_file_digest() {
  local manifest="$1"
  local path="$2"
  "$attestation_awk_bin" -F '\t' -v wanted="$path" \
    '$1 == "F" && $5 == wanted { print $4; found++ } END { exit(found == 1 ? 0 : 1) }' "$manifest"
}

attestation_verify_snapshot() {
  local root="$1"
  local manifest="$2"
  local expected_commit="${3:-}"
  local expected_url="${4:-}"
  local line mode oid digest path full actual_mode actual_digest relative
  attestation_reject_symlink_components "$root" || return 1
  [[ "$root" == /* && -d "$root" && ! -L "$root" ]] || return 1
  [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
  [[ "$($attestation_head_bin -n 1 -- "$manifest")" == herdr-source-snapshot-v2 ]] || return 1
  attestation_snapshot_commit="$(attestation_manifest_value "$manifest" commit)" || return 1
  attestation_snapshot_url="$(attestation_manifest_value "$manifest" repository_url)" || return 1
  [[ "$attestation_snapshot_commit" =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ -z "$expected_commit" || "$attestation_snapshot_commit" == "$expected_commit" ]] || return 1
  [[ -z "$expected_url" || "$attestation_snapshot_url" == "$expected_url" ]] || return 1
  declare -A verify_mode=()
  declare -A verify_sha=()
  declare -A verify_oid=()
  declare -A verify_dirs=()
  verify_dirs['.']='1'
  while IFS= read -r line; do
    [[ "$line" == F$'\t'* ]] || continue
    IFS=$'\t' read -r _ mode oid digest path <<< "$line"
    attestation_valid_relative_path "$path" || return 1
    [[ "$mode" == 444 || "$mode" == 555 || "$mode" == 644 || "$mode" == 755 || "$mode" == 0444 || "$mode" == 0555 || "$mode" == 0644 || "$mode" == 0755 ]] || return 1
    [[ "$oid" =~ ^[0-9a-f]{40}$ && "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    verify_mode["$path"]="$mode"
    verify_oid["$path"]="$oid"
    verify_sha["$path"]="$digest"
    local current='.' component
    local -a components
    IFS='/' read -r -a components <<< "$path"
    for component in "${components[@]}"; do
      current="$current/$component"
      current="${current#./}"
      verify_dirs["$current"]='1'
    done
  done < "$manifest"
  [[ "${#verify_sha[@]}" -gt 0 ]] || return 1
  while IFS= read -r -d '' full; do
    relative="${full#"$root"/}"
    [[ "$relative" == .source-attestation ]] && continue
    attestation_valid_relative_path "$relative" || return 1
    if [[ -L "$full" ]]; then return 1
    elif [[ -d "$full" ]]; then
      [[ -n "${verify_dirs[$relative]+x}" ]] || return 1
    elif [[ -f "$full" ]]; then
      [[ -n "${verify_sha[$relative]+x}" ]] || return 1
      actual_mode="$($attestation_stat_bin -c '%a' -- "$full")"
      [[ "$actual_mode" == "${verify_mode[$relative]#0}" ]] || return 1
      actual_digest="$(attestation_hash_file "$full")"
      [[ "$actual_digest" == "${verify_sha[$relative]}" ]] || return 1
    else
      return 1
    fi
  done < <("$attestation_find_bin" -P "$root" -mindepth 1 -print0)
  for path in "${!verify_sha[@]}"; do
    full="$root/$path"
    [[ -f "$full" && ! -L "$full" ]] || return 1
    actual_digest="$(attestation_hash_file "$full")"
    [[ "$actual_digest" == "${verify_sha[$path]}" ]] || return 1
  done
  attestation_snapshot_manifest="$manifest"
  attestation_snapshot_manifest_sha256="$(attestation_hash_file "$manifest")" || return 1
}

attestation_build_payload_manifest() {
  local root="$1"
  local manifest="$2"
  local full relative mode digest entries
  [[ -d "$root" && ! -L "$root" ]] || return 1
  entries="$($attestation_mktemp_bin)"
  while IFS= read -r -d '' full; do
    relative="${full#"$root"/}"
    [[ "$relative" != .payload-manifest ]] || continue
    attestation_valid_relative_path "$relative" || { "$attestation_rm_bin" -f -- "$entries"; return 1; }
    [[ -f "$full" && ! -L "$full" ]] || { "$attestation_rm_bin" -f -- "$entries"; return 1; }
    mode="$($attestation_stat_bin -c '%a' -- "$full")"
    [[ "$mode" == 444 || "$mode" == 555 || "$mode" == 644 || "$mode" == 755 ]] || { "$attestation_rm_bin" -f -- "$entries"; return 1; }
    digest="$(attestation_hash_file "$full")" || { "$attestation_rm_bin" -f -- "$entries"; return 1; }
    printf 'F\t%s\t%s\t%s\n' "$mode" "$digest" "$relative" >> "$entries"
  done < <("$attestation_find_bin" -P "$root" -mindepth 1 -type f -print0)
  {
    printf 'herdr-payload-manifest-v1\n'
    "$attestation_sort_bin" "$entries"
  } > "$manifest"
  "$attestation_rm_bin" -f -- "$entries"
  "$attestation_chmod_bin" 0444 -- "$manifest"
}

attestation_verify_payload_manifest() {
  local root="$1"
  local manifest="$2"
  local expected_hash="${3:-}"
  local line mode digest path full relative actual_mode actual_digest
  attestation_reject_symlink_components "$root" || return 1
  [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
  [[ -z "$expected_hash" || "$(attestation_hash_file "$manifest")" == "$expected_hash" ]] || return 1
  [[ "$($attestation_head_bin -n 1 -- "$manifest")" == herdr-payload-manifest-v1 ]] || return 1
  declare -A payload_mode=()
  declare -A payload_sha=()
  declare -A payload_dirs=()
  payload_dirs['.']='1'
  while IFS= read -r line; do
    [[ "$line" == F$'\t'* ]] || continue
    IFS=$'\t' read -r _ mode digest path <<< "$line"
    attestation_valid_relative_path "$path" || return 1
    [[ "$mode" =~ ^(444|555|644|755)$ && "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    payload_mode["$path"]="$mode"
    payload_sha["$path"]="$digest"
    local current='.' component
    local -a components
    IFS='/' read -r -a components <<< "$path"
    for component in "${components[@]}"; do
      current="$current/$component"
      current="${current#./}"
      payload_dirs["$current"]='1'
    done
  done < "$manifest"
  [[ "${#payload_sha[@]}" -gt 0 ]] || return 1
  while IFS= read -r -d '' full; do
    relative="${full#"$root"/}"
    [[ "$relative" != .payload-manifest ]] || continue
    attestation_valid_relative_path "$relative" || return 1
    if [[ -L "$full" ]]; then return 1
    elif [[ -d "$full" ]]; then
      [[ -n "${payload_dirs[$relative]+x}" ]] || return 1
    elif [[ -f "$full" ]]; then
      [[ -n "${payload_sha[$relative]+x}" ]] || return 1
      actual_mode="$($attestation_stat_bin -c '%a' -- "$full")"
      [[ "$actual_mode" == "${payload_mode[$relative]}" ]] || return 1
      actual_digest="$(attestation_hash_file "$full")"
      [[ "$actual_digest" == "${payload_sha[$relative]}" ]] || return 1
    else
      return 1
    fi
  done < <("$attestation_find_bin" -P "$root" -mindepth 1 -print0)
  for path in "${!payload_sha[@]}"; do
    full="$root/$path"
    [[ -f "$full" && ! -L "$full" ]] || return 1
  done
}

attestation_canonical_cargo() {
  local user_home="$1"
  local cargo_path="$user_home/.cargo/bin/cargo"
  local resolved
  [[ "$user_home" == /* && "$user_home" != / ]] || return 1
  [[ -x "$cargo_path" ]] || return 1
  resolved="$($attestation_realpath_bin -e -- "$cargo_path" 2>/dev/null || true)"
  [[ -n "$resolved" && -f "$resolved" && -x "$resolved" ]] || return 1
  [[ "$resolved" == "$user_home/.cargo/"* || "$resolved" == "$user_home/.rustup/"* ]] || {
    echo "Cargo executable resolves outside the approved toolchain roots: $cargo_path -> $resolved" >&2
    return 1
  }
  [[ "$($attestation_stat_bin -c '%a' -- "$resolved" 2>/dev/null || true)" =~ ^[0-7]+$ ]] || return 1
  printf '%s\n' "$cargo_path"
}
