#!/usr/bin/env bash
#
# Install this repo's skills and global instructions into the local DSH environment.
#
# DSH_HOME resolution matches @deepseek-ai/dsh-home-paths resolveDshHome(), highest first:
#   1. --dsh-home parameter (explicit)
#   2. $DSH_HOME environment variable
#   3. ~/.dsh                (upstream default name)
#
# This file is deliberately ASCII-only.
#
# Usage:
#   ./install.sh
#   ./install.sh --force
#   ./install.sh --dsh-home /path/to/dsh-data
#
set -euo pipefail

FORCE=0
EXPLICIT_HOME=""

while [ $# -gt 0 ]; do
  case "$1" in
    --force)     FORCE=1; shift ;;
    --dsh-home)  EXPLICIT_HOME="$2"; shift 2 ;;
    -h|--help)   sed -n '2,16p' "$0"; exit 0 ;;
    *)           echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

resolve_dsh_home() {
  if [ -n "$EXPLICIT_HOME" ]; then printf '%s\n' "$EXPLICIT_HOME"; return; fi
  if [ -n "${DSH_HOME:-}" ];    then printf '%s\n' "$DSH_HOME";    return; fi
  printf '%s\n' "$HOME/.dsh"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$(resolve_dsh_home)"

echo "DSH_HOME = $TARGET"
echo

mkdir -p "$TARGET"

# ---- global instructions -------------------------------------------------
AGENTS_SRC="$REPO_ROOT/agents/AGENTS.md"
AGENTS_DST="$TARGET/AGENTS.md"

if [ ! -f "$AGENTS_SRC" ]; then
  echo "warning: not found: $AGENTS_SRC -- skipping global instructions" >&2
elif [ -e "$AGENTS_DST" ] && [ "$FORCE" -ne 1 ]; then
  echo "warning: already exists: $AGENTS_DST -- kept as is. Use --force to overwrite." >&2
else
  cp -f "$AGENTS_SRC" "$AGENTS_DST"
  echo "[ok] AGENTS.md -> $AGENTS_DST"
fi

# ---- skills --------------------------------------------------------------
SKILLS_SRC="$REPO_ROOT/skills"
SKILLS_DST="$TARGET/skills"

if [ ! -d "$SKILLS_SRC" ]; then
  echo "warning: not found: $SKILLS_SRC -- skipping skills" >&2
else
  mkdir -p "$SKILLS_DST"
  COUNT=0
  for dir in "$SKILLS_SRC"/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    if [ ! -f "$dir/SKILL.md" ]; then
      echo "warning: skipped $name: no SKILL.md in directory" >&2
      continue
    fi
    mkdir -p "$SKILLS_DST/$name"
    cp -f "$dir/SKILL.md" "$SKILLS_DST/$name/SKILL.md"
    echo "[ok] skill $name"
    COUNT=$((COUNT + 1))
  done
  echo
  echo "installed $COUNT skills into $SKILLS_DST"
fi

echo
echo "Done. Restart DSH or open a new session to pick this up."
echo "DSH discovers skills as <root>/<name>/SKILL.md -- already laid out that way."
