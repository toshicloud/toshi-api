#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

scripts/generate.sh

message="the generated code differs from proto/; run scripts/generate.sh and commit the result"

if ! git diff --exit-code; then
  echo "$message" >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  git status --porcelain >&2
  echo "$message" >&2
  exit 1
fi
