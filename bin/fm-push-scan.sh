#!/usr/bin/env bash
# Guard a branch push with one explicitly selected fleet-local term list.
#
# The selected list is resolved only below the absolute fleet home, never from
# the caller's current directory. FM_HOME defaults to this script's repository
# root; when set, it must itself be absolute. The two directions stay separate:
#   company   config/company-push-terms.txt (tooling identity entering company code)
#   sensitive config/sensitive-terms.txt (private/project identity entering public code)
#
# Comment lines (optionally indented) and blank lines are removed before use.
# Every attempted scan prints the loaded-pattern count before any result. A
# missing, non-regular, unreadable, invalid, or zero-pattern list prints no
# clean/hit result and exits 2. A completed clean scan exits 0; any hit exits 1.
# Hit records reveal only the publication file/surface, matching line numbers,
# and matching-line count. They never echo a matched pattern or source text.
#
# Every completed scan covers git diff origin/main...HEAD, the branch name, all
# commit messages and authors in origin/main..HEAD, and the exact pull-request
# title and body supplied as files. Both PR files are mandatory, including when
# rescanning text read back from a published pull request.
#
# Repeat --evidence-file for every artifact that could be published or linked
# from the pull request. Evidence is always scanned against the sensitive list,
# separately from the selected repository-direction list, and also rejects an
# unredacted current-operator home path. An evidence scan cannot silently fall
# back to the company list.
#
# The redact-evidence mode consumes raw evidence on stdin and atomically writes
# only a redacted artifact. It replaces the current absolute home and ~/ prefix
# with <HOME> before any bytes reach the destination file.
#
# Usage:
#   fm-push-scan.sh <company|sensitive> --pr-title-file <path> --pr-body-file <path> [--evidence-file <path>]...
#   fm-push-scan.sh redact-evidence --output <path>
#   fm-push-scan.sh --help
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
OPERATOR_HOME=${HOME:-}
[ "$OPERATOR_HOME" != / ] || OPERATOR_HOME=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

redact_value() { # <value>; sets REDACTED_VALUE
  REDACTED_VALUE=$1
  if [ -n "$OPERATOR_HOME" ]; then
    REDACTED_VALUE=${REDACTED_VALUE//"$OPERATOR_HOME"/<HOME>}
  fi
  REDACTED_VALUE=${REDACTED_VALUE//\~\//<HOME>\/}
}

fail_before_patterns() { # <list-kind> <list-path> <diagnostic>
  printf 'fm-push-scan: patterns loaded: 0 (list=%s, path=%s)\n' "$1" "$2"
  printf 'fm-push-scan: error: %s\n' "$3" >&2
  exit 2
}

fail_after_patterns() { # <diagnostic>
  printf 'fm-push-scan: error: %s\n' "$1" >&2
  exit 2
}

emit_scan_record() { # <record-kind> <record>
  local record_kind=$1 record=$2
  if ! printf '%s\n' "$record"; then
    fail_after_patterns "could not write $record_kind scan record"
  fi
}

redact_evidence() {
  local output='' output_dir output_base tmp_output='' line
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --output)
        [ "$#" -ge 2 ] || { printf 'fm-push-scan: error: --output requires a path.\n' >&2; exit 2; }
        [ -z "$output" ] || { printf 'fm-push-scan: error: --output may be provided only once.\n' >&2; exit 2; }
        output=$2
        shift 2
        ;;
      --output=*)
        [ -z "$output" ] || { printf 'fm-push-scan: error: --output may be provided only once.\n' >&2; exit 2; }
        output=${1#*=}
        shift
        ;;
      *)
        printf 'fm-push-scan: error: unknown redact-evidence argument.\n' >&2
        exit 2
        ;;
    esac
  done
  [ -n "$output" ] || { printf 'fm-push-scan: error: redact-evidence requires --output.\n' >&2; exit 2; }
  output_dir=${output%/*}
  output_base=${output##*/}
  [ "$output_dir" != "$output" ] || output_dir=.
  [ -d "$output_dir" ] || { printf 'fm-push-scan: error: evidence output directory does not exist.\n' >&2; exit 2; }
  umask 077
  tmp_output=$(mktemp "$output_dir/.${output_base}.redacted.XXXXXX") || {
    printf 'fm-push-scan: error: could not create redacted evidence output.\n' >&2
    exit 2
  }
  trap 'rm -f "$tmp_output"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  while IFS= read -r line || [ -n "$line" ]; do
    redact_value "$line"
    if ! printf '%s\n' "$REDACTED_VALUE" >> "$tmp_output"; then
      printf 'fm-push-scan: error: could not write redacted evidence output.\n' >&2
      exit 2
    fi
  done
  if ! mv -f "$tmp_output" "$output"; then
    printf 'fm-push-scan: error: could not publish redacted evidence output locally.\n' >&2
    exit 2
  fi
  tmp_output=
  trap - EXIT HUP INT TERM
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  redact-evidence)
    redact_evidence "$@"
    exit 0
    ;;
