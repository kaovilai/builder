#!/bin/bash
# Shared release-notes context: upstream source links and the Go
# toolchain CVEs fixed by a release version.
#
# Usage: release-sources.sh <flavor: standard|fips> <go-version> [fips-source-tag]
# Emits markdown on stdout:
#   ### Sources — the go.dev release notes, and for fips releases the
#     exact golang-fips release the toolchain was built from
#   ### CVEs fixed in Go <version> — every stdlib advisory from the Go
#     vulnerability database (queried through the OSV.dev API) whose
#     fixed version is exactly this version
#
# Consumers: release.yml — keep this script the single owner of the
# upstream-source and Go-CVE presentation.

set -euo pipefail
# Bash clears errexit inside command substitutions unless this is set;
# without it a failed curl would yield a partial CVE list instead of
# failing the run.
shopt -s inherit_errexit

FLAVOR="${1:?usage: release-sources.sh <standard|fips> <go-version> [fips-source-tags]}"
VER="${2:?usage: release-sources.sh <standard|fips> <go-version> [fips-source-tags]}"
SRC="${3:-}"

minor="${VER%.*}"

echo "### Sources"
if [ "$FLAVOR" = "fips" ]; then
  # one link per DISTINCT recorded source: drift rebuilds can rebuild
  # one family across a source change, so families of the same release
  # can legitimately differ. Unlabeled (pre-label) images get an index
  # link — never an inferred tag presented as the exact source.
  if [ -n "$SRC" ]; then
    while read -r t; do
      [ -n "$t" ] || continue
      echo "- [golang-fips release \`${t}\`](https://github.com/golang-fips/go/releases/tag/${t}) — the toolchain this release was built from"
    done <<< "$SRC"
  else
    echo "- No recorded source label (the images predate labels) — see the [golang-fips releases for this version](https://github.com/golang-fips/go/releases)"
  fi
fi
echo "- [Go ${minor} release notes](https://go.dev/doc/devel/release#go${minor})"
echo
echo "### CVEs fixed in Go ${VER}"

# every stdlib advisory, filtered to those whose fixed event is exactly
# this version; the query API paginates via page_token. Captured into a
# variable: a pipeline consumer would mask a failure inside the loop.
cves=$(
  page=""
  while :; do
    # page_token belongs in the JSON body (OSV's pagination contract),
    # not the URL — a URL token is ignored and the first page repeats
    body=$(jq -cn --arg pt "$page" \
      '{"package":{"name":"stdlib","ecosystem":"Go"}} + (if $pt == "" then {} else {page_token: $pt} end)')
    resp=$(curl -sfS --retry 3 --retry-delay 5 --max-time 30 \
      -H 'Content-Type: application/json' \
      -d "$body" "https://api.osv.dev/v1/query")
    jq -r --arg v "$VER" '
      .vulns[]?
      | select(.affected[]? | select(.package.name == "stdlib")
               | .ranges[]? | .events[]? | .fixed == $v)
      # summary before the CVE list: whitespace IFS collapses
      # consecutive tabs, so an empty field must be last
      | "\(.id)\t\(.summary // "")\t\([(.aliases // [])[] | select(startswith("CVE-"))] | join(", "))"' <<< "$resp"
    page=$(jq -r '.next_page_token // empty' <<< "$resp")
    [ -n "$page" ] || break
  done | sort -u
)
if [ -n "$cves" ]; then
  while IFS=$'\t' read -r id summary cve_ids; do
    if [ -n "$cve_ids" ]; then
      echo "- **${cve_ids}** — ${summary} ([${id}](https://osv.dev/vulnerability/${id}))"
    else
      echo "- **${id}** — ${summary} ([advisory](https://osv.dev/vulnerability/${id}))"
    fi
  done <<< "$cves"
else
  echo "- None recorded in the [Go vulnerability database](https://osv.dev/list?ecosystem=Go) for this exact version."
fi
