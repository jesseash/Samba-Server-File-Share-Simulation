#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PAT_FILE="$REPO_ROOT/pat.txt"

usage() {
  cat <<'EOF'
Usage: bash scripts/git_push_with_pat.sh [--dry-run] [--branch <name>] [--force]

Options:
  --dry-run            Show what would be pushed without pushing.
  --branch <name>      Push HEAD to this branch (default: current branch, or main).
  --force              Use force-with-lease to overwrite remote (handles conflicts).
  -h, --help           Show this help.

Environment variables:
  GIT_PAT_USER         Username portion for HTTPS auth (default: x-access-token)
  GITHUB_REPO          GitHub repo as owner/name (auto-detected from origin if unset)
EOF
}

DRY_RUN=0
TARGET_BRANCH=""
FORCE_PUSH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --branch)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --branch" >&2
        usage
        exit 1
      fi
      TARGET_BRANCH="$2"
      shift 2
      ;;
    --force)
      FORCE_PUSH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -f "$PAT_FILE" ]]; then
  echo "PAT file not found: $PAT_FILE" >&2
  exit 1
fi

PAT="$(tr -d '\r\n' < "$PAT_FILE")"

if [[ -z "$PAT" ]]; then
  echo "PAT is empty in: $PAT_FILE" >&2
  exit 1
fi

cd "$REPO_ROOT"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Not a git repository: $REPO_ROOT" >&2
  exit 1
fi

if [[ -z "$TARGET_BRANCH" ]]; then
  TARGET_BRANCH="$(git symbolic-ref --short -q HEAD || true)"
fi

if [[ -z "$TARGET_BRANCH" ]]; then
  TARGET_BRANCH="main"
fi

REPO_SLUG="${GITHUB_REPO:-}"

if [[ -z "$REPO_SLUG" ]]; then
  ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"

  if [[ "$ORIGIN_URL" =~ ^git@github\.com:([^/]+/[^/]+?)(\.git)?$ ]]; then
    REPO_SLUG="${BASH_REMATCH[1]}"
  elif [[ "$ORIGIN_URL" =~ ^https://github\.com/([^/]+/[^/]+?)(\.git)?$ ]]; then
    REPO_SLUG="${BASH_REMATCH[1]}"
  fi
fi

if [[ -z "$REPO_SLUG" ]]; then
  echo "Unable to determine GitHub repo. Set GITHUB_REPO=owner/name and try again." >&2
  exit 1
fi

REPO_SLUG="${REPO_SLUG%.git}"

GIT_PAT_USER="${GIT_PAT_USER:-x-access-token}"
PUSH_URL="https://${GIT_PAT_USER}:${PAT}@github.com/${REPO_SLUG}.git"

PUSH_OPTS=()
[[ "$FORCE_PUSH" -eq 1 ]] && PUSH_OPTS+=(--force)

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: pushing HEAD -> ${TARGET_BRANCH} on ${REPO_SLUG}"
  git push --dry-run "${PUSH_OPTS[@]}" "$PUSH_URL" "HEAD:${TARGET_BRANCH}"
else
  git push "${PUSH_OPTS[@]}" "$PUSH_URL" "HEAD:${TARGET_BRANCH}"
fi