esac

[ "$#" -ge 1 ] || {
  printf 'fm-push-scan: error: select exactly one list: company or sensitive.\n' >&2
  usage >&2
  exit 2
}
LIST_KIND=$1
shift
case "$LIST_KIND" in
  company) LIST_REL=config/company-push-terms.txt ;;
  sensitive) LIST_REL=config/sensitive-terms.txt ;;
  *)
    printf 'fm-push-scan: error: select exactly company or sensitive.\n' >&2
    exit 2
    ;;
esac

PR_TITLE_FILE=
PR_BODY_FILE=
EVIDENCE_FILES=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr-title-file)
      [ "$#" -ge 2 ] || { printf 'fm-push-scan: error: --pr-title-file requires a path.\n' >&2; exit 2; }
      [ -z "$PR_TITLE_FILE" ] || { printf 'fm-push-scan: error: --pr-title-file may be provided only once.\n' >&2; exit 2; }
      PR_TITLE_FILE=$2
      shift 2
      ;;
    --pr-title-file=*)
      [ -z "$PR_TITLE_FILE" ] || { printf 'fm-push-scan: error: --pr-title-file may be provided only once.\n' >&2; exit 2; }
      PR_TITLE_FILE=${1#*=}
      shift
      ;;
    --pr-body-file)
      [ "$#" -ge 2 ] || { printf 'fm-push-scan: error: --pr-body-file requires a path.\n' >&2; exit 2; }
      [ -z "$PR_BODY_FILE" ] || { printf 'fm-push-scan: error: --pr-body-file may be provided only once.\n' >&2; exit 2; }
      PR_BODY_FILE=$2
      shift 2
      ;;
    --pr-body-file=*)
      [ -z "$PR_BODY_FILE" ] || { printf 'fm-push-scan: error: --pr-body-file may be provided only once.\n' >&2; exit 2; }
      PR_BODY_FILE=${1#*=}
      shift
      ;;
    --evidence-file)
      [ "$#" -ge 2 ] || { printf 'fm-push-scan: error: --evidence-file requires a path.\n' >&2; exit 2; }
      EVIDENCE_FILES+=("$2")
      shift 2
      ;;
    --evidence-file=*)
      EVIDENCE_FILES+=("${1#*=}")
      shift
      ;;
    --)
      shift
      [ "$#" -eq 0 ] || { printf 'fm-push-scan: error: unexpected positional arguments.\n' >&2; exit 2; }
      ;;
    *)
      printf 'fm-push-scan: error: unknown argument.\n' >&2
      exit 2
      ;;
  esac
done
[ -n "$PR_TITLE_FILE" ] || { printf 'fm-push-scan: error: --pr-title-file is required.\n' >&2; exit 2; }
[ -n "$PR_BODY_FILE" ] || { printf 'fm-push-scan: error: --pr-body-file is required.\n' >&2; exit 2; }

