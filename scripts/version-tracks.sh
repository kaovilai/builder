#!/bin/bash
# README version-train graphic: renders the animated SVG (light and dark
# variants) that replaced the shields badge wall in the README header.
#
# Three tracks, one shared Go-version axis:
#   go.dev      — upstream stable releases (go.dev/dl)
#   ubi go-fips — the FIPS images published to quay, restricted to
#                 builds whose golang-fips source classifies stable
#                 (fips-classify.sh: label-first, push-time fallback)
#   ubi         — the standard images published to quay
# Each track's engine sits at its latest stable version; older releases
# trail behind as fading cars at their own axis positions, so the gap
# between the go.dev train and a quay train is the shipping lag, at a
# glance. A dashed ghost car ahead of the FIPS engine marks the latest
# published pre-release-sourced build — a plain-tag image built from a
# pre-release go-fips source counts here, never as "stable".
#
# Each lane's engine is the newest stable version published across that
# lane's variant families (ubi8/9/10 normally advance in lockstep); a
# family that lags is not depicted separately — the README's available-
# images table and the quay tags page carry the per-family detail.
#
# Usage: version-tracks.sh [--dark] [--summary] [--from <snapshot>]
#        version-tracks.sh --snapshot <file>
#   default        render the light SVG on stdout
#   --dark         render the dark-palette SVG instead
#   --summary      one JSON line of lane heads ({"godev":…,"ubi":…,
#                  "fips":…,"fips_pre":…}) for the README's generated
#                  text summary
#   --snapshot <f> gather live data once and write the lane snapshot
#                  (JSON) to <f>; no SVG is rendered
#   --from <f>     build the output from a snapshot instead of live
#                  data — the workflow renders light, dark, and the
#                  summary from ONE snapshot, so a publication landing
#                  between invocations cannot leave the three outputs
#                  disagreeing on the lane heads
# Owners of the inputs: go.dev/dl JSON, shipped-set.sh --history (quay),
# go-fips-releases.sh + fips-classify.sh (FIPS source classification).
# Refreshed by .github/workflows/readme-tracks.yml, which commits the
# rendered docs/version-tracks{,-dark}.svg.

set -euo pipefail
# Bash clears errexit inside command substitutions unless this is set.
shopt -s inherit_errexit

MODE=light
SUMMARY=""
SNAPSHOT=""
FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dark)     MODE=dark ;;
    --summary)  SUMMARY=1 ;;
    --snapshot) SNAPSHOT="${2:?--snapshot needs an output file}"; shift ;;
    --from)     FROM="${2:?--from needs a snapshot file}"; shift ;;
    *)          echo "usage: $0 [--dark] [--summary] [--from <snapshot>] | --snapshot <file>" >&2; exit 1 ;;
  esac
  shift
done
[ -z "$FROM" ] || [ -r "$FROM" ] || { echo "ERROR: snapshot $FROM not readable" >&2; exit 1; }

# Engine + this many trailing cars per track (older cars beyond this are
# dropped so the axis stays readable).
TRAIL=3

