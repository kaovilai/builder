#!/bin/bash
# Shared variant tag-prefix mapping: <ubi-major> <flavor> → prefix.
# ubi8 publishes unprefixed tags; ubi9+ are prefixed. The fips flavor's
# prefix states the FIPS backend of the content, keyed on the
# golang-fips source tag: *-openssl-fips (Go ≤1.26, cryptography routed
# through the OpenSSL FIPS module) → openssl-fips-, *-hostfips-release
# (Go 1.27+, native crypto/fips140) → hostfips- — so a tag name never
# claims a backend its image does not use.
#
# Usage:
#   variant-prefix.sh <ubi-major> <flavor> [fips-source-tag]
#     The build/dispatch prefix for that variant; the fips source tag
#     (e.g. go1.27.3-1-hostfips-release) picks the generation. Standard
#     ignores the third argument.
#   variant-prefix.sh --sibling <ubi-major> <flavor> <fips-source-tag>
#     The OTHER generation's prefix (what a hostfips build's openssl-era
#     tags live under, and vice versa) — for retiring stale tags when a
#     version moves between generations.
#   variant-prefix.sh --all <ubi-major> <flavor>
#     Every prefix the flavor can ship, one per line (both fips
#     generations; standard emits one) — for callers that enumerate
#     aliases or tags (ubi-drift-check.yml).
#
# Consumers: image-build.yml, scheduled_dispatch.yml,
# ubi-drift-check.yml — keep this script the single owner of the
# tag-naming contract.

set -euo pipefail

fips_generation() { # $1 = fips source tag → openssl-fips | hostfips
  case "$1" in
    *-openssl-fips)     echo "openssl-fips" ;;
    *-hostfips-release) echo "hostfips" ;;
    *)
      echo "ERROR: unknown fips source tag ${1}; expected *-openssl-fips or *-hostfips-release" >&2
      exit 1
      ;;
  esac
}

emit() { # $1 = major, $2 = generation (ignored for standard), $3 = flavor
  if [ "$3" = "fips" ]; then
    if [ "$1" = "8" ]; then echo "${2}-"; else echo "ubi${1}-${2}-"; fi
  else
    if [ "$1" = "8" ]; then echo ""; else echo "ubi${1}-"; fi
  fi
}

MODE=direct
case "${1:-}" in
  --all)     MODE=all; shift ;;
  --sibling) MODE=sibling; shift ;;
esac

MAJOR="${1:?usage: variant-prefix.sh [--all|--sibling] <ubi-major> <flavor> [fips-source-tag]}"
FLAVOR="${2:?usage: variant-prefix.sh [--all|--sibling] <ubi-major> <flavor> [fips-source-tag]}"
case "$FLAVOR" in
  standard|fips) ;;
  *) echo "ERROR: unknown flavor ${FLAVOR}" >&2; exit 1 ;;
esac

case "$MODE" in
  all)
    if [ "$FLAVOR" != "fips" ]; then
      emit "$MAJOR" "" "$FLAVOR"
    else
      emit "$MAJOR" "openssl-fips" fips
      emit "$MAJOR" "hostfips" fips
    fi
    ;;
  sibling)
    SRC="${3:?--sibling needs the fips source tag}"
    gen=$(fips_generation "$SRC")
    case "$gen" in
      openssl-fips) emit "$MAJOR" "hostfips" fips ;;
      hostfips)     emit "$MAJOR" "openssl-fips" fips ;;
    esac
    ;;
  direct)
    if [ "$FLAVOR" = "fips" ]; then
      SRC="${3:?fips needs the source tag (go<version>-<build>-(openssl-fips|hostfips-release))}"
      # own assignment: a failing generation lookup as a command ARGUMENT
      # would not trigger errexit and would emit an empty generation
      gen="$(fips_generation "$SRC")"
      emit "$MAJOR" "$gen" fips
    else
      emit "$MAJOR" "" "$FLAVOR"
    fi
    ;;
esac
