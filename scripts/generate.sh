#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# protoc-gen-es is a devDependency of ts/, beside the runtime it must match, so
# it comes from ts/node_modules. Install it from the committed lockfile when it
# is missing, so this script works in a fresh checkout that has not run npm.
if [[ ! -x ts/node_modules/.bin/protoc-gen-es ]]; then
  echo "generate: installing ts/ dependencies from package-lock.json" >&2
  npm --prefix ts ci --ignore-scripts --no-audit --no-fund
fi
export PATH="$root/ts/node_modules/.bin:$PATH"

for tool in buf protoc-gen-go protoc-gen-connect-go protoc-gen-es; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "generate: $tool is not on PATH; run it under mise (mise exec -- scripts/generate.sh)" >&2
    exit 1
  fi
done

# buf generate --clean would remove the output directory, and the Go output
# goes to the repository root, so the generated trees are removed here.
rm -rf workspacev1 operatorv1 githubcorev1 backendv1 providerv1 toshipb ts/gen
buf generate
