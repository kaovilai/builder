#!/bin/bash
# Shared pre-release classification of a published FIPS image.
#
# Usage: fips-classify.sh <releases-json-file> <version> <tag-last-modified> <manifest-digest>
# Emits true (pre-release source), false (stable), or unknown (no
# matching release — callers must refuse to classify).
#
# Rule: builds always use the best release of the version current at
# build time, so the image is pre-release iff no stable release of
# that Go version had been published when the tag was last pushed. The
# exact source tag recorded in the image config label
# (io.konveyor.builder.go-fips-source, set by image-build.yml) is
# checked first — no timing race; images built before the label
# existed fall back to the push-time rule.
#
# Consumers: release.yml, readme-badges.yml — keep this script the
# single owner of the classification rules.

set -euo pipefail
shopt -s inherit_errexit

RELEASES=$1
VER=$2
LM=$3
DIGEST=$4

# the recorded source tag, read back through the quay registry v2 API
QUAY_TOKEN=$(curl -sfS --retry 3 \
  "https://quay.io/v2/auth?service=quay.io&scope=repository:konveyor/builder:pull" \
  | jq -r .token)
list=$(curl -sfS --retry 3 -H "Authorization: Bearer ${QUAY_TOKEN}" \
  -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
  "https://quay.io/v2/konveyor/builder/manifests/$DIGEST")
if jq -e 'has("manifests")' <<< "$list" >/dev/null; then
  # a manifest list: descend to the first platform's manifest
  plat=$(jq -r '.manifests[0].digest' <<< "$list")
  list=$(curl -sfS --retry 3 -H "Authorization: Bearer ${QUAY_TOKEN}" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
    "https://quay.io/v2/konveyor/builder/manifests/$plat")
fi
# a single-platform tag resolves straight to a manifest
cfg=$(jq -r '.config.digest' <<< "$list")
label=$(curl -sfSL --retry 3 -H "Authorization: Bearer ${QUAY_TOKEN}" \
  "https://quay.io/v2/konveyor/builder/blobs/$cfg" \
  | jq -r '.config.Labels["io.konveyor.builder.go-fips-source"] // ""')

if [ -n "$label" ]; then
  jq -rn --arg t "$label" --slurpfile r "$RELEASES" '
    [$r[0][] | select(.tag == $t)]
    | if length == 0 then "unknown" else .[0].pre end'
  exit 0
fi

ts_iso=$(date -u -d "$LM" +%Y-%m-%dT%H:%M:%SZ)
jq -rn --arg v "$VER" --arg ts "$ts_iso" --slurpfile r "$RELEASES" '
  [$r[0][] | select(.tag | startswith("go" + $v + "-"))]
  | if length == 0 then "unknown"
    else ([.[] | select(.pre == false) | select(.published_at <= $ts)] | length) == 0
    end'
