#!/bin/bash
# Shared variant tag-prefix mapping: <ubi-major> <flavor> → prefix.
# ubi8 publishes unprefixed tags; ubi9+ are prefixed; fips flavors
# carry the openssl-fips segment.
#
# Consumers: image-build.yml, scheduled_dispatch.yml,
# ubi-drift-check.yml — keep this script the single owner of the
# tag-naming contract.

set -euo pipefail

case "${1:?usage: variant-prefix.sh <ubi-major> <flavor>}:${2:?usage: variant-prefix.sh <ubi-major> <flavor>}" in
  8:standard) echo "" ;;
  8:fips)     echo "openssl-fips-" ;;
  *:standard) echo "ubi${1}-" ;;
  *:fips)     echo "ubi${1}-openssl-fips-" ;;
  *)
    echo "ERROR: unknown variant ${1}:${2}" >&2
    exit 1
    ;;
esac
