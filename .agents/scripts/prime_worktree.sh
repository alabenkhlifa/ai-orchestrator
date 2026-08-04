#!/usr/bin/env bash
#
# prime_worktree.sh — warm a freshly created git worktree from the main worktree.
#
# A new slice worktree starts with no `_build`, no `deps`, no `priv/plts` and no
# `assets/node_modules`, so its first `mix compile` pays a full cold build and its
# first `mix dialyzer` rebuilds the PLT from scratch (minutes). This script clones
# those directories from the main worktree so the new worktree is immediately warm.
#
# Usage:
#   .agents/scripts/prime_worktree.sh <target-worktree-path>
#
# Design constraints (deliberate, do not "optimise" away):
#   * `_build` is COPIED, never symlinked or shared. Two worktrees compiling into
#     one `_build` clobber each other's artifacts.
#   * `deps` is COPIED, not shared via MIX_DEPS_PATH. The relative symlinks inside
#     `_build` (e.g. `_build/dev/lib/phoenix/priv -> ../../../../deps/phoenix/priv`)
#     resolve against the *owning* worktree, and a shared `deps` would be rewritten
#     under a concurrent worktree by any `mix deps.get` on a different `mix.lock`.
#   * `priv/plts` is COPIED. `mix.exs` pins `plt_local_path`/`plt_core_path` to the
#     relative path `priv/plts`, so each worktree needs its own copy.
#   * Copies use `cp -c` (APFS clonefile) when available: copy-on-write, near
#     instant, and costs no extra disk. Falls back to a plain recursive copy.
#
# The script is idempotent: an existing non-empty directory in the target is kept
# as-is and never overwritten, so re-running against a live worktree is harmless.

set -euo pipefail

readonly PROGNAME="$(basename "${BASH_SOURCE[0]}")"

# Directories cloned from the main worktree, in copy order.
readonly PRIMED_DIRS=(_build deps priv/plts assets/node_modules)

log()  { printf '%s: %s\n' "$PROGNAME" "$*"; }
warn() { printf '%s: warning: %s\n' "$PROGNAME" "$*" >&2; }
die()  { printf '%s: error: %s\n' "$PROGNAME" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $PROGNAME <target-worktree-path>

Primes a git worktree of this repository from the main worktree by cloning
_build, deps, priv/plts and assets/node_modules into it, then running
'mix deps.get' in the target only when its mix.lock differs from the source.

Refuses to run when the target is the main worktree itself or is not a
worktree of this repository. Existing non-empty directories are kept.
EOF
}

# Canonicalise an existing directory path (resolves symlinks such as /tmp).
abs_dir() {
  ( cd -- "$1" >/dev/null 2>&1 && pwd -P )
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    '') usage >&2; die "missing <target-worktree-path>" ;;
  esac
  [ "$#" -eq 1 ] || { usage >&2; die "expected exactly one argument, got $#"; }

  local target_arg="$1"

  command -v git >/dev/null 2>&1 || die "git not found on PATH"

  # --- Resolve the source (main) worktree from this script's own location -----
  local script_dir
  script_dir="$(abs_dir "$(dirname -- "${BASH_SOURCE[0]}")")" \
    || die "cannot resolve the directory of $PROGNAME"

  local source_common_dir source_worktree
  source_common_dir="$(git -C "$script_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || die "$script_dir is not inside a git repository"
  source_common_dir="$(abs_dir "$source_common_dir")" \
    || die "cannot resolve the shared git directory"

  # The main worktree is always the first entry of 'git worktree list'.
  source_worktree="$(git -C "$script_dir" worktree list --porcelain \
    | awk '/^worktree /{ print substr($0, 10); exit }')"
  [ -n "$source_worktree" ] || die "cannot determine the main worktree"
  [ -d "$source_worktree" ] || die "main worktree $source_worktree does not exist"
  source_worktree="$(abs_dir "$source_worktree")"

  # --- Validate the target ----------------------------------------------------
  [ -e "$target_arg" ] || die "target does not exist: $target_arg"
  [ -d "$target_arg" ] || die "target is not a directory: $target_arg"

  local target_worktree
  target_worktree="$(abs_dir "$target_arg")" || die "cannot resolve target: $target_arg"

  local target_common_dir target_toplevel
  target_common_dir="$(git -C "$target_worktree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || die "target is not inside a git repository: $target_worktree"
  target_common_dir="$(abs_dir "$target_common_dir")" \
    || die "cannot resolve the target's shared git directory"

  [ "$target_common_dir" = "$source_common_dir" ] \
    || die "target belongs to a different repository ($target_common_dir != $source_common_dir)"

  target_toplevel="$(git -C "$target_worktree" rev-parse --path-format=absolute --show-toplevel 2>/dev/null)" \
    || die "cannot resolve the target worktree root"
  target_toplevel="$(abs_dir "$target_toplevel")"
  [ "$target_toplevel" = "$target_worktree" ] \
    || die "target is not a worktree root; pass $target_toplevel instead"

  [ "$target_worktree" != "$source_worktree" ] \
    || die "refusing to prime the main worktree from itself: $source_worktree"

  log "source: $source_worktree"
  log "target: $target_worktree"

  # --- Pick the copy mode once, by probing the real filesystem ----------------
  local clone_supported=0
  if probe_clonefile "$source_worktree" "$target_worktree"; then
    clone_supported=1
    log "copy mode: cp -c (APFS copy-on-write clone)"
  else
    log "copy mode: cp -R (plain recursive copy; clonefile unavailable)"
  fi

  # --- Clone the warm directories --------------------------------------------
  local rel
  for rel in "${PRIMED_DIRS[@]}"; do
    copy_tree "$source_worktree" "$target_worktree" "$rel" "$clone_supported"
  done

  # --- Refresh deps only when the lockfiles disagree ---------------------------
  check_npm_lock "$source_worktree" "$target_worktree"
  sync_deps "$source_worktree" "$target_worktree"

  log "primed $target_worktree"
}

