#!/bin/bash
# Shared shipped-set selector for the automation workflows.
#
# Emits one line per shipped image on stdout, TAB-separated:
#   version  major  flavor  family  digest  tag  last_modified  newest
#
# Shipped set: tags published on quay.io/konveyor/builder, grouped by
# manifest digest, per variant family the newest patch of each of the
# two newest minor versions. Version extraction is anchored to a
# trailing vX.Y.Z with an optional -pre suffix (pre-release content
# publishes only -pre tags; stable only plain tags). `newest` is 1 for
# the family's newest minor (the dispatcher's "build latest" slot) and
# 0 otherwise. godev tags are excluded.
#
# Consumers: release.yml, smoke-test.yml, submit-sboms.yml,
# ubi-drift-check.yml, readme-badges.yml — keep this script the single
# owner of the selection rules.

set -euo pipefail
# Bash clears errexit inside command substitutions unless this is set;
# without it a failed curl/jq in published_tags would yield a partial
# tag list instead of failing the run.
shopt -s inherit_errexit

# Collect all active tags published to quay.io/konveyor/builder.
published_tags() {
  local page=1 resp
  while :; do
    resp=$(curl -sfS --retry 3 --retry-delay 5 --max-time 30 \
      "https://quay.io/api/v1/repository/konveyor/builder/tag/?limit=100&page=${page}&onlyActiveTags=true")
    # godev filtered in jq: a page holding only godev tags would make
    # grep exit 1 and abort the run
    echo "$resp" | jq -r '.tags[] | select((.name | contains("godev")) | not) | "\(.name) \(.manifest_digest) \(.last_modified)"'
    [ "$(echo "$resp" | jq -r '.has_additional')" = "true" ] || break
    page=$((page + 1))
  done
}

# --raw: emit every active tag as "name digest last_modified" instead
# of the selected shipped set (the drift check's publish confirmation
# looks up tags that may have left the shipped set). Like the default
# mode, names containing "godev" are excluded.
# --history: every published patch tag, "version family kind digest
# tag", with NO selection — the release notes' predecessor lookups need
# the full published history, not the reduced shipped set (with
# 1.26.9, 1.26.10, 1.27.2 and 1.27.3 published, the reduced set would
# compare 1.27.3 against 1.26.10 and wrongly call 1.26.10 a first
# release). Composable with --from.
# --latest-by-kind: per family, the newest published patch tag of EACH
# kind (a "kind" column, "plain"/"pre", replaces "newest" as the last
# column; at most one row per family per kind, omitted when that kind
# has nothing published). The kind filter runs BEFORE any patch/minor
# reduction: the newest plain patch can be older than the newest -pre
# patch of the same minor (stable 1.27.2 next to 1.27.3-pre), which the
# default per-minor selection would discard. Composable with --from.
# --from <file>: select from a --raw snapshot instead of a fresh crawl,
# so callers that also use the snapshot directly (the drift check's
# alias bookkeeping) never see selection and bookkeeping disagree
MODE=selection
case "${1:-}" in
  --raw)
    published_tags
    exit 0
    ;;
  --history)
    MODE=history
    shift
    ;;
  --latest-by-kind)
    MODE=latest-by-kind
    shift
    ;;
esac

# the selector reads the tag list from a file: its script arrives on
# stdin via the heredoc below, so the tags cannot also be piped in
TAGS_FILE=$(mktemp /tmp/shipped-set-tags.XXXXXX)
trap 'rm -f "$TAGS_FILE"' EXIT
if [ "${1:-}" = "--from" ]; then
  cat "${2:?--from needs a file}" > "$TAGS_FILE"
else
  published_tags > "$TAGS_FILE"
fi

python3 - "$TAGS_FILE" "$MODE" <<'PYEOF'
import re
import sys
from collections import defaultdict

by_digest = {}
last_modified = {}
for line in open(sys.argv[1]):
    name, digest, when = line.split(None, 2)
    when = when.strip()
    by_digest.setdefault(digest, []).append(name)
    last_modified[name] = when

