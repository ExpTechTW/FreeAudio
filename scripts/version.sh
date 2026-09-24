#!/usr/bin/env bash
# The one place a build's version is decided; scripts/build-app.sh and the release workflow read it from here. Same
# scheme as DPIP (ExpTechTW/DPIP, tool/release/version.sh):
#
#            release     snapshot
#   label    26.1        26w39a       the name people see: the GitHub release's title, shown in the app
#   train    26.1        26.2         CFBundleShortVersionString; a snapshot carries the release it leads to
#   code     126000042   126000043    CFBundleVersion, the only thing that says which build is newer
#   date     26-09-24    26-09-24     the day of the commit, Taipei time
#
# Names can't be compared: a snapshot named after a later week can come before the release it became. The code only
# ever rises, so that's what the updater compares.
#
#   eval "$(scripts/version.sh)"      FREEAUDIO_LABEL, _TRAIN, _CODE, _DATE and _PRERELEASE
#   scripts/version.sh --json
#   scripts/version.sh --snapshot     a snapshot even if HEAD carries a release tag, as for a push to main
#
# Needs the full history: actions/checkout with fetch-depth: 0.
set -euo pipefail

# code = <generation><yy><commits this year>: 126000042 is generation 1, 2026, the 42nd commit of 2026. A new year
# adds 1,000,000 while the count starts over, so the code still rises. The generation only changes if the scheme does.
readonly SCHEME=1

# Taipei time, as in DPIP: the week in a label is the week of the people reading it.
readonly TZONE='Asia/Taipei'

snapshot_only=0
json=0
for arg in "$@"; do
  case "$arg" in
  --snapshot) snapshot_only=1 ;;
  --json) json=1 ;;
  *)
    echo "usage: $0 [--snapshot] [--json]" >&2
    exit 2
    ;;
  esac
done

commit_ts="$(git log -1 --format=%ct HEAD)"
stamp() { # <format>
  TZ="$TZONE" date -r "$commit_ts" "+$1" 2>/dev/null || TZ="$TZONE" date -d "@$commit_ts" "+$1"
}

year="$(stamp %y)"
commits="$(git rev-list --count HEAD --since="$(stamp %Y)-01-01T00:00:00+08:00")"
code=$((SCHEME * 100000000 + 10#$year * 1000000 + commits))
date="$(stamp %y-%m-%d)"

# 0 → a, 25 → z, 26 → aa
letters() { # <n>
  local i="$1" out=""
  while :; do
    out="$(printf "\\$(printf '%03o' $((97 + i % 26)))")$out"
    i=$((i / 26 - 1))
    [ "$i" -lt 0 ] && break
  done
  printf '%s' "$out"
}

# Only a `v` tag makes a release. Snapshots are tagged with their bare label (26w39a), so the two never collide.
exact_tag=""
if [ "$snapshot_only" = 0 ]; then
  exact_tag="$(git tag --points-at HEAD --list 'v[0-9]*' --sort=-v:refname | head -n 1)"
fi
last_tag="$(git tag --list 'v[0-9]*' --sort=-v:refname | head -n 1)"

if [ -n "$exact_tag" ]; then
  label="${exact_tag#v}"
  prerelease=false
  if [[ "$label" =~ ^([0-9]+)\.([0-9]+) ]]; then
    train="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  else
    train="$label"
  fi
else
  prerelease=true
  # A commit that's already out keeps its name.
  label="$(git tag --points-at HEAD --list '[0-9][0-9]w[0-9][0-9]*' | head -n 1)"
  if [ -z "$label" ]; then
    # The letter counts the snapshots already published this week, so this build is the next one. Published, not
    # committed: a push carries several commits but makes one build.
    prefix="${year}w$(stamp %V)"
    n="$(git tag --list "${prefix}*" | wc -l | tr -d ' ')"
    label="${prefix}$(letters "$n")"
    # A tag the count missed (a run that failed after tagging, a tag deleted by hand): walk past it.
    while git rev-parse -q --verify "refs/tags/$label" >/dev/null; do
      n=$((n + 1))
      label="${prefix}$(letters "$n")"
    done
  fi
  # The release this snapshot leads to: the next number after the newest release, or the year's first.
  train="${year}.1"
  if [ -n "$last_tag" ]; then
    tag_year="${last_tag#v}"
    tag_year="${tag_year%%.*}"
    tag_seq="${last_tag#v*.}"
    tag_seq="${tag_seq%%.*}"
    if [ "$tag_year" = "$year" ]; then
      train="${year}.$((tag_seq + 1))"
    fi
  fi
fi

if [ "$json" = 1 ]; then
  printf '{"label":"%s","train":"%s","code":%s,"date":"%s","prerelease":%s}\n' \
    "$label" "$train" "$code" "$date" "$prerelease"
else
  printf 'FREEAUDIO_LABEL=%s\nFREEAUDIO_TRAIN=%s\nFREEAUDIO_CODE=%s\nFREEAUDIO_DATE=%s\nFREEAUDIO_PRERELEASE=%s\n' \
    "$label" "$train" "$code" "$date" "$prerelease"
fi