# Probe whether cp -c actually clones across the real source and target volumes.
# Reads an existing source file and writes only inside the target, so the source
# worktree is never modified.
probe_clonefile() {
  local source_worktree="$1" target_worktree="$2"
  local probe_src="$source_worktree/mix.exs"
  local probe_dir="$target_worktree/.prime_worktree_probe.$$"
  local ok=1

  [ -f "$probe_src" ] || return 1
  mkdir -p "$probe_dir" || return 1
  if cp -c "$probe_src" "$probe_dir/clone" >/dev/null 2>&1; then
    ok=0
  fi
  rm -rf "$probe_dir"
  return "$ok"
}

# copy_tree <source-worktree> <target-worktree> <relative-path> <clone-supported>
copy_tree() {
  local source_worktree="$1" target_worktree="$2" rel="$3" clone_supported="$4"
  local src="$source_worktree/$rel"
  local dst="$target_worktree/$rel"

  if [ ! -d "$src" ]; then
    log "skip $rel: not present in the source worktree"
    return 0
  fi

  if [ -e "$dst" ] && [ ! -d "$dst" ]; then
    die "$dst exists and is not a directory"
  fi

  if [ -d "$dst" ]; then
    if [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
      log "keep $rel: already present in the target"
      return 0
    fi
    rmdir "$dst" || die "cannot remove the empty directory $dst"
  fi

  mkdir -p "$(dirname "$dst")"

  local started ended
  started="$(date +%s)"
  if [ "$clone_supported" -eq 1 ]; then
    if ! cp -Rpc "$src" "$dst"; then
      warn "clone of $rel failed; retrying with a plain recursive copy"
      rm -rf "$dst"
      cp -Rp "$src" "$dst" || die "cannot copy $src to $dst"
    fi
  else
    cp -Rp "$src" "$dst" || die "cannot copy $src to $dst"
  fi
  ended="$(date +%s)"

  log "copy $rel: done in $((ended - started))s"
}

# The cloned assets/node_modules matches the source's package-lock.json. Warn when
# the target locks different versions; the browser gate is a slice-level concern, so
# this only reports and never runs the install.
check_npm_lock() {
  local source_worktree="$1" target_worktree="$2"
  local rel="assets/package-lock.json"

  [ -d "$target_worktree/assets/node_modules" ] || return 0
  [ -f "$source_worktree/$rel" ] && [ -f "$target_worktree/$rel" ] || return 0

  if ! cmp -s "$source_worktree/$rel" "$target_worktree/$rel"; then
    warn "$rel differs from the source worktree"
    warn "run 'npm --prefix assets ci' in $target_worktree before the browser proof"
  fi
}

# Run 'mix deps.get' in the target only when its mix.lock differs from the source.
sync_deps() {
  local source_worktree="$1" target_worktree="$2"

  if [ ! -f "$target_worktree/mix.lock" ]; then
    log "skip mix deps.get: the target has no mix.lock"
    return 0
  fi

  if [ -d "$target_worktree/deps" ] \
    && cmp -s "$source_worktree/mix.lock" "$target_worktree/mix.lock"; then
    log "skip mix deps.get: mix.lock matches the source worktree"
    return 0
  fi

  if ! command -v mix >/dev/null 2>&1; then
    warn "mix.lock differs from the source worktree but mix is not on PATH"
    warn "run 'mix deps.get' in $target_worktree before building"
    return 1
  fi

  log "mix.lock differs from the source worktree: running mix deps.get"
  ( cd "$target_worktree" && mix deps.get ) || die "mix deps.get failed in $target_worktree"
}

main "$@"