godev_hist=""
history_tsv=""
plain_hist=""
fips_candidates=""
fips_tag_pre=""
fips_releases_file=""
if [ -z "$FROM" ]; then
  # Upstream stable history, newest first: full releases only — rc/beta
  # entries ("go1.27rc3") are filtered by requiring a pure X.Y.Z version.
  # Retries/timeouts follow the repo's go.dev fetch convention.
  godev_hist="$(curl -fsSL --retry 3 --retry-delay 5 --max-time 30 \
    'https://go.dev/dl/?mode=json&include=all' \
    | jq -r '[.[] | .version | ltrimstr("go") | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))]
             | sort_by(split(".") | map(tonumber)) | reverse
             | .[0:'"$((TRAIL + 1))"'] | .[]')"

  # Published quay history (version, family, kind, digest, tag,
  # last_modified): the shared selector's --history mode is the single
  # owner of the published-tag view (see CONTRIBUTING). FIPS families
  # end in -fips.
  history_tsv="$("$(dirname "$0")/shipped-set.sh" --history)"
  plain_hist="$(awk -F'\t' '$2 !~ /-fips$/ && $3 == "plain" {print $1}' <<< "$history_tsv" \
    | sort -uV | tail -n "$((TRAIL + 1))")"
  # Every FIPS plain-tag row as version, digest, last_modified — no
  # dedupe or window before classification: pruning first could drop a
  # published stable image because four newer pre-release/unknown
  # versions exhausted the cutoff, and picking one family's row per
  # version could prefer a pre-release-sourced sibling over a stable
  # one. Whether a row is really stable is decided by fips-classify.sh;
  # identical digests are classified once.
  fips_candidates="$(awk -F'\t' '$2 ~ /-fips$/ && $3 == "plain" {print $1"\t"$4"\t"$6}' <<< "$history_tsv")"
  fips_tag_pre="$(awk -F'\t' '$2 ~ /-fips$/ && $3 == "pre" {print $1}' <<< "$history_tsv" \
    | sort -uV | tail -n 1)"

  fips_releases_file="$(mktemp /tmp/version-tracks-fips.XXXXXX)"
  trap 'rm -f "$fips_releases_file"' EXIT
fi

MODE="$MODE" SUMMARY="$SUMMARY" SNAPSHOT="$SNAPSHOT" FROM="$FROM" TRAIL="$TRAIL" \
GODEV="$godev_hist" PLAIN="$plain_hist" FIPS_CANDIDATES="$fips_candidates" \
FIPS_TAG_PRE="$fips_tag_pre" CLASSIFIER="$(dirname "$0")/fips-classify.sh" \
FIPS_JSON="$fips_releases_file" FIPS_RELEASES_SRC="$(dirname "$0")/go-fips-releases.sh" \
python3 <<'PY'
import json
import math
import os
import subprocess
import sys

mode = os.environ["MODE"]
summary_only = os.environ["SUMMARY"] == "1"
snapshot_path = os.environ["SNAPSHOT"]
from_path = os.environ["FROM"]
trail_n = int(os.environ["TRAIL"])

def ver_key(v):
    return [int(p) for p in v.split(".")]

def load_lanes():
    godev = os.environ["GODEV"].split()
    plain = os.environ["PLAIN"].split()
    tag_pre = os.environ["FIPS_TAG_PRE"].strip()

    # golang-fips release list, materialized once for the classifier (it
    # takes a file, not the generator's stdout)
    releases = os.environ["FIPS_JSON"]
    gen = subprocess.run([os.environ["FIPS_RELEASES_SRC"]],
                         capture_output=True, text=True)
    if gen.returncode != 0:
        sys.exit(f"ERROR: golang-fips release list failed: {gen.stderr.strip()}")
    with open(releases, "w") as f:
        f.write(gen.stdout)

    # FIPS plain tags are only "stable" when their golang-fips source
    # classifies stable — the classifier owns the rule (image label
    # first, push-time fallback for pre-label images). Aggregate per
    # version across its family rows: any stable-sourced row makes the
    # version stable; a version with only pre-release sources joins the
    # pre-release selection; unknown sources are excluded from both
    # rather than mislabeled. The window is applied AFTER classification.
    ver_cls = {}
    digest_cls = {}
    for line in os.environ["FIPS_CANDIDATES"].splitlines():
        if not line.strip():
            continue
        ver, digest, ts = line.split("\t")
        if digest not in digest_cls:
            cls = subprocess.run(
                [os.environ["CLASSIFIER"], releases, ver, ts, digest],
                capture_output=True, text=True)
            if cls.returncode != 0:
                sys.exit(f"ERROR: fips-classify failed for {ver}: {cls.stderr.strip()}")
            digest_cls[digest] = cls.stdout.strip()
        cls = digest_cls[digest]
        if cls not in ("true", "false", "unknown"):
            sys.exit(f"ERROR: unexpected FIPS classification {cls!r} for {ver}")
        ver_cls.setdefault(ver, set()).add(cls)

    fips_stable = [v for v, cls in ver_cls.items() if "false" in cls]
    fips_pre_versions = [v for v, cls in ver_cls.items()
                         if "false" not in cls and "true" in cls]
    if tag_pre:
        fips_pre_versions.append(tag_pre)

    return {
        "godev": sorted(set(godev), key=ver_key),
        "plain": sorted(set(plain), key=ver_key),
        "fips": sorted(set(fips_stable), key=ver_key),
        "fips_pre": max(sorted(set(fips_pre_versions)), key=ver_key)
                     if fips_pre_versions else "",
    }

