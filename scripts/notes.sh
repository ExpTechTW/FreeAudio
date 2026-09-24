#!/usr/bin/env bash
# Writes a release's notes from the changelog lines its commits carry (see commit.md):
#
#   New(zh-Hant): 可以從 GitHub 自動更新
#   New(en-US): FreeAudio updates itself from GitHub
#
# A snapshot lists what changed since the previous published build. A release lists everything since the previous
# release: someone going from 26.1 to 26.2 never saw the snapshots in between. Same format as DPIP's
# tool/release/notes.sh.
#
#   scripts/notes.sh <label> <code> [--release] > NOTES.md
set -euo pipefail

label="${1:?usage: scripts/notes.sh <label> <code> [--release]}"
code="${2:?usage: scripts/notes.sh <label> <code> [--release]}"
kind="${3:-}"
repo="${GITHUB_REPOSITORY:-ExpTechTW/FreeAudio}"

# Printed first and unfolded; every other language is folded underneath.
readonly PRIMARY='zh-Hant'
readonly LINE_RE='^(New|Optimization|Fix)\(([A-Za-z]{2,3}(-[A-Za-z0-9]+)*)\):[[:space:]]*(.+)$'

heading_for() { # <category> <locale>
  case "$2::$1" in
  zh-Hant::New) printf '🌟 新功能' ;;
  zh-Hant::Optimization) printf '🔌 最佳化' ;;
  zh-Hant::Fix) printf '🐞 錯誤修正' ;;
  ja-JP::New) printf '🌟 新機能' ;;
  ja-JP::Optimization) printf '🔌 改善' ;;
  ja-JP::Fix) printf '🐞 不具合修正' ;;
  *::New) printf '🌟 New features' ;;
  *::Optimization) printf '🔌 Improvements' ;;
  *::Fix) printf '🐞 Bug fixes' ;;
  esac
}

language_name() { # <locale>
  case "$1" in
  en-US) printf 'English' ;;
  ja-JP) printf '日本語' ;;
  *) printf '%s' "$1" ;;
  esac
}

if [ "$kind" = "--release" ]; then
  since="$(git tag --list 'v[0-9]*' --sort=-v:refname | grep -vx "v$label" | head -n 1 || true)"
else
  since="$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || true)"
fi
range="${since:+$since..}HEAD"

# Co-authored-by trailers: `@login` when the address carries one, the name otherwise.
trailer_authors() { # <sha>
  local email name
  git log -1 --format=%b "$1" |
    sed -n 's/^[Cc]o-authored-by: *\(.*\) <\(.*\)>.*/\2|\1/p' |
    while IFS='|' read -r email name; do
      case "$email" in
      *+*@users.noreply.github.com)
        email="${email#*+}"
        printf '@%s\n' "${email%@users.noreply.github.com}"
        ;;
      *) printf '%s\n' "$name" ;;
      esac
    done
}

# Who wrote an entry, as GitHub logins so the note can @ them: the trailers first, then the commit's author on GitHub,
# then the name in git when neither is known (no network, or no gh).
authors_of() { # <sha>
  local sha="$1" logins
  logins="$(trailer_authors "$sha")"
  # On an error gh prints the response body, which isn't a name.
  if [ -z "$logins" ] && command -v gh >/dev/null 2>&1; then
    logins="$(gh api "repos/$repo/commits/$sha" --jq '.author.login // empty | "@" + .' 2>/dev/null)" || logins=""
  fi
  [ -n "$logins" ] || logins="$(git log -1 --format=%an "$sha")"
  printf '%s\n' "$logins" | awk 'NF && !seen[$0]++' | paste -sd ',' - | sed 's/,/, /g'
}

# The first snapshot an entry shipped in, so someone who runs snapshots sees what they already have. Only in a
# release's notes; a snapshot's entries all come from itself.
first_seen_in() { # <sha>
  [ "$kind" = "--release" ] || return 0
  git tag --list '[0-9][0-9]w[0-9][0-9]*' --contains "$1" --sort=creatordate 2>/dev/null | head -n 1
}

# One file per category and language: macOS still ships bash 3.2, which has no associative arrays.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

locales=""
for sha in $(git rev-list --no-merges --reverse "$range"); do
  # An entry may be hard-wrapped; fold indented continuation lines back onto it.
  body="$(git log -1 --format=%b "$sha" | awk '
    /^[[:space:]]+[^[:space:]]/ && held { sub(/^[[:space:]]+/, " "); printf "%s", $0; next }
    { if (held) printf "\n"; printf "%s", $0; held = 1 }
    END { if (held) printf "\n" }
  ')"
  printf '%s\n' "$body" | grep -Eq "$LINE_RE" || continue

  who="$(authors_of "$sha")"
  short="$(git rev-parse --short "$sha")"
  seen="$(first_seen_in "$sha")"
  while IFS= read -r line; do
    printf '%s\n' "$line" | grep -Eq "$LINE_RE" || continue
    category="$(printf '%s\n' "$line" | sed -E "s/$LINE_RE/\\1/")"
    locale="$(printf '%s\n' "$line" | sed -E "s/$LINE_RE/\\2/")"
    text="$(printf '%s\n' "$line" | sed -E "s/$LINE_RE/\\4/")"
    printf -- '- %s — %s ([`%s`](https://github.com/%s/commit/%s))%s\n' \
      "$text" "$who" "$short" "$repo" "$sha" "${seen:+ · \`$seen\`}" >>"$work/$category.$locale"
    case " $locales " in
    *" $locale "*) ;;
    *) locales="$locales $locale" ;;
    esac
  done <<EOF
$body
EOF
done

section() { # <locale>
  local any=0 category
  for category in New Optimization Fix; do
    [ -s "$work/$category.$1" ] || continue
    any=1
    printf '### %s\n\n' "$(heading_for "$category" "$1")"
    cat "$work/$category.$1"
    printf '\n'
  done
  if [ "$any" = 0 ]; then
    case "$1" in
    zh-Hant) printf '_沒有使用者可見的變更。_\n\n' ;;
    ja-JP) printf '_ユーザーに見える変更はありません。_\n\n' ;;
    *) printf '_No user-facing changes._\n\n' ;;
    esac
  fi
}

{
  # No heading: GitHub already shows the release's title above its notes.
  if [ "$kind" = "--release" ]; then
    if [ -n "$since" ]; then printf '_自 %s 以來的全部變更。_\n\n' "$since"; fi
  else
    printf '_快照，取自 main 的 `%s`。未經審查，可能有問題。_\n\n' "$(git rev-parse --short HEAD)"
  fi

  section "$PRIMARY"
  # Alphabetical, so the order doesn't change from one build to the next.
  for locale in $(printf '%s\n' $locales | grep -vx "$PRIMARY" | sort); do
    printf '<details>\n<summary>%s</summary>\n\n' "$(language_name "$locale")"
    section "$locale"
    printf '</details>\n\n'
  done

  if [ "$kind" = "--release" ] && [ -n "$since" ]; then
    printf -- '---\n\n**完整差異 / Full changelog**: https://github.com/%s/compare/%s...v%s\n\n' "$repo" "$since" "$label"
  fi

  # Invisible on the page. The updater compares it with the build that's running (Release.code in Update.swift), and
  # the release workflow checks a new build is above it.
  printf '<!-- freeaudio-build: %s -->\n' "$code"
}
