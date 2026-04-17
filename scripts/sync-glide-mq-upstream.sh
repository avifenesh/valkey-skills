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
VERSION=$(gh api "repos/$UPSTREAM_OWNER/$UPSTREAM_REPO/contents/package.json?ref=$SHA" --jq .content \
  | base64 -d | jq -r '.version // empty')

if [ -z "$SHA" ]; then
  echo "[ERROR] Could not resolve ref '$REF'" >&2
  exit 1
fi

echo "[INFO] Syncing $UPSTREAM_OWNER/$UPSTREAM_REPO @ $SHA (${DATE}, v${VERSION:-?})"

# Helper: fetch a single file from upstream and write it to the given local path.
fetch_file() {
  local upstream_path="$1"
  local local_path="$2"
  mkdir -p "$(dirname "$local_path")"
  gh api "repos/$UPSTREAM_OWNER/$UPSTREAM_REPO/contents/${upstream_path}?ref=$SHA" --jq .content \
    | base64 -d > "$local_path"
}

for p in "${PLUGINS[@]}"; do
  dest_dir="skills/$p/skills/$p"
  echo "[INFO] $p -> $dest_dir"

  # SKILL.md
  fetch_file "skills/$p/SKILL.md" "$dest_dir/SKILL.md"

  # references/ (newline-separated list of files)
  ref_files=$(gh api "repos/$UPSTREAM_OWNER/$UPSTREAM_REPO/contents/skills/$p/references?ref=$SHA" \
    --jq '.[] | select(.type=="file") | .name' 2>/dev/null || true)

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