if from_path:
    with open(from_path) as f:
        lanes = json.load(f)
else:
    lanes = load_lanes()

if snapshot_path:
    with open(snapshot_path, "w") as f:
        json.dump(lanes, f, separators=(",", ":"))
    sys.exit(0)

def head_of(vs):
    return max(sorted(set(vs)), key=ver_key) if vs else ""

heads = {"godev": head_of(lanes["godev"]), "ubi": head_of(lanes["plain"]),
         "fips": head_of(lanes["fips"])}
if summary_only:
    print(json.dumps({**heads, "fips_pre": lanes["fips_pre"]}, separators=(",", ":")))
    sys.exit(0)

# window the classified-stable versions only now, so the axis covers
# exactly the cars that are drawn
fips = lanes["fips"][-(trail_n + 1):]
fips_pre = lanes["fips_pre"]

# Categorical palette (fixed slot order: the three tracks in their
# listed order), validated for CVD separation and contrast on both
# surfaces — light aqua is below 3:1, which the direct version labels
# on every car and engine relieve. Text stays in ink colors, never a
# series color.
if mode == "light":
    C = dict(bg="#fcfcfb", ink="#0b0b0b", ink2="#52514e",
             blue="#2a78d6", orange="#eb6834", aqua="#1baf7a",
             lamp="#fab219")
else:
    C = dict(bg="#1a1a19", ink="#f0efec", ink2="#c3c2b7",
             blue="#3987e5", orange="#d95926", aqua="#199e70",
             lamp="#eda100")

tracks = [
    ("go.dev", C["blue"], lanes["godev"], None,
     "upstream stable releases"),
    ("ubi go-fips", C["orange"], fips, fips_pre,
     "FIPS images on quay"),
    ("ubi", C["aqua"], lanes["plain"], None,
     "standard images on quay"),
]

# Shared axis: the union of every version any track shows, oldest first.
axis = sorted({v for _, _, vs, _, _ in tracks for v in vs} | {fips_pre} - {""},
              key=ver_key)
if not axis:
    sys.exit("ERROR: no versions gathered for any track")

# Fixed spacing, not a stretched plot: adjacent positions stay far
# enough apart for car + engine geometry at any axis length (an
# engine's nose reaches 50 units, a car 22).
SPACING = 110
LEFT, RIGHT, TOP = 210, 90, 88
H = 440
W = LEFT + RIGHT + SPACING * max(len(axis) - 1, 1)
row_y = [160, 262, 364]                  # rail-top y per track
AXIS_Y = H - 30

def x_of(ver):
    return LEFT + axis.index(ver) * SPACING

svg = []
svg.append('<?xml version="1.0" encoding="UTF-8"?>')
svg.append('<!-- generated by scripts/version-tracks.sh via '
           '.github/workflows/readme-tracks.yml; do not edit -->')
svg.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" '
           'role="img" aria-labelledby="tt td" font-family="-apple-system,'
           " 'Segoe UI', Helvetica, Arial, sans-serif\">")
svg.append('<title id="tt">Go version tracks</title>')
svg.append('<desc id="td">Latest stable Go version per source — go.dev '
           'upstream, the UBI go-fips images, and the standard UBI images — '
           'as trains on three tracks over a shared version axis; older '
           'releases trail behind each engine.</desc>')

