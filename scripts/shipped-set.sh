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
# looks up tags that may have left the shipped set)
if [ "${1:-}" = "--raw" ]; then
  published_tags
  exit 0
fi

# the selector reads the tag list from a file: its script arrives on
# stdin via the heredoc below, so the tags cannot also be piped in
TAGS_FILE=$(mktemp /tmp/shipped-set-tags.XXXXXX)
trap 'rm -f "$TAGS_FILE"' EXIT
published_tags > "$TAGS_FILE"

python3 - "$TAGS_FILE" <<'PYEOF'
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
    fips = "-fips" if "openssl-fips" in n else ""
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

for key, entries in fams.items():
    major = key[len("ubi"):].split("-")[0]
    flavor = "fips" if key.endswith("-fips") else "standard"
    minors = sorted({v[:2] for e in entries for v in e["versions"]}, reverse=True)[:2]
    for minor in minors:
        best = None
        for e in entries:
            for v in e["versions"]:
                if v[:2] == minor and (best is None or v > best[0]):
                    best = (v, e)
        if best:
            v, e = best
            suffix = "v%d.%d.%d" % v
            tag = next(n for n in e["tags"] if n.endswith(suffix) or n.endswith(suffix + "-pre"))
            version = "%d.%d.%d" % v
            print("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d" % (
                version, major, flavor, key, e["digest"], tag,
                last_modified[tag], 1 if minor == minors[0] else 0))
PYEOF
