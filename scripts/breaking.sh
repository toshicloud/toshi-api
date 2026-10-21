#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

base="${BASE:-origin/main}"
title="${PR_TITLE:-}"

if ! sha="$(git rev-parse --verify "$base^{commit}")"; then
  echo "breaking: $base is not a commit in this clone" >&2
  exit 1
fi

if ! tree="$(git ls-tree -r --name-only "$sha" -- proto)"; then
  echo "breaking: cannot read the tree of $sha" >&2
  exit 1
fi

# The newest release tag, or empty before the first one.
if ! tag="$(git -c versionsort.suffix=- for-each-ref --count=1 --sort=-version:refname --format='%(refname:strip=2)' 'refs/tags/v*')"; then
  echo "breaking: cannot read the tags" >&2
  exit 1
fi

config="$(mktemp --suffix=.json)"
trap 'rm -f "$config"' EXIT
cat > "$config" <<'JSON'
{"version":"v2","modules":[{"path":"proto"}],"breaking":{"use":["WIRE_JSON"]}}
JSON

# Compares both packages with one input and leaves the exit codes behind.
compare() {
  local input="$1"
  workspace_rc=0
  operator_rc=0
  buf breaking --path proto/toshi/workspace/v1 --against "$input" || workspace_rc=$?
  buf breaking --path proto/toshi/operator/v1 --against "$input" \
    --config "$config" --against-config "$config" || operator_rc=$?
}

# buf exits 100 for a compatibility violation and another code for any other
# failure. Only 100 can be waived by the pull request title.
failed=0
broken=0
judge() {
  local name="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    return
  fi
  if [ "$rc" -eq 100 ]; then
    echo "breaking: $name has a change buf rejects" >&2
    broken=1
    return
  fi
  echo "breaking: buf failed on $name with exit $rc" >&2
  failed=1
}

if printf '%s\n' "$tree" | grep -q '\.proto$'; then
  compare ".git#ref=$sha"
  judge "toshi.workspace.v1 against $base" "$workspace_rc"
  judge "toshi.operator.v1 against $base" "$operator_rc"

  if [ "$failed" -ne 0 ]; then
    exit 1
  fi

  if [ "$broken" -eq 1 ]; then
    breaking_marker='^[a-z]+(\([^)]*\))?!:'
    if [[ "$title" =~ $breaking_marker ]] && [ -z "$tag" ]; then
      echo "::warning::breaking change accepted before the first tag: $title"
    else
      exit 1
    fi
  fi
else
  echo "::notice::$base has no .proto files yet; nothing to compare against"
fi

if [ -z "$tag" ]; then
  echo "::notice::no v* tag yet, so there is no release to compare against"
  exit 0
fi

compare ".git#tag=$tag"
if [ "$workspace_rc" -eq 0 ] && [ "$operator_rc" -eq 0 ]; then
  exit 0
fi
echo "breaking: the API has a change buf rejects against $tag" >&2
exit 1
