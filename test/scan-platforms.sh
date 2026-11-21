#!/bin/bash
# Writes a Trivy report for each platform in PATCHED_PLATFORMS of an image in a
# registry to <reports dir>/<arch>.json, and checks that each one has fixable
# vulnerabilities to patch.
#
# usage: scan-platforms.sh <image ref> <reports dir>
set -euo pipefail

image="$1"
reports="$2"

mkdir -p "$reports"
for platform in $PATCHED_PLATFORMS; do
  arch=$(echo "$platform" | cut -d'/' -f2)
  trivy image --image-src remote --platform "$platform" --pkg-types os --ignore-unfixed --scanners vuln \
    -f json -o "${reports}/${arch}.json" "$image"
  count=$(jq '[.Results[]? | .Vulnerabilities[]?] | length' "${reports}/${arch}.json")
  echo "${platform}: ${count} fixable vulnerabilities before patching"
  if [ "$count" -eq 0 ]; then
    echo "::error::expected fixable vulnerabilities in the unpatched ${platform} image"
    exit 1
  fi
done
