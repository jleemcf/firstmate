#!/usr/bin/env bash
# Refuse a no-mistakes publication unless the validated head contains the
# current upstream default-branch tip.
#
# firstmate wires this executable into no-mistakes' trusted commands.format
# slot, which runs after validation and immediately before the Push step's
# commit and remote mutation.
# The guard deliberately chooses refusal instead of another rebase because the
# pipeline already owns branch custody and validation; rewriting here would
# publish a head the completed validation steps never exercised.
#
# The current base comes from one live `git ls-remote --symref origin HEAD`
# observation, then an exact fetch of that advertised branch into FETCH_HEAD.
# The branch is not moved and no named ref is written.
# If the remote default, its commit, the fetch, or ancestry cannot be proved,
# publication is refused.
# A default branch that moves between observation and fetch is also refused so
# a racing read cannot certify either tip.
#
# Usage: fm-nm-publish-guard.sh
set -eu

refuse() {
  printf 'fm-nm-publish-guard: REFUSED: %s\n' "$*" >&2
  exit 1
}

[ "$#" -eq 0 ] || refuse "this guard accepts no arguments"
[ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ] \
  || refuse "the publication directory is not a Git worktree"

remote_view=$(LC_ALL=C git ls-remote --symref origin HEAD 2>/dev/null) \
  || refuse "could not read origin's current default branch"

default_ref=$(printf '%s\n' "$remote_view" | awk '
  $1 == "ref:" && $3 == "HEAD" { count++; value=$2 }
  END { if (count == 1 && value != "") print value; else exit 1 }
') || refuse "could not determine origin's current default branch"
advertised_head=$(printf '%s\n' "$remote_view" | awk '
  $2 == "HEAD" { count++; value=$1 }
  END { if (count == 1 && value != "") print value; else exit 1 }
') || refuse "could not determine origin's current default-branch commit"

case "$default_ref" in
  refs/heads/*) ;;
  *) refuse "origin's advertised default branch is not a branch ref" ;;
esac
git check-ref-format "$default_ref" >/dev/null 2>&1 \
  || refuse "origin's advertised default branch is invalid"

if ! git fetch --no-tags --quiet origin "$default_ref"; then
  refuse "could not fetch origin's current default branch"
fi
fetched_head=$(git rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null) \
  || refuse "the fetched default-branch tip is not a commit"
[ "$fetched_head" = "$advertised_head" ] \
  || refuse "origin's default branch moved while publication safety was being checked"
validated_head=$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
  || refuse "the validated publication head is not a commit"

if ! git merge-base --is-ancestor "$fetched_head" "$validated_head" 2>/dev/null; then
  refuse "the validated publication head does not contain origin/${default_ref#refs/heads/}"
fi

printf 'fm-nm-publish-guard: verified: validated head contains current origin/%s\n' \
  "${default_ref#refs/heads/}"