def family(n):
    # both fips generations — openssl-fips (Go ≤1.26) and hostfips
    # (Go 1.27+) — are the same flavor lineage: 1.27.3 hostfips content
    # is simply the newer fips image of the family
    fips = "-fips" if ("openssl-fips" in n or "hostfips" in n) else ""
    m = re.match(r"^ubi(\d+)", n)
    return f"ubi{m.group(1) if m else '8'}{fips}"

fams = {}
for digest, names in by_digest.items():
    versions = set()
    for n in names:
        # anchored with an optional -pre suffix: pre-release content
        # publishes only -pre tags, stable only plain
        m = re.search(r"v(\d+)\.(\d+)\.(\d+)(-pre)?$", n)
        if m:
            versions.add((int(m[1]), int(m[2]), int(m[3])))
    fams.setdefault(family(names[0]), []).append({"digest": digest, "tags": names, "versions": versions})

if sys.argv[2] == "history":
    # one row per family+kind+version, newest last_modified wins: a
    # migration overlap can leave patch tags of the same version under
    # BOTH backend prefixes (legacy openssl-fips-named and hostfips-
    # named), and consumers must not pick between their digests
    # arbitrarily — the newest push is the currently-published content
    best = {}
    for digest, names in by_digest.items():
        for n in names:
            m = re.search(r"v(\d+)\.(\d+)\.(\d+)(-pre)?$", n)
            if not m:
                continue
            key = (family(n), "pre" if m[4] else "plain",
                   (int(m[1]), int(m[2]), int(m[3])))
            row = (last_modified[n], "%s.%s.%s" % (m[1], m[2], m[3]),
                   family(n), "pre" if m[4] else "plain", digest, n)
            if key not in best or row[0] > best[key][0]:
                best[key] = row
    for row in best.values():
        print("%s\t%s\t%s\t%s\t%s" % row[1:])
    sys.exit(0)

if sys.argv[2] == "latest-by-kind":
    # kind filtered before any reduction — see the mode docs above
    for key, entries in fams.items():
        major = key[len("ubi"):].split("-")[0]
        flavor = "fips" if key.endswith("-fips") else "standard"
        for kind, suffix in (("plain", ""), ("pre", "-pre")):
            best = None
            for e in entries:
                for v in e["versions"]:
                    s = "v%d.%d.%d" % v
                    tag = next((n for n in e["tags"] if n.endswith(s + suffix)), None)
                    if tag is None:
                        continue
                    if best is None or v > best[0]:
                        best = (v, e, tag)
            if best:
                v, e, tag = best
                print("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" % (
                    "%d.%d.%d" % v, major, flavor, key, e["digest"], tag,
                    last_modified[tag], kind))
    sys.exit(0)

for key, entries in fams.items():
    major = key[len("ubi"):].split("-")[0]
    flavor = "fips" if key.endswith("-fips") else "standard"
    minors = sorted({v[:2] for e in entries for v in e["versions"]}, reverse=True)[:2]
    for minor in minors:
        # key: version, then plain-tag preference — a graduation window
        # can leave both the -pre and the plain tag of the same version
        # active, and the plain one is the stable replacement
        best = None
        for e in entries:
            for v in e["versions"]:
                if v[:2] != minor:
                    continue
                # the kind comes from the matching patch tag, not from
                # any tag on the digest: a latest*-pre alias can sit on
                # stable content, and any() would then mark both digests
                # of a version pre-release, leaving quay order to pick
                suffix = "v%d.%d.%d" % v
                plain = next((n for n in e["tags"] if n.endswith(suffix)), None)
                pre = next((n for n in e["tags"] if n.endswith(suffix + "-pre")), None)
                tag = plain or pre
                if tag is None:
                    continue
                k = (v, plain is not None)
                if best is None or k > best[0]:
                    best = (k, v, e, tag)
        if best:
            _, v, e, tag = best
            version = "%d.%d.%d" % v
            print("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d" % (
                version, major, flavor, key, e["digest"], tag,
                last_modified[tag], 1 if minor == minors[0] else 0))
PYEOF
