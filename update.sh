#!/usr/bin/env bash
#
# Update the locally installed DSH config from the silver-parakeet repo.
#
# Version source of truth is upstream/VERSION.txt in the repo, which records the
# upstream DietrichGebert/ponytail commit this package was built from.
#
# Flow:
#   1. Read the local marker at <DSH_HOME>/.ponytail-config-version
#   2. Fetch upstream/VERSION.txt from the repo (public, no token needed)
#   3. If the commit matches and --force is absent, stop
#   4. Otherwise install agents/AGENTS.md and every skills/*/SKILL.md
#
# DSH_HOME resolution matches resolveDshHome(): --dsh-home, $DSH_HOME, ~/.dsh
#
# Requires: curl, and either jq or python3 for JSON parsing.
# This file is deliberately ASCII-only.
#
# Usage:
#   ./update.sh
#   ./update.sh --check
#   ./update.sh --force
#   ./update.sh --quiet
#
set -euo pipefail

OWNER="aiden1764"
REPO="silver-parakeet"
BRANCH="main"
EXPLICIT_HOME=""
FORCE=0
QUIET=0
CHECK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --force)    FORCE=1; shift ;;
    --quiet)    QUIET=1; shift ;;
    --check)    CHECK=1; shift ;;
    --dsh-home) EXPLICIT_HOME="$2"; shift 2 ;;
    -h|--help)  sed -n '2,26p' "$0"; exit 0 ;;
    *)          echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }

JSON_TOOL=""
if command -v jq >/dev/null 2>&1; then
  JSON_TOOL="jq"
elif command -v python3 >/dev/null 2>&1; then
  JSON_TOOL="python3"
else
  echo "jq or python3 is required for JSON parsing" >&2
  exit 1
fi

resolve_dsh_home() {
  if [ -n "$EXPLICIT_HOME" ]; then printf '%s\n' "$EXPLICIT_HOME"; return; fi
  if [ -n "${DSH_HOME:-}" ];    then printf '%s\n' "$DSH_HOME";    return; fi
  printf '%s\n' "$HOME/.dsh"
}

TARGET="$(resolve_dsh_home)"
MARKER="$TARGET/.ponytail-config-version"
API="https://api.github.com/repos/$OWNER/$REPO/contents"

info() { [ "$QUIET" -eq 1 ] || echo "$@"; }

AUTH=()
if [ -n "${GH_PAT:-}" ]; then
  AUTH=(-H "Authorization: Bearer $GH_PAT")
fi

get_text() {
  curl -fsSL -H "User-Agent: dsh-update-script" \
       -H "Accept: application/vnd.github+json" "${AUTH[@]}" "$1"
}

# Fetch a file via the Contents API and echo its decoded text.
get_file_text() {
  local json
  json="$(get_text "$1")"
  if [ "$JSON_TOOL" = "jq" ]; then
    printf '%s' "$json" | jq -r '.content' | tr -d '\n' | base64 -d
  else
    printf '%s' "$json" | python3 -c \
      'import sys,json,base64; print(base64.b64decode(json.load(sys.stdin)["content"]).decode("utf-8"), end="")'
  fi
}

list_dir() {
  local json
  json="$(get_text "$1")"
  if [ "$JSON_TOOL" = "jq" ]; then
    printf '%s' "$json" | jq -r '.[] | select(.type=="dir") | .name'
  else
    printf '%s' "$json" | python3 -c \
      'import sys,json; [print(e["name"]) for e in json.load(sys.stdin) if e["type"]=="dir"]'
  fi
}

marker_commit() {
  [ -f "$MARKER" ] || return 0
  sed -n 's/^[[:space:]]*commit[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$MARKER" | head -1
}

# ---- 1. current local version -------------------------------------------
LOCAL_COMMIT="$(marker_commit)"
info "DSH_HOME : $TARGET"
info "local    : ${LOCAL_COMMIT:-unknown (never updated via this script)}"

# ---- 2. remote version ---------------------------------------------------
REMOTE_TEXT="$(get_file_text "$API/upstream/VERSION.txt")"
REMOTE_COMMIT="$(printf '%s\n' "$REMOTE_TEXT" | sed -n 's/^[[:space:]]*commit[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)"

[ -n "$REMOTE_COMMIT" ] || { echo "could not parse a commit id from upstream/VERSION.txt" >&2; exit 1; }
info "remote   : $REMOTE_COMMIT"

if [ "$LOCAL_COMMIT" = "$REMOTE_COMMIT" ] && [ "$FORCE" -ne 1 ]; then
  if [ "$QUIET" -eq 1 ]; then
    echo "ponytail config up to date ($REMOTE_COMMIT)"
  else
    echo
    echo "Already up to date. Use --force to reinstall anyway."
  fi
  exit 0
fi

if [ "$CHECK" -eq 1 ]; then
  echo "update available: ${LOCAL_COMMIT:-unknown} -> $REMOTE_COMMIT"
  exit 10
fi

info ""
info "Installing $REMOTE_COMMIT ..."
info ""

# ---- 3. install ----------------------------------------------------------
WRITTEN=0
SKIPPED=0

install_one() {
  local dest="$1" text="$2" label="$3"
  local dir
  dir="$(dirname "$dest")"
  mkdir -p "$dir"

  if [ -f "$dest" ]; then
    local ondisk
    ondisk="$(cat "$dest")"
    if [ "$ondisk" = "$text" ]; then
      info "$(printf '[--]   %-34s unchanged' "$label")"
      SKIPPED=$((SKIPPED + 1))
      return
    fi
  fi

  printf '%s' "$text" > "$dest"
  info "$(printf '[ok]   %-34s updated' "$label")"
  WRITTEN=$((WRITTEN + 1))
}

for name in $(list_dir "$API/skills"); do
  if ! text="$(get_file_text "$API/skills/$name/SKILL.md" 2>/dev/null)"; then
    echo "warning: skipped $name : no SKILL.md" >&2
    continue
  fi
  install_one "$TARGET/skills/$name/SKILL.md" "$text" "$name"
done

# Never clobber a locally customised AGENTS.md without --force.
AGENTS_DEST="$TARGET/AGENTS.md"
if agents_text="$(get_file_text "$API/agents/AGENTS.md" 2>/dev/null)"; then
  if [ -f "$AGENTS_DEST" ] && [ "$FORCE" -ne 1 ]; then
    if [ "$(cat "$AGENTS_DEST")" != "$agents_text" ]; then
      echo "warning: AGENTS.md differs locally; kept as is. Use --force to overwrite." >&2
      SKIPPED=$((SKIPPED + 1))
      agents_text=""
    fi
  fi
  [ -n "$agents_text" ] && install_one "$AGENTS_DEST" "$agents_text" "AGENTS.md"
else
  echo "warning: agents/AGENTS.md not found in repo" >&2
fi

# ---- 4. record the new version ------------------------------------------
cat > "$MARKER" <<EOF
# Local record of the installed ponytail config.
# Written by install.sh and update.sh. Safe to delete.
repo   = $OWNER/$REPO
branch = $BRANCH
commit = $REMOTE_COMMIT
updated = $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

info ""
info "version marker -> $MARKER"
echo
echo "done: $WRITTEN written, $SKIPPED unchanged (commit ${REMOTE_COMMIT:0:12})"
echo "DSH watches its skill roots; a new session picks this up. No restart needed."
