#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

for tool in buf protoc-gen-go protoc-gen-connect-go protoc-gen-es; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "generate: $tool is not on PATH; run it under mise (mise exec -- scripts/generate.sh)" >&2
    exit 1
  fi
done

# buf generate --clean would remove the output directory, and the Go output
# goes to the repository root, so the three generated trees are removed here.
rm -rf workspacev1 operatorv1 ts/gen
buf generate
