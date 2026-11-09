#!/bin/bash
# Shared golang-fips release knowledge.
#
# Default: emit the candidate releases as JSON on stdout:
#   [{"tag": "go1.27.3-1-hostfips-release", "pre": true, "published_at": "..."}, ...]
#   (non-draft releases tagged go<version>-<build>-(openssl-fips|hostfips-release);
#    the pure-digit build segment excludes rc tags)
# --top2: the best release of each of the two newest minor versions,
#   as JSON [{"tag", "pre", "version"}, ...], newest minor first
# --best-for <X.Y.Z>: the best release of exactly that Go version, as
#   JSON, or no output when none exists
# "Best" ordering: stable first, then version, then build number, then
# the openssl-fips backend.
#
# Consumers: image-build.yml, scheduled_dispatch.yml, release.yml,
# readme-badges.yml — keep this script the single owner of the rules.

set -euo pipefail
# Bash clears errexit inside command substitutions unless this is set;
# without it a failed gh/jq would yield a partial release list instead
# of failing the run.
shopt -s inherit_errexit

# the lookup owns its retries (CONTRIBUTING): a transient gh failure
# discards any partial result and retries the complete pagination
FIPS_RELEASES=""
for attempt in 1 2 3; do
  if FIPS_RELEASES=$(gh api repos/golang-fips/go/releases --paginate | jq -s 'add'); then
    break
  fi
  if [ "$attempt" -eq 3 ]; then
    echo "ERROR: golang-fips release lookup failed after 3 attempts" >&2
    exit 1
  fi
  sleep 10
done

JQ='
  def vkey: (.tag | split("-")[0] | ltrimstr("go") | split(".") | map(tonumber));
  def bkey: (.tag | split("-")[1] | tonumber);
  def ossl: (if .tag | endswith("openssl-fips") then 1 else 0 end);
  def best: max_by([ (if .pre then 0 else 1 end), vkey, bkey, ossl ]);
  def cands: [ .[] | select(.draft == false)
    | select(.tag_name | test("^go[0-9]+\\.[0-9]+(\\.[0-9]+)?-[0-9]+-(openssl-fips|hostfips-release)$"))
    | {tag: .tag_name, pre: .prerelease, published_at: .published_at} ];
'

case "${1:-}" in
  --top2)
    echo "$FIPS_RELEASES" | jq -c "${JQ}"'
      cands | group_by(vkey | .[0:2]) | sort_by(.[0] | vkey | .[0:2]) | reverse
      | .[0:2] | map(best)
      | map({tag, pre, version: (.tag | split("-")[0] | ltrimstr("go"))})'
    ;;
  --best-for)
    ver="go${2:?--best-for needs a Go version}"
    echo "$FIPS_RELEASES" | jq -c --arg v "$ver" "${JQ}"'
      cands | map(select(.tag | startswith($v + "-"))) | best | select(. != null)'
    ;;
  *)
    echo "$FIPS_RELEASES" | jq -c "${JQ}"'cands'
    ;;
esac