HOME_INPUT=${FM_HOME:-$SCRIPT_ROOT}
case "$HOME_INPUT" in
  /*) ;;
  *)
    redact_value "$HOME_INPUT/$LIST_REL"
    fail_before_patterns "$LIST_KIND" "$REDACTED_VALUE" \
      "FM_HOME must be an absolute directory"
    ;;
esac
if [ -d "$HOME_INPUT" ]; then
  FLEET_HOME=$(CDPATH='' cd -- "$HOME_INPUT" 2>/dev/null && pwd -P) || {
    redact_value "$HOME_INPUT/$LIST_REL"
    fail_before_patterns "$LIST_KIND" "$REDACTED_VALUE" \
      "fleet home cannot be resolved"
  }
else
  FLEET_HOME=$HOME_INPUT
fi
LIST_PATH="$FLEET_HOME/$LIST_REL"
redact_value "$LIST_PATH"
LIST_DISPLAY=$REDACTED_VALUE

[ -e "$LIST_PATH" ] || \
  fail_before_patterns "$LIST_KIND" "$LIST_DISPLAY" \
    "$LIST_KIND pattern list is missing: $LIST_DISPLAY"
[ -f "$LIST_PATH" ] && [ -r "$LIST_PATH" ] || \
  fail_before_patterns "$LIST_KIND" "$LIST_DISPLAY" \
    "$LIST_KIND pattern list is not a readable regular file: $LIST_DISPLAY"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-push-scan.XXXXXX") || \
  fail_before_patterns "$LIST_KIND" "$LIST_DISPLAY" "could not create a private scan directory"
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

load_pattern_list() { # <kind> <path> <destination> <scope>; sets LOADED_PATTERN_COUNT
  local kind=$1 path=$2 destination=$3 scope=$4 display
  redact_value "$path"
  display=$REDACTED_VALUE
  [ -e "$path" ] || fail_before_patterns "$kind" "$display" "$kind pattern list is missing: $display"
  [ -f "$path" ] && [ -r "$path" ] || \
    fail_before_patterns "$kind" "$display" "$kind pattern list is not a readable regular file: $display"
  if ! awk '
    {
      sub(/\r$/, "")
      if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next
      print
    }
  ' "$path" > "$destination"; then
    fail_before_patterns "$kind" "$display" "$kind pattern list could not be read: $display"
  fi
  LOADED_PATTERN_COUNT=$(awk 'END { print NR + 0 }' "$destination")
  if [ "$scope" = repository ]; then
    emit_scan_record "loaded-pattern count" \
      "fm-push-scan: patterns loaded: $LOADED_PATTERN_COUNT (list=$kind, path=$display)"
  else
    emit_scan_record "loaded-pattern count" \
      "fm-push-scan: patterns loaded: $LOADED_PATTERN_COUNT (scope=$scope, list=$kind, path=$display)"
  fi
  [ "$LOADED_PATTERN_COUNT" -gt 0 ] || \
    fail_after_patterns "$kind pattern list yielded zero usable patterns after comments and blank lines were removed: $display"
  if ! exec 3> "$TMP_ROOT/grep-error"; then
    fail_after_patterns "opening the regular-expression diagnostic output failed"
  fi
  LC_ALL=C grep -aEi -f "$destination" /dev/null >/dev/null 2>&3
  GREP_RC=$?
  exec 3>&-
  case "$GREP_RC" in
    0|1) ;;
    *) fail_after_patterns "$kind pattern list contains an invalid extended regular expression" ;;
  esac
}

PRIMARY_PATTERNS="$TMP_ROOT/patterns"
load_pattern_list "$LIST_KIND" "$LIST_PATH" "$PRIMARY_PATTERNS" repository
PRIMARY_PATTERN_COUNT=$LOADED_PATTERN_COUNT

redact_value "$PR_TITLE_FILE"
PR_TITLE_DISPLAY=$REDACTED_VALUE
redact_value "$PR_BODY_FILE"
PR_BODY_DISPLAY=$REDACTED_VALUE
[ -f "$PR_TITLE_FILE" ] && [ -r "$PR_TITLE_FILE" ] || \
  fail_after_patterns "pull-request title is not a readable regular file: $PR_TITLE_DISPLAY"
[ -f "$PR_BODY_FILE" ] && [ -r "$PR_BODY_FILE" ] || \
  fail_after_patterns "pull-request body is not a readable regular file: $PR_BODY_DISPLAY"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || \
  fail_after_patterns "current directory is not inside a git repository"
REPO_ROOT=$(CDPATH='' cd -- "$REPO_ROOT" 2>/dev/null && pwd -P) || \
  fail_after_patterns "git repository root cannot be resolved"
git -C "$REPO_ROOT" rev-parse --verify 'origin/main^{commit}' >/dev/null 2>&1 || \
  fail_after_patterns "required base origin/main is missing or is not a commit"
BRANCH=$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null) || \
  fail_after_patterns "HEAD is detached; a branch name is required for the scan"

DIFF_FILE="$TMP_ROOT/diff"
BRANCH_FILE="$TMP_ROOT/branch"
MESSAGES_FILE="$TMP_ROOT/commit-messages"
AUTHORS_FILE="$TMP_ROOT/commit-authors"
TITLE_FILE="$TMP_ROOT/pull-request-title"
BODY_FILE="$TMP_ROOT/pull-request-body"
if ! git -C "$REPO_ROOT" --no-pager diff --no-ext-diff --no-color origin/main...HEAD -- > "$DIFF_FILE"; then
  fail_after_patterns "git diff origin/main...HEAD failed"
fi
if ! printf '%s\n' "$BRANCH" > "$BRANCH_FILE"; then
  fail_after_patterns "materializing the branch scan source failed"
fi
if ! git -C "$REPO_ROOT" --no-pager log --format=%B origin/main..HEAD > "$MESSAGES_FILE"; then
  fail_after_patterns "reading commit messages from origin/main..HEAD failed"
fi
if ! git -C "$REPO_ROOT" --no-pager log --format='%an <%ae>' origin/main..HEAD > "$AUTHORS_FILE"; then
  fail_after_patterns "reading commit authors from origin/main..HEAD failed"
fi
if ! cat < "$PR_TITLE_FILE" > "$TITLE_FILE"; then
  fail_after_patterns "pull-request title could not be read: $PR_TITLE_DISPLAY"
fi
if ! cat < "$PR_BODY_FILE" > "$BODY_FILE"; then
  fail_after_patterns "pull-request body could not be read: $PR_BODY_DISPLAY"
fi

ACTIVE_LABELS=(diff branch commit-messages commit-authors pull-request-title pull-request-body)
ACTIVE_FILES=("$DIFF_FILE" "$BRANCH_FILE" "$MESSAGES_FILE" "$AUTHORS_FILE" "$TITLE_FILE" "$BODY_FILE")
ACTIVE_PATTERNS=$PRIMARY_PATTERNS
ACTIVE_PATTERN_COUNT=$PRIMARY_PATTERN_COUNT
ACTIVE_EVIDENCE=0
HITS=0

append_match_lines() { # <matches-file> <hit-lines-file> <label>
  local matches=$1 hit_lines=$2 label=$3 match line_number match_count=0
  if ! exec 4< "$matches"; then
    fail_after_patterns "opening the match input for $label failed"
  fi
  while IFS= read -r match <&4 || [ -n "$match" ]; do
    line_number=${match%%:*}
    case "$line_number" in
      ''|*[!0-9]*)
        exec 4<&-
        fail_after_patterns "grep returned an invalid line record for $label"
        ;;
    esac
    if ! printf '%s\n' "$line_number" >> "$hit_lines"; then
      exec 4<&-
      fail_after_patterns "recording a match location for $label failed"
    fi
    match_count=$((match_count + 1))
  done
  exec 4<&-
  [ "$match_count" -gt 0 ] || fail_after_patterns "grep reported a hit without readable locations for $label"
}

scan_private_pattern() { # <pattern> <source> <label> <hit-lines> <match-id>
  local pattern=$1 source=$2 label=$3 hit_lines=$4 match_id=$5 matches="$TMP_ROOT/matches"
  if ! exec 4> "$matches"; then
    fail_after_patterns "opening the match output for $label check $match_id failed"
  fi
  if ! exec 5> "$TMP_ROOT/grep-error"; then
    exec 4>&-
    fail_after_patterns "opening the grep diagnostic output for $label check $match_id failed"
  fi
  LC_ALL=C grep -aFin -- "$pattern" "$source" >&4 2>&5
  GREP_RC=$?
  exec 4>&-
  exec 5>&-
  case "$GREP_RC" in
    0) append_match_lines "$matches" "$hit_lines" "$label" ;;
    1) ;;
    *) fail_after_patterns "grep failed while scanning $label check $match_id" ;;
  esac
}

scan_active_sources() {
  local source_index=0 source label pattern_index pattern matches hit_lines unique_lines
  local line_list line_count
  while [ "$source_index" -lt "${#ACTIVE_FILES[@]}" ]; do
    source=${ACTIVE_FILES[$source_index]}
    label=${ACTIVE_LABELS[$source_index]}
    hit_lines="$TMP_ROOT/hit-lines"
    if ! : > "$hit_lines"; then
      fail_after_patterns "opening the hit-location output for $label failed"
    fi
    pattern_index=0
    if ! exec 3< "$ACTIVE_PATTERNS"; then
      fail_after_patterns "opening the pattern input for $label failed"
    fi
    while IFS= read -r pattern <&3 || [ -n "$pattern" ]; do
      pattern_index=$((pattern_index + 1))
      matches="$TMP_ROOT/matches"
      if ! exec 4> "$matches"; then
        exec 3<&-
        fail_after_patterns "opening the match output for $label pattern $pattern_index failed"
      fi
      if ! exec 5> "$TMP_ROOT/grep-error"; then
        exec 4>&-
        exec 3<&-
        fail_after_patterns "opening the grep diagnostic output for $label pattern $pattern_index failed"
      fi
      LC_ALL=C grep -aEin -- "$pattern" "$source" >&4 2>&5
      GREP_RC=$?
      exec 4>&-
      exec 5>&-
      case "$GREP_RC" in
        0) append_match_lines "$matches" "$hit_lines" "$label" ;;
        1) ;;
        *)
          exec 3<&-
          fail_after_patterns "grep failed while scanning $label pattern $pattern_index"
          ;;
      esac
    done
    exec 3<&-
    [ "$pattern_index" -eq "$ACTIVE_PATTERN_COUNT" ] || \
      fail_after_patterns "pattern input ended early while scanning $label (read $pattern_index of $ACTIVE_PATTERN_COUNT)"

    if [ "$ACTIVE_EVIDENCE" -eq 1 ]; then
      [ -z "$OPERATOR_HOME" ] || scan_private_pattern "$OPERATOR_HOME" "$source" "$label" "$hit_lines" operator-home
      # shellcheck disable=SC2088 # The literal home alias is evidence content, not a shell path.
      scan_private_pattern '~/' "$source" "$label" "$hit_lines" operator-home-alias
    fi

    if [ -s "$hit_lines" ]; then
      HITS=1
      unique_lines="$TMP_ROOT/unique-hit-lines"
      if ! LC_ALL=C sort -n -u "$hit_lines" > "$unique_lines"; then
        fail_after_patterns "sorting match locations for $label failed"
      fi
      line_count=$(awk 'END { print NR + 0 }' "$unique_lines")
      line_list=$(paste -sd, "$unique_lines") || fail_after_patterns "reading match locations for $label failed"
      emit_scan_record "hit" "fm-push-scan: hit: file=$label lines=$line_list count=$line_count"
    fi
    source_index=$((source_index + 1))
  done
}

scan_active_sources

if [ "${#EVIDENCE_FILES[@]}" -gt 0 ]; then
  ACTIVE_LABELS=()
  ACTIVE_FILES=()
  EVIDENCE_INDEX=0
  for EVIDENCE_FILE in "${EVIDENCE_FILES[@]}"; do
    EVIDENCE_INDEX=$((EVIDENCE_INDEX + 1))
    redact_value "$EVIDENCE_FILE"
    EVIDENCE_DISPLAY=$REDACTED_VALUE
    [ -f "$EVIDENCE_FILE" ] && [ -r "$EVIDENCE_FILE" ] || \
      fail_after_patterns "evidence[$EVIDENCE_INDEX] is not a readable regular file: $EVIDENCE_DISPLAY"
    EVIDENCE_COPY="$TMP_ROOT/evidence.$EVIDENCE_INDEX"
    if ! cat < "$EVIDENCE_FILE" > "$EVIDENCE_COPY"; then
      fail_after_patterns "evidence[$EVIDENCE_INDEX] could not be read: $EVIDENCE_DISPLAY"
    fi
    ACTIVE_LABELS+=("evidence[$EVIDENCE_INDEX]")
    ACTIVE_FILES+=("$EVIDENCE_COPY")
  done

  if [ "$LIST_KIND" = sensitive ]; then
    EVIDENCE_PATTERNS=$PRIMARY_PATTERNS
    EVIDENCE_PATTERN_COUNT=$PRIMARY_PATTERN_COUNT
    emit_scan_record "loaded-pattern count" \
      "fm-push-scan: patterns loaded: $EVIDENCE_PATTERN_COUNT (scope=evidence, list=sensitive, path=$LIST_DISPLAY)"
  else
    EVIDENCE_PATTERNS="$TMP_ROOT/evidence-patterns"
    EVIDENCE_LIST_PATH="$FLEET_HOME/config/sensitive-terms.txt"
    load_pattern_list sensitive "$EVIDENCE_LIST_PATH" "$EVIDENCE_PATTERNS" evidence
    EVIDENCE_PATTERN_COUNT=$LOADED_PATTERN_COUNT
  fi
  ACTIVE_PATTERNS=$EVIDENCE_PATTERNS
  ACTIVE_PATTERN_COUNT=$EVIDENCE_PATTERN_COUNT
  ACTIVE_EVIDENCE=1
  scan_active_sources
fi

if [ "$HITS" -ne 0 ]; then
  emit_scan_record "final result" "fm-push-scan: result: hits found"
  exit 1
fi
emit_scan_record "final result" "fm-push-scan: result: clean"
exit 0
