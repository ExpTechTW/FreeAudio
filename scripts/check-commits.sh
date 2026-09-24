#!/usr/bin/env bash
# Rejects a commit message the release notes can't be built from. The message is the changelog: scripts/notes.sh
# publishes its entry lines, and a pushed message can only be fixed by rewriting history. The rules are in commit.md;
# this is DPIP's gate (ExpTechTW/DPIP, tool/check/commits.sh) with FreeAudio's languages.
#
#   scripts/check-commits.sh                     HEAD
#   scripts/check-commits.sh origin/main..HEAD   every commit in a range
#   scripts/check-commits.sh --message <file>    a draft, before it's committed (.githooks/commit-msg)
set -uo pipefail

mode=range
range="${1:-HEAD~1..HEAD}"
if [ "${1:-}" = "--message" ]; then
  mode=message
  msg_file="${2:?--message needs a file}"
fi

# Types a user sees, which therefore need entries. The rest may have none.
readonly USER_FACING='feat|fix|perf'
readonly ALL_TYPES='feat|fix|perf|refactor|docs|test|chore|build|ci|style|revert'

# One entry per line:  Category(locale): text
readonly LINE_RE='^(New|Optimization|Fix)\(([A-Za-z]{2,3}(-[A-Za-z0-9]+)*)\):[[:space:]]*(.+)$'

# The app's own language, and the one everyone else falls back to.
readonly REQUIRED_LOCALES='zh-Hant en-US'
# The languages FreeAudio ships (Sources/FreeAudio/Resources). A misspelt one would publish a block nobody reads.
readonly KNOWN_LOCALES='zh-Hant en-US ja-JP'

readonly SUMMARY_MAX=72

fail=0
note() {
  printf '  %s\n' "$1" >&2
}

check_one() { # <subject> <body> <label>
  local subject body short bad entries cand loc category base n
  subject="$1"
  body="$2"
  short="$3"
  bad=0

  # GitHub appends ` (#123)` to a merged pull request's summary; judge what the author wrote.
  subject="$(printf '%s' "$subject" | sed -E 's/ \(#[0-9]+\)$//')"

  # 1. The summary line.
  if ! printf '%s' "$subject" | grep -Eq "^($ALL_TYPES)(\([a-z0-9._-]+\))?: .+"; then
    note "summary must be '<type>(<scope>): <summary>' with type one of: ${ALL_TYPES//|/, }"
    bad=1
  fi
  if [ "${#subject}" -gt "$SUMMARY_MAX" ]; then
    note "summary is ${#subject} characters; the limit is $SUMMARY_MAX"
    bad=1
  fi
  case "$subject" in
  *.)
    note "summary must not end with a period"
    bad=1
    ;;
  esac
  # English, so the log reads in one voice. Tested as ASCII: BSD grep has no -P.
  if printf '%s' "$subject" | LC_ALL=C grep -q '[^ -~]'; then
    note "summary must be plain-ASCII English — 中文 belongs in the entry lines"
    bad=1
  fi

  # 2. A commit is authored by a person. A tool that credits itself makes the history lie about who is accountable.
  #    A person credited in a trailer is fine.
  if printf '%s' "$body" |
    grep -Eqi '^(Co-authored-by|Signed-off-by):.*(claude|copilot|cursor|gpt|codex|gemini|\[bot\]|noreply@anthropic|openai)'; then
    note "no tool in a Co-authored-by / Signed-off-by trailer"
    bad=1
  fi
  if printf '%s' "$body" | grep -Eqi 'generated with|🤖|claude\.com|openai\.com'; then
    note "no tool attribution in the message"
    bad=1
  fi

  # 3. Changelog entries, which scripts/notes.sh publishes.
  entries="$(printf '%s\n' "$body" | grep -E "$LINE_RE" || true)"

  # A line that looks like an entry but doesn't match is silently left out of the notes; `en_US` is the likely one.
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    printf '%s' "$cand" | grep -Eq "$LINE_RE" || {
      note "malformed entry: $cand"
      note "  expected  Category(locale): text  e.g. New(en-US): FreeAudio updates itself"
      bad=1
    }
  done <<EOF
$(printf '%s\n' "$body" | grep -E '^(New|Optimization|Fix)[ (]' || true)
EOF

  for loc in $(printf '%s\n' "$entries" | sed -E "s/$LINE_RE/\\2/" | sort -u); do
    case " $KNOWN_LOCALES " in
    *" $loc "*) ;;
    *)
      note "unknown locale '$loc' — one of: ${KNOWN_LOCALES// /, }"
      bad=1
      ;;
    esac
  done

  if printf '%s' "$subject" | grep -Eq "^($USER_FACING)(\(|:)"; then
    if [ -z "$entries" ]; then
      note "a feat/fix/perf commit needs at least one 'New|Optimization|Fix(<locale>): ...' line"
      bad=1
    else
      for loc in $REQUIRED_LOCALES; do
        printf '%s\n' "$entries" | grep -Eq "^[A-Za-z]+\($loc\):" || {
          note "missing $loc entries — every published entry needs one"
          bad=1
        }
      done
      # The languages are published as parallel lists; one written in one language and forgotten in another would
      # ship a shorter list to those readers.
      for category in New Optimization Fix; do
        base="$(printf '%s\n' "$entries" | grep -Ec "^$category\(zh-Hant\):" || true)"
        for loc in $(printf '%s\n' "$entries" | sed -E "s/$LINE_RE/\\2/" | sort -u); do
          [ "$loc" != zh-Hant ] || continue
          n="$(printf '%s\n' "$entries" | grep -Ec "^$category\($loc\):" || true)"
          [ "$n" -eq 0 ] || [ "$n" -eq "$base" ] || {
            note "$category has $base zh-Hant entries but $n for $loc — they must pair up"
            bad=1
          }
        done
      done
    fi
  fi

  if [ "$bad" -ne 0 ]; then
    printf '\n✗ %s  %s\n' "$short" "$subject" >&2
    fail=1
  fi
}

if [ "$mode" = message ]; then
  # What git will record: no comment lines, nothing under the scissors line `git commit -v` adds.
  draft="$(sed -e '/^# -\{24\} >8 -\{24\}$/,$d' -e '/^#/d' "$msg_file")"
  subject="$(printf '%s\n' "$draft" | sed -n '1p')"
  # Folded into another commit by `git rebase --autosquash`; that commit's message is the one that stays.
  case "$subject" in
  fixup!* | squash!* | amend!*) exit 0 ;;
  esac
  check_one "$subject" "$(printf '%s\n' "$draft" | sed '1d')" "draft"
else
  commits="$(git rev-list --no-merges "$range" 2>/dev/null || true)"
  if [ -z "$commits" ]; then
    echo "commit gate: no commits in $range"
    exit 0
  fi
  for sha in $commits; do
    check_one "$(git log -1 --format=%s "$sha")" "$(git log -1 --format=%b "$sha")" "$(git log -1 --format=%h "$sha")"
  done
fi

if [ "$fail" -ne 0 ]; then
  if [ "$mode" = message ]; then
    printf '\nNothing was committed. Fix the message and commit again; the format is in commit.md.\n' >&2
  else
    cat >&2 <<'EOF'

A pushed message can't be edited, so fix it by rewriting the commits:

    git rebase -i <base>          # mark them `reword`
    git push --force-with-lease

The format is in commit.md.
EOF
  fi
  exit 1
fi

if [ "$mode" = message ]; then
  echo "commit gate: the message is OK"
else
  echo "commit gate: $(printf '%s\n' "$commits" | wc -l | tr -d ' ') commit(s) OK"
fi
