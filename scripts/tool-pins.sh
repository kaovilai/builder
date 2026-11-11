#!/bin/bash
# Shared tool-image pin lookup: <service> → image:tag from
# docker-compose.yml, the single source of truth for CI tool image
# versions (bumped by Dependabot's docker-compose ecosystem).
#
# Usage: tool-pins.sh <service>   e.g. tool-pins.sh syft
# Emits the image reference (e.g. "anchore/syft:v1.33.0") on stdout;
# non-zero when the service is not declared.
#
# Consumers: lint.yml, release.yml — keep this script the single owner
# of the pin lookup so a compose rename touches one place.

set -euo pipefail
# Bash clears errexit inside command substitutions unless this is set.
shopt -s inherit_errexit

SERVICE="${1:?usage: tool-pins.sh <service>}"
COMPOSE="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/docker-compose.yml"
[ -r "$COMPOSE" ] || { echo "ERROR: $COMPOSE not found" >&2; exit 1; }

image=$(python3 - "$COMPOSE" "$SERVICE" <<'PY'
import re, sys

compose, service = sys.argv[1], sys.argv[2]
section = None
for line in open(compose):
    # top-level service key, two-space indent
    m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
    if m:
        section = m.group(1)
        continue
    if section == service:
        m = re.match(r'^\s+image:\s*(\S+)', line)
        if m:
            print(m.group(1))
            break
PY
)
[ -n "$image" ] || { echo "ERROR: no image declared for service ${SERVICE} in $COMPOSE" >&2; exit 1; }
echo "$image"
