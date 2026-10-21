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

# A title that marks a breaking change with "!", as in Conventional Commits,
# waives a compatibility violation before the first tag and while the newest
# tag's major version is 0. From v1.0.0 nothing waives one.
breaking_marker='^[a-z]+(\([^)]*\))?!:'
accept_marked() {
  local against="$1" when
  if ! [[ "$title" =~ $breaking_marker ]]; then
    return 1
  fi
  case "$tag" in
    "") when="before the first tag" ;;
    v0.*) when="while $tag has major version 0" ;;
    *) return 1 ;;
  esac
  echo "::warning::breaking change against $against accepted $when: $title"
}

if printf '%s\n' "$tree" | grep -q '\.proto$'; then
  compare ".git#ref=$sha"
  judge "toshi.workspace.v1 against $base" "$workspace_rc"
  judge "toshi.operator.v1 against $base" "$operator_rc"

  if [ "$failed" -ne 0 ]; then
    exit 1
  fi

  if [ "$broken" -eq 1 ] && ! accept_marked "$base"; then
    exit 1
  fi
else
  echo "::notice::$base has no .proto files yet; nothing to compare against"
fi

if [ -z "$tag" ]; then
  echo "::notice::no v* tag yet, so there is no release to compare against"
  exit 0
fi

# The violations buf reports for one package of an input against the tag,
# without positions, one per line.
violations() {
  local input="$1" package="$2"
  shift 2
  buf breaking "$input" --path "proto/toshi/$package/v1" \
    --against ".git#tag=$tag" --error-format json "$@" |
    jq -c '{path, type, message}' | sort -u
}

# While the major version is 0, a violation that the target branch already
# has against the tag was accepted when it landed. Only a violation this
# change adds to them counts.
added() {
  local package="$1" rc="$2" head_rc=0 base_rc=0 from_head from_base new
  shift 2
  if [ "$rc" -eq 0 ]; then
    return
  fi
  if [ "$rc" -ne 100 ]; then
    judge "toshi.$package.v1 against $tag" "$rc"
    return
  fi
  from_head="$(violations . "$package" "$@")" || head_rc=$?
  from_base="$(violations ".git#ref=$sha" "$package" "$@")" || base_rc=$?
  if [ "$head_rc" -ne 100 ] || { [ "$base_rc" -ne 0 ] && [ "$base_rc" -ne 100 ]; }; then
    echo "breaking: buf failed comparing toshi.$package.v1 and $base with $tag" >&2
    failed=1
    return
  fi
  new="$(comm -23 <(printf '%s\n' "$from_head") <(printf '%s\n' "$from_base") | sed '/^$/d')"
  if [ -z "$new" ]; then
    echo "::notice::toshi.$package.v1 breaks only what $base already breaks against $tag"
    return
  fi
  printf '%s\n' "$new" >&2
  echo "breaking: toshi.$package.v1 adds a change buf rejects against $tag" >&2
  broken=1
}

compare ".git#tag=$tag"
failed=0
broken=0
case "$tag" in
  v0.*)
    added workspace "$workspace_rc"
    added operator "$operator_rc" --config "$config" --against-config "$config"
    ;;
  *)
    judge "toshi.workspace.v1 against $tag" "$workspace_rc"
    judge "toshi.operator.v1 against $tag" "$operator_rc"
    ;;
esac

if [ "$failed" -ne 0 ]; then
  exit 1
fi
if [ "$broken" -eq 1 ] && ! accept_marked "$tag"; then
  exit 1
fi