css = """
<style>
  .spin { transform-box: fill-box; transform-origin: center;
          animation: spin 1.4s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .bob  { animation: bob 1.1s ease-in-out infinite alternate; }
  @keyframes bob { to { transform: translateY(1.5px); } }
  .puff { animation: puff 2.4s ease-out infinite;
          /* scale about the circle's own center; without this the
             default (0,0) origin drags the puff toward the top-left of
             the canvas instead of rising above the chimney */
          transform-box: fill-box; transform-origin: center; }
  @keyframes puff {
    0%   { opacity: 0;   transform: translate(0,0) scale(.4); }
    25%  { opacity: .45; }
    100% { opacity: 0;   transform: translate(14px,-30px) scale(1.5); }
  }
  @media (prefers-reduced-motion: reduce) {
    .spin, .bob, .puff { animation: none; }
  }
</style>
"""
svg.append(css)
svg.append(f'<rect width="{W}" height="{H}" rx="12" fill="{C["bg"]}"/>')
svg.append(f'<text x="20" y="34" font-size="16" font-weight="600" '
           f'fill="{C["ink"]}">Go version tracks</text>')
svg.append(f'<text x="20" y="54" font-size="11.5" fill="{C["ink2"]}">'
           'latest stable per source &#183; older releases trail behind '
           '&#183; refreshed weekly from go.dev and quay.io</text>')

# Shared version axis: faint dashed gridline + tick label per version.
for ver in axis:
    x = x_of(ver)
    svg.append(f'<line x1="{x:.1f}" y1="{TOP}" x2="{x:.1f}" y2="{AXIS_Y - 14}" '
               f'stroke="{C["ink2"]}" stroke-opacity=".25" stroke-width="1" '
               'stroke-dasharray="2 6"/>')
    svg.append(f'<text x="{x:.1f}" y="{AXIS_Y}" font-size="11.5" '
               f'text-anchor="middle" fill="{C["ink2"]}">{ver}</text>')

def wheel(cx, cy, r, color, spokes=True):
    s = [f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{C["bg"]}" '
         f'stroke="{color}" stroke-width="2"/>']
    if spokes:
        s.append(f'<g class="spin" stroke="{color}" stroke-width="1.6">')
        for rot in (0, 60, 120):
            a = math.radians(rot)
            dx, dy = r * 0.72 * math.cos(a), r * 0.72 * math.sin(a)
            s.append(f'<line x1="{cx - dx:.1f}" y1="{cy - dy:.1f}" '
                     f'x2="{cx + dx:.1f}" y2="{cy + dy:.1f}"/>')
        s.append('</g>')
    return "".join(s)

def car(cx, rail, color, opacity):
    """A trailing car centered at cx; wheels sit on the rail."""
    s = [f'<g opacity="{opacity}">']
    s.append(f'<rect x="{cx - 22}" y="{rail - 26}" width="44" height="17" '
             f'rx="4" fill="{color}"/>')
    s.append(wheel(cx - 12, rail - 5, 5, color, spokes=False))
    s.append(wheel(cx + 12, rail - 5, 5, color, spokes=False))
    s.append('</g>')
    return "".join(s)

def coupler(x1, x2, rail, color, ghost=False):
    dash = ' stroke-dasharray="4 3"' if ghost else ''
    return (f'<line x1="{x1:.1f}" y1="{rail - 17}" x2="{x2:.1f}" '
            f'y2="{rail - 17}" stroke="{color}" stroke-width="2"'
            f' stroke-opacity=".8"{dash}/>')

def engine(ex, rail, color, ver):
    """The locomotive, nose at ex+50, wheels on the rail."""
    s = [f'<g class="bob">']
    # cowcatcher
    s.append(f'<polygon points="{ex + 36},{rail - 24} {ex + 50},{rail - 2} '
             f'{ex + 36},{rail - 2}" fill="{color}"/>')
    # body
    s.append(f'<rect x="{ex - 40}" y="{rail - 34}" width="76" height="23" '
             f'rx="5" fill="{color}"/>')
    # cab
    s.append(f'<rect x="{ex - 40}" y="{rail - 52}" width="30" height="20" '
             f'rx="4" fill="{color}"/>')
    s.append(f'<rect x="{ex - 35}" y="{rail - 48}" width="12" height="10" '
             f'rx="2" fill="{C["bg"]}"/>')
    # chimney + steam
    s.append(f'<rect x="{ex + 8}" y="{rail - 50}" width="12" height="18" '
             f'rx="2" fill="{color}"/>')
    s.append('</g>')  # bob applies to the body, not the wheels
    for i, delay in enumerate((0, 0.8, 1.6)):
        s.append(f'<circle class="puff" cx="{ex + 14}" cy="{rail - 56}" '
                 f'r="4" fill="{C["ink2"]}" style="animation-delay:'
                 f'{delay}s"/>')
    # headlight
    s.append(f'<circle cx="{ex + 41}" cy="{rail - 30}" r="3.5" '
             f'fill="{C["lamp"]}"/>')
    # wheels
    for cx in (ex - 28, ex - 6, ex + 20):
        s.append(wheel(cx, rail - 7, 7, color))
    # version label
    s.append(f'<text x="{ex}" y="{rail - 62}" font-size="13" '
             f'font-weight="600" text-anchor="middle" '
             f'fill="{C["ink"]}">{ver}</text>')
    return "".join(s)

