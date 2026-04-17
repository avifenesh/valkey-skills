#!/usr/bin/env bash
# Sync glide-mq, glide-mq-migrate-bullmq, and glide-mq-migrate-bee skill content
# from upstream avifenesh/glide-mq into this repo's plugin layout.
#
# Upstream layout      : skills/<plugin>/SKILL.md + skills/<plugin>/references/*
# valkey-skills layout : skills/<plugin>/skills/<plugin>/SKILL.md + skills/<plugin>/skills/<plugin>/references/*
#
# Usage: scripts/sync-glide-mq-upstream.sh [ref]   (default: main)
#
# Writes a manifest to UPSTREAM-GLIDE-MQ.md at repo root with the SHA/date/version synced.

set -euo pipefail

UPSTREAM_OWNER="avifenesh"
UPSTREAM_REPO="glide-mq"
PLUGINS=("glide-mq" "glide-mq-migrate-bullmq" "glide-mq-migrate-bee")
REF="${1:-main}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v gh >/dev/null 2>&1; then
  echo "[ERROR] gh CLI is required (install from cli.github.com or provide GH_TOKEN to the API directly)" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[ERROR] jq is required" >&2
  exit 1
fi

echo "[INFO] Resolving ref '$REF' on $UPSTREAM_OWNER/$UPSTREAM_REPO..."
SHA=$(gh api "repos/$UPSTREAM_OWNER/$UPSTREAM_REPO/commits/$REF" --jq .sha)
DATE=$(gh api "repos/$UPSTREAM_OWNER/$UPSTREAM_REPO/commits/$REF" --jq .commit.author.date)

if [ -z "$SHA" ]; then
  echo "[ERROR] Could not resolve ref '$REF'" >&2
  exit 1
fi

# `jq @base64d` instead of `base64 -d` for portability (GNU base64 uses -d,
# BSD/macOS uses -D). gsub("\n"; "") strips the wrapping newlines the
# GitHub API adds to base64-encoded content blobs.
VERSION=$(gh api "repos/$UPSTREAM_OWNER/$UPSTREAM_REPO/contents/package.json?ref=$SHA" \
  --jq '.content | gsub("\n"; "") | @base64d | fromjson | .version // empty')

echo "[INFO] Syncing $UPSTREAM_OWNER/$UPSTREAM_REPO @ $SHA (${DATE}, v${VERSION:-?})"

# Helper: fetch a single file from upstream and write it to the given local path.
fetch_file() {
  local upstream_path="$1"
  local local_path="$2"
  mkdir -p "$(dirname "$local_path")"
  gh api "repos/$UPSTREAM_OWNER/$UPSTREAM_REPO/contents/${upstream_path}?ref=$SHA" \
    --jq '.content | gsub("\n"; "") | @base64d' > "$local_path"
}

# Helper: list files in an upstream directory. Returns:
#   - Newline-separated filenames if the directory exists.
#   - Empty string and exit 0 if upstream returns 404 (directory removed upstream).
#   - Exits non-zero for any other API error so the sync fails loudly instead of
#     silently deleting local content.
list_ref_files() {
  local upstream_path="$1"
  local stderr
  stderr=$(mktemp)
  local body
  if ! body=$(gh api "repos/$UPSTREAM_OWNER/$UPSTREAM_REPO/contents/${upstream_path}?ref=$SHA" \
                  --jq '.[] | select(.type=="file") | .name' 2>"$stderr"); then
    if grep -qE '(HTTP 404|404 Not Found)' "$stderr"; then
      rm -- "$stderr"
      return 0  # upstream removed the dir - signal with empty output
    fi
    cat "$stderr" >&2
    rm -- "$stderr"
    echo "[ERROR] Failed to list ${upstream_path} on $UPSTREAM_OWNER/$UPSTREAM_REPO" >&2
    return 1
  fi
  rm -- "$stderr"
  printf '%s\n' "$body"
}

for p in "${PLUGINS[@]}"; do
  dest_dir="skills/$p/skills/$p"
  echo "[INFO] $p -> $dest_dir"

  # SKILL.md
  fetch_file "skills/$p/SKILL.md" "$dest_dir/SKILL.md"

  # references/ (fail loudly on non-404; empty on 404)
  ref_files=$(list_ref_files "skills/$p/references")

  if [ -n "$ref_files" ]; then
    mkdir -p "$dest_dir/references"
    # Remove stale references that no longer exist upstream
    if [ -d "$dest_dir/references" ]; then
      for existing in "$dest_dir/references"/*; do
        [ -f "$existing" ] || continue
        base=$(basename "$existing")
        if ! grep -qxF "$base" <<< "$ref_files"; then
          echo "  [REMOVE] references/$base (no longer upstream)"
          rm -- "$existing"
        fi
      done
    fi
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      fetch_file "skills/$p/references/$f" "$dest_dir/references/$f"
      echo "  [OK] references/$f"
    done <<< "$ref_files"
  else
    # upstream removed the references/ dir entirely - nuke our copy
    if [ -d "$dest_dir/references" ]; then
      echo "  [REMOVE] references/ (no longer upstream)"
      rm -r -- "$dest_dir/references"
    fi
  fi
done

# Write pin manifest
cat > UPSTREAM-GLIDE-MQ.md <<EOF
# glide-mq upstream pin

The three glide-mq plugins in this repo vendor content from
[avifenesh/glide-mq](https://github.com/avifenesh/glide-mq).

Run \`scripts/sync-glide-mq-upstream.sh\` to refresh from upstream \`main\`, or
pass a ref (tag, branch, commit SHA) to pin to a specific version.

Last sync:

- Ref requested: \`$REF\`
- Commit SHA: \`$SHA\`
- Commit date: $DATE
- Package version: \`${VERSION:-?}\`

Plugins synced:

$(printf -- '- %s\n' "${PLUGINS[@]}")
EOF

echo "[INFO] Done. Pin recorded in UPSTREAM-GLIDE-MQ.md"
