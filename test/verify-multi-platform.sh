#!/bin/bash
# Verifies a patched multi-platform index in a registry against the original index.
#
# usage: verify-multi-platform.sh <original ref> <patched ref> <reports dir>
#
# PATCHED_PLATFORMS lists the platforms that must have been patched, PRESERVED_ARCHES
# the architectures that must be unchanged. <reports dir> holds the Trivy reports of
# the original image, named <arch>.json. Set TRIVY_USERNAME and TRIVY_PASSWORD for a
# registry that needs authentication; docker must already be logged in to it.
set -euo pipefail

original="$1"
patched="$2"
reports="$3"

docker buildx imagetools inspect --raw "$original" > original-index.json
docker buildx imagetools inspect --raw "$patched" > patched-index.json
jq . patched-index.json

platforms() {
  # linux/arm64/v8 and linux/arm64 are the same platform
  jq -r '.manifests[] | select(.platform.os != "unknown") | "\(.platform.os)/\(.platform.architecture)\(if .platform.variant and .platform.variant != "v8" then "/" + .platform.variant else "" end)"' "$1" | sort
}
digest_for() {
  jq -r --arg arch "$2" '.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest' "$1"
}

# every original platform is kept in the patched index
diff <(platforms original-index.json) <(platforms patched-index.json)

for platform in $PATCHED_PLATFORMS; do
  arch=$(echo "$platform" | cut -d'/' -f2)
  before=$(digest_for original-index.json "$arch")
  after=$(digest_for patched-index.json "$arch")
  echo "${platform}: ${before} -> ${after}"
  if [ -z "$after" ] || [ "$before" = "$after" ]; then
    echo "::error::${platform} was not patched"
    exit 1
  fi
done

for arch in $PRESERVED_ARCHES; do
  if [ "$(digest_for original-index.json "$arch")" != "$(digest_for patched-index.json "$arch")" ]; then
    echo "::error::linux/${arch} should have been preserved"
    exit 1
  fi
done

# the vulnerabilities went down on every patched platform
for platform in $PATCHED_PLATFORMS; do
  arch=$(echo "$platform" | cut -d'/' -f2)
  trivy image --image-src remote --platform "$platform" --pkg-types os --ignore-unfixed --scanners vuln \
    -f json -o "patched-${arch}.json" "$patched"
  image_arch=$(jq -r '.Metadata.ImageConfig.architecture' "patched-${arch}.json")
  before=$(jq '[.Results[]? | .Vulnerabilities[]?] | length' "${reports}/${arch}.json")
  after=$(jq '[.Results[]? | .Vulnerabilities[]?] | length' "patched-${arch}.json")
  echo "${platform} (image config: ${image_arch}): ${before} -> ${after} fixable vulnerabilities"
  if [ "$image_arch" != "$arch" ]; then
    echo "::error::scanned ${image_arch} instead of ${arch}"
    exit 1
  fi
  if [ "$after" -ge "$before" ]; then
    echo "::error::vulnerabilities did not go down for ${platform}"
    exit 1
  fi
done
