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
| Image tag naming and publishing — `<prefix>v<version>[-pre]`, `latest[<version>][-pre]` (the version segment is not hyphenated, e.g. `latest1.27.3-pre`); the fips prefix states the backend (`openssl-fips-` for Go ≤1.26, `hostfips-` for 1.27+, keyed on the golang-fips source tag); pre-release sources publish only `-pre` tags, stable only plain; tag pruning is manual (quay's management API rejects robot tokens — see image-build.yml), each build re-points the sibling generation's latest aliases and logs the tags the manual prune should remove | `.github/workflows/image-build.yml` (build-time publishing) and `.github/workflows/ubi-drift-check.yml` (drift-time re-pointing of the canonical latest aliases) — the only two workflows that write to the registry |
| Variant registry — which UBI majors and flavors ship | `variants.txt` (workflows enumerate it; adding a variant is adding a line) |
| Release-notes security context — upstream source links (go.dev, golang-fips) and the Go CVEs fixed by a version, from the OSV.dev query of the Go vulnerability database | `scripts/release-sources.sh` |
| Release-notes base diff — the RHEL/UBI CVEs fixed between the previous and current image of a family, from trivy OS-package scans of both digests | `scripts/base-cve-diff.sh` |
| CI tool image pins — syft, actionlint versions; declared in `docker-compose.yml` (bumped by Dependabot's docker-compose ecosystem, since neither the docker nor github-actions ecosystems can see `docker run` references in workflow run blocks) and read by workflows through the single lookup | `docker-compose.yml` + `scripts/tool-pins.sh` |
| README version-tracks graphic — the animated SVG (light + dark) showing the latest stable Go per source as trains over a shared version axis, older releases trailing behind each engine | `scripts/version-tracks.sh` (data from go.dev/dl and `shipped-set.sh --history`; rendered files `docs/version-tracks{,-dark}.svg`, committed by `.github/workflows/readme-tracks.yml`) |

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

## Known alert noise: base-image Python packages

The repository's Dependabot alerts are dominated by four packages that
come from the UBI base image as RPMs — `python3-urllib3`, `setuptools`,
`python3-requests`, and `python3-idna`. The SBOM catalogs their
`dist-info`/`egg-info` metadata, so Dependabot matches them against
**upstream pip advisory ranges** (urllib3 2.x, setuptools 84.x, …) that
RHEL never ships in these streams: RHEL backports the fixes in place and
keeps the version string. Measured 2026-11-12: `dnf update` in fresh
ubi8/ubi9/ubi10 images moved 10–11 packages each and cleared none of the
four — and rebuilding on base-image drift (`ubi-drift-check.yml`)
already delivers the same package updates, so a build-time `dnf update`
adds nothing.

Do not try to clear this class with `dnf update` or a pipeline change.
If the noise ever needs to go, the real levers are removing python3 from
the images (a breaking change for consumers who run Python scripts in
them) or excluding `/usr/lib/python*/site-packages` from the SBOM
catalog — both product decisions, not bug fixes.

## Commits

Sign off every commit (`git commit -s`) — the DCO check requires it.