for (name, color, versions, ghost_ver, note), rail in zip(tracks, row_y):
    # oldest → newest regardless of the input order each source uses
    versions = sorted(set(versions), key=ver_key)[-(trail_n + 1):]
    # track label, left margin — the note column is wide enough that the
    # leftmost car never paints over it
    svg.append(f'<text x="20" y="{rail - 40}" font-size="14" '
               f'font-weight="600" fill="{C["ink"]}">{name}</text>')
    svg.append(f'<text x="20" y="{rail - 24}" font-size="10.5" '
               f'fill="{C["ink2"]}">{note}</text>')
    # rails: a running line with dashed ties beneath it
    svg.append(f'<line x1="{LEFT - 110}" y1="{rail}" x2="{W - 20}" '
               f'y2="{rail}" stroke="{C["ink2"]}" stroke-opacity=".55" '
               'stroke-width="2"/>')
    svg.append(f'<line x1="{LEFT - 110}" y1="{rail + 5}" x2="{W - 20}" '
               f'y2="{rail + 5}" stroke="{C["ink2"]}" stroke-opacity=".3" '
               'stroke-width="3" stroke-dasharray="3 10"/>')

    if not versions:
        svg.append(f'<text x="{LEFT}" y="{rail - 30}" font-size="12" '
                   f'font-style="italic" fill="{C["ink2"]}">'
                   'nothing published yet</text>')
        continue

    cars = sorted([v for v in versions if v != versions[-1]], key=ver_key)
    head = versions[-1]
    elements = cars + [head]  # oldest → engine
    # fading cars, oldest most transparent
    ops = [0.4, 0.6, 0.8][-len(cars):] if cars else []
    for v, op in zip(cars, ops):
        svg.append(car(x_of(v), rail, color, op))
        svg.append(f'<text x="{x_of(v):.1f}" y="{rail - 32}" font-size="10.5" '
                   f'text-anchor="middle" fill="{C["ink2"]}">{v}</text>')
    # couplers between consecutive elements
    for a, b in zip(elements, elements[1:]):
        svg.append(coupler(x_of(a) + 22, x_of(b) - 22, rail, color))
    svg.append(engine(x_of(head) - 10, rail, color, head))

    # ghost pre-release car ahead of the engine, dashed outline
    if ghost_ver and ghost_ver in axis and ver_key(ghost_ver) > ver_key(head):
        gx = x_of(ghost_ver)
        svg.append(f'<g stroke="{color}" fill="none" stroke-dasharray="5 3">'
                   f'<rect x="{gx - 22}" y="{rail - 26}" width="44" '
                   f'height="17" rx="4"/>'
                   f'<circle cx="{gx - 12}" cy="{rail - 5}" r="5"/>'
                   f'<circle cx="{gx + 12}" cy="{rail - 5}" r="5"/></g>')
        svg.append(f'<text x="{gx:.1f}" y="{rail - 32}" font-size="10.5" '
                   f'font-style="italic" text-anchor="middle" '
                   f'fill="{C["ink2"]}">{ghost_ver} pre</text>')
        svg.append(coupler(x_of(head) + 50, gx - 22, rail, color, ghost=True))

svg.append('</svg>')
print("\n".join(svg))
PY
