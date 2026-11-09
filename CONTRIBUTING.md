# Contributing

## The maintainability rule: one owner per rule

Logic that more than one workflow needs lives in exactly one place
under `scripts/`. Workflows contain orchestration plus only the
consumption that makes them distinct — a workflow step should read
like *what it does with the data*, not *how the data is derived*. If a
change would copy a rule into a second workflow, extract the rule
instead.

Current single owners:

| Rule | Owner |
| ---- | ----- |
| Shipped-image selection — quay tags grouped by digest, per variant family the newest patch of the two newest minor versions, `-pre`-aware; per-kind published latest (`--latest-by-kind`, kind-filtered before the per-minor reduction) | `scripts/shipped-set.sh` (`--raw` emits every active tag; all modes exclude names containing `godev`) |
| Image tag naming and publishing — `<prefix>v<version>[-pre]`, `latest[<version>][-pre]` (the version segment is not hyphenated, e.g. `latest1.27.3-pre`); pre-release sources publish only `-pre` tags, stable only plain, each build prunes the opposite-kind patch tag | `.github/workflows/image-build.yml` (build-time publishing) and `.github/workflows/ubi-drift-check.yml` (drift-time re-pointing of the canonical latest aliases) — the only two workflows that write to the registry |
| Variant registry — which UBI majors and flavors ship | `variants.txt` (workflows enumerate it; adding a variant is adding a line) |

Why this is a rule and not a preference: every copy of a rule must be
found and updated in lockstep, and copies drift. Both failure modes
have happened here — `grep -v godev` survived in one workflow after
the others moved the filter into jq, and each `-pre` tagging semantics
change had to be applied by hand to four workflows, with one
missed-application bug caught only by test harnesses.

Guidelines:

- New shared logic goes in `scripts/` as a standalone script: a header
  comment listing its consumers, its stdout format, and its flags;
  `set -euo pipefail`; it owns its own retries and fails loudly.
- A workflow's slice of shared output (the awk/python that reshapes
  it into that workflow's matrix or dispatch lines) stays in the
  workflow — that part is genuinely its own.
- When review finds the same logic in two workflows, the fix is
  extraction, not a better comment on the second copy.

## Commits

Sign off every commit (`git commit -s`) — the DCO check requires it.
