#!/usr/bin/env bash
# Behavior tests for bin/fm-push-scan.sh.
#
# These regressions prove that a missing, empty, comment-only, or unreadable
# selected list cannot produce a clean result, and that list selection never
# falls back to a caller-relative or opposite-direction file. They also prove
# all six required push surfaces are scanned and every completed record carries
# the usable-pattern count. Evidence regressions prove separate sensitive-list
# enforcement, non-echoing hit records, and pre-write operator-home redaction.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-push-scan)
SCAN="$ROOT/bin/fm-push-scan.sh"

new_repo() { # <name> <branch> <content> <message> <author-name> <author-email>
  local name=$1 branch=$2 content=$3 message=$4 author_name=$5 author_email=$6
  local repo="$TMP_ROOT/$name"
  fm_git_init_commit "$repo"
  git -C "$repo" branch -M main
  fm_git_add_origin "$repo" "$repo.origin.git"
  git -C "$repo" fetch -q origin
  git -C "$repo" checkout -qb "$branch"
  printf '%s\n' "$content" >> "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name="$author_name" -c user.email="$author_email" \
    commit -qm "$message"
  mkdir -p "$repo/nested"
  printf '%s\n' "$repo"
}

write_pr_text() { # <directory> <title> <body>
  mkdir -p "$1"
  printf '%s\n' "$2" > "$1/title.txt"
  printf '%s\n' "$3" > "$1/body.txt"
}

run_scan() { # <repo> <home> <list> [scanner-arguments...]
  local repo=$1 home=$2 list=$3
  shift 3
  (
    cd "$repo/nested" || exit 99
    FM_HOME="$home" "$SCAN" "$list" \
      --pr-title-file "$home/pr/title.txt" \
      --pr-body-file "$home/pr/body.txt" "$@"
  ) 2>&1
}

run_scan_with_printf_failure() { # <repo> <home> <list> <failure>
  local repo=$1 home=$2 list=$3 failure=$4 branch
  branch=$(git -C "$repo" symbolic-ref --short HEAD)
  (
    cd "$repo/nested" || exit 99
    # shellcheck disable=SC2329 # Exported for the scanner subprocess to invoke indirectly.
    printf() {
      case "${FM_TEST_PRINTF_FAILURE:-}" in
        branch)
          [ "${1:-}" = '%s\n' ] && [ "${2:-}" = "${FM_TEST_BRANCH:-}" ] && return 1
          ;;
        loaded-count)
          case "${2:-}" in
            'fm-push-scan: patterns loaded:'*) return 1 ;;
          esac
          ;;
        clean-result)
          [ "${2:-}" = 'fm-push-scan: result: clean' ] && return 1
          ;;
      esac
      # shellcheck disable=SC2059 # Forward the shim's variadic printf interface unchanged.
      builtin printf "$@"
    }
    printf '' || exit 99
    export -f printf
    FM_TEST_PRINTF_FAILURE="$failure" FM_TEST_BRANCH="$branch" FM_HOME="$home" \
      "$SCAN" "$list" \
        --pr-title-file "$home/pr/title.txt" \
        --pr-body-file "$home/pr/body.txt"
  ) 2>&1
}

run_scan_with_temp_failure() { # <repo> <home> <list> <failure>
  local repo=$1 home=$2 list=$3 failure=$4 case_root fakebin scan_tmp real_cat
  case_root="$TMP_ROOT/temp-failure-$failure"
  fakebin="$case_root/bin"
  scan_tmp="$case_root/scan-tmp"
  real_cat=$(command -v cat)
  mkdir -p "$fakebin"
  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
set -u
mkdir -p "$FM_TEST_SCAN_TMP"
if [ "$FM_TEST_TEMP_FAILURE" = match-output ]; then
  mkdir -p "$FM_TEST_SCAN_TMP/matches"
fi
printf '%s\n' "$FM_TEST_SCAN_TMP"
SH
  cat > "$fakebin/cat" <<'SH'
#!/usr/bin/env bash
set -u
count=0
if [ -f "$FM_TEST_CAT_COUNT" ]; then
  IFS= read -r count < "$FM_TEST_CAT_COUNT" || true
fi
count=$((count + 1))
printf '%s\n' "$count" > "$FM_TEST_CAT_COUNT"
"$FM_TEST_REAL_CAT" "$@"
rc=$?
if [ "$FM_TEST_TEMP_FAILURE" = pattern-input ] && [ "$count" -eq 2 ]; then
  rm -f "$FM_TEST_SCAN_TMP/patterns"
fi
exit "$rc"
SH
  chmod +x "$fakebin/mktemp" "$fakebin/cat"
  (
    cd "$repo/nested" || exit 99
    PATH="$fakebin:$PATH" FM_TEST_SCAN_TMP="$scan_tmp" \
      FM_TEST_TEMP_FAILURE="$failure" FM_TEST_CAT_COUNT="$case_root/cat-count" \
      FM_TEST_REAL_CAT="$real_cat" FM_HOME="$home" \
      "$SCAN" "$list" \
        --pr-title-file "$home/pr/title.txt" \
        --pr-body-file "$home/pr/body.txt"
  ) 2>&1
}

assert_no_result() { # <output> <label>
  assert_not_contains "$1" "fm-push-scan: result:" \
    "$2 emitted a scan result even though preflight failed"
}

test_missing_list_fails_without_cwd_or_other_list_fallback() {
  local repo home out rc
  repo=$(new_repo missing-list feature/safe 'safe diff' 'safe message' 'Safe Author' 'safe@example.invalid')
  home="$TMP_ROOT/missing-home"
  mkdir -p "$home/config" "$repo/nested/config"
  write_pr_text "$home/pr" 'Safe title' 'Safe body'
  printf '%s\n' 'safe' > "$home/config/sensitive-terms.txt"
  printf '%s\n' 'safe' > "$repo/nested/config/company-push-terms.txt"

  out=$(run_scan "$repo" "$home" company); rc=$?
  expect_code 2 "$rc" "missing selected list must fail closed"
  assert_contains "$out" "patterns loaded: 0 (list=company, path=$home/config/company-push-terms.txt)" \
    "missing-list failure did not identify the absolute fleet-home path and zero count"
  assert_contains "$out" "company pattern list is missing" \
    "missing-list failure did not report the missing selected list"
  assert_no_result "$out" "missing-list failure"
  pass "fm-push-scan.sh: missing selected list fails without cwd or opposite-list fallback"
}

test_script_root_default_is_cwd_independent() {
  local repo home out rc
  repo=$(new_repo script-root feature/safe-root 'safe diff' 'safe message' 'Safe Author' 'safe@example.invalid')
  home="$TMP_ROOT/script-root-home"
  mkdir -p "$home/bin" "$home/config"
  write_pr_text "$home/pr" 'Safe title' 'Safe body'
  cp "$SCAN" "$home/bin/fm-push-scan.sh"
  chmod +x "$home/bin/fm-push-scan.sh"
  printf '%s\n' 'forbidden' > "$home/config/sensitive-terms.txt"

  out=$(cd "$repo/nested" && FM_HOME='' "$home/bin/fm-push-scan.sh" sensitive \
    --pr-title-file "$home/pr/title.txt" \
    --pr-body-file "$home/pr/body.txt" 2>&1); rc=$?
  expect_code 0 "$rc" "script-root default should resolve independently of the caller cwd"
  assert_contains "$out" "patterns loaded: 1 (list=sensitive, path=$home/config/sensitive-terms.txt)" \
    "script-root default did not resolve the selected list from its own absolute root"
  assert_contains "$out" "fm-push-scan: result: clean" \
    "script-root default did not complete the clean scan"
  pass "fm-push-scan.sh: script-root default is independent of the caller directory"
}

test_empty_list_fails_for_zero_patterns() {
  local repo home out rc
  repo=$(new_repo empty-list feature/safe-empty 'safe diff' 'safe message' 'Safe Author' 'safe@example.invalid')
  home="$TMP_ROOT/empty-home"
  mkdir -p "$home/config"
  write_pr_text "$home/pr" 'Safe title' 'Safe body'
  : > "$home/config/sensitive-terms.txt"

  out=$(run_scan "$repo" "$home" sensitive); rc=$?
  expect_code 2 "$rc" "empty list must fail closed"
  assert_contains "$out" "patterns loaded: 0 (list=sensitive" \
    "empty-list failure did not print a zero pattern count"
  assert_contains "$out" "yielded zero usable patterns" \
    "empty-list failure did not fail for zero usable patterns"
  assert_no_result "$out" "empty-list failure"
  pass "fm-push-scan.sh: empty list fails for zero usable patterns"
}

test_comment_only_list_fails_for_zero_patterns() {
  local repo home out rc
  repo=$(new_repo comment-list feature/safe-comments 'safe diff' 'safe message' 'Safe Author' 'safe@example.invalid')
  home="$TMP_ROOT/comment-home"
  mkdir -p "$home/config"
  write_pr_text "$home/pr" 'Safe title' '# Markdown heading that comments must not match'
  printf '%s\n' '# first comment' '   # indented comment' '' '   ' > "$home/config/company-push-terms.txt"

  out=$(run_scan "$repo" "$home" company); rc=$?
  expect_code 2 "$rc" "comment-only list must fail closed"
  assert_contains "$out" "patterns loaded: 0 (list=company" \
    "comment-only failure did not print a zero pattern count"
  assert_contains "$out" "yielded zero usable patterns" \
    "comment-only failure did not fail for zero usable patterns"
  assert_no_result "$out" "comment-only failure"
  pass "fm-push-scan.sh: comment-only list fails instead of treating headings as patterns"
}

test_unreadable_list_fails_for_the_list_reason() {
  local repo home list_path out rc
  repo=$(new_repo unreadable-list feature/safe-unreadable 'safe diff' 'safe message' 'Safe Author' 'safe@example.invalid')
  home="$TMP_ROOT/unreadable-home"
  mkdir -p "$home/config"
  write_pr_text "$home/pr" 'Safe title' 'Safe body'
  list_path="$home/config/sensitive-terms.txt"
  printf '%s\n' 'forbidden' > "$list_path"
  chmod 000 "$list_path"
  if [ -r "$list_path" ]; then
    rm -f "$list_path"
    mkdir "$list_path"
  fi

  out=$(run_scan "$repo" "$home" sensitive); rc=$?
  expect_code 2 "$rc" "unreadable list must fail closed"
  assert_contains "$out" "patterns loaded: 0 (list=sensitive" \
    "unreadable-list failure did not print a zero pattern count"
  assert_contains "$out" "pattern list is not a readable regular file" \
    "unreadable-list case failed for an incidental reason"
  assert_no_result "$out" "unreadable-list failure"
  pass "fm-push-scan.sh: unreadable list fails for the selected-list reason"
}

assert_surface_hit() { # <case> <branch> <content> <message> <author> <email> <title> <body> <source>
  local case_name=$1 branch=$2 content=$3 message=$4 author=$5 email=$6 title=$7 body=$8 source=$9
  local repo home out rc
  repo=$(new_repo "hit-$case_name" "$branch" "$content" "$message" "$author" "$email")
  home="$TMP_ROOT/hit-$case_name-home"
  mkdir -p "$home/config"
  write_pr_text "$home/pr" "$title" "$body"
  printf '%s\n' '# comment must not be loaded' 'forbidden[ _-]token' > "$home/config/company-push-terms.txt"

  out=$(run_scan "$repo" "$home" company); rc=$?
  expect_code 1 "$rc" "$case_name planted hit must fail the scan"
  assert_contains "$out" "patterns loaded: 1 (list=company" \
    "$case_name hit record omitted the usable-pattern count"
  assert_contains "$out" "hit: file=$source lines=" \
    "$case_name hit did not identify its safe source and line location"
  assert_contains "$out" "count=1" \
    "$case_name hit did not report its matching-line count"
  assert_not_contains "$out" "forbidden" \
    "$case_name hit record echoed the matched pattern or source text"
  assert_not_contains "$out" "Forbidden" \
    "$case_name hit record echoed case-variant matched source text"
  assert_not_contains "$out" "pattern[" \
    "$case_name hit record exposed a pattern index and pattern text"
  assert_not_contains "$out" "match=" \
    "$case_name hit record exposed matching source text"
  assert_contains "$out" "fm-push-scan: result: hits found" \
    "$case_name hit did not report a completed hit result"
}

test_every_required_surface_is_scanned() {
  assert_surface_hit diff feature/safe-diff 'contains forbidden-token' 'safe message' \
    'Safe Author' 'safe@example.invalid' 'Safe title' 'Safe body' diff
  assert_surface_hit branch feature/forbidden-token 'safe diff' 'safe message' \
    'Safe Author' 'safe@example.invalid' 'Safe title' 'Safe body' branch
  assert_surface_hit message feature/safe-message 'safe diff' 'adds Forbidden_Token metadata' \
    'Safe Author' 'safe@example.invalid' 'Safe title' 'Safe body' commit-messages
  assert_surface_hit author feature/safe-author 'safe diff' 'safe message' \
    'Forbidden Token' 'safe@example.invalid' 'Safe title' 'Safe body' commit-authors
  assert_surface_hit title feature/safe-title 'safe diff' 'safe message' \
    'Safe Author' 'safe@example.invalid' 'Forbidden token release' 'Safe body' pull-request-title
  assert_surface_hit body feature/safe-body 'safe diff' 'safe message' \
    'Safe Author' 'safe@example.invalid' 'Safe title' 'Contains forbidden-token details' pull-request-body
  pass "fm-push-scan.sh: diff, branch, messages, authors, PR title, and PR body all reject planted hits"
}

test_clean_scan_passes_with_count_and_comments_removed() {
  local repo home out rc
  repo=$(new_repo clean feature/safe-clean 'safe diff' 'safe message' 'Safe Author' 'safe@example.invalid')
  home="$TMP_ROOT/clean-home"
  mkdir -p "$home/config"
  write_pr_text "$home/pr" 'Safe title' '# A markdown heading is safe'
  printf '%s\n' '# A comment is not a grep pattern' '' 'forbidden[ _-]token' > "$home/config/sensitive-terms.txt"

  out=$(run_scan "$repo" "$home" sensitive); rc=$?
  expect_code 0 "$rc" "clean complete set should pass"
  assert_contains "$out" "patterns loaded: 1 (list=sensitive" \
    "clean result omitted the usable-pattern count"
  assert_contains "$out" "fm-push-scan: result: clean" \
    "clean complete set did not produce a clean result"
  assert_not_contains "$out" "fm-push-scan: hit:" \
    "comment lines were incorrectly loaded as patterns"
  pass "fm-push-scan.sh: clean complete set passes and prints its pattern count"
}

test_evidence_uses_the_sensitive_list_without_echoing_hits() {
  local repo home evidence out rc
  repo=$(new_repo evidence-sensitive feature/safe-evidence 'safe diff' 'safe message' 'Safe Author' 'safe@example.invalid')
  home="$TMP_ROOT/evidence-sensitive-home"
  evidence="$home/publishable-evidence.txt"
  mkdir -p "$home/config"
  write_pr_text "$home/pr" 'Safe title' 'Safe body'
  printf '%s\n' 'company-only-never' > "$home/config/company-push-terms.txt"
  printf '%s\n' 'contains private-marker detail' > "$evidence"

  out=$(run_scan "$repo" "$home" company --evidence-file "$evidence"); rc=$?
  expect_code 2 "$rc" "company scan evidence must not fall back when the sensitive list is missing"
  assert_contains "$out" "patterns loaded: 0 (list=sensitive" \
    "missing evidence-sensitive list did not report a zero count"
  assert_contains "$out" "sensitive pattern list is missing" \
    "evidence scan did not require its separate sensitive list"
  assert_no_result "$out" "missing evidence-sensitive list"

  printf '%s\n' 'private[-_]marker' > "$home/config/sensitive-terms.txt"
  out=$(run_scan "$repo" "$home" company --evidence-file "$evidence"); rc=$?
  expect_code 1 "$rc" "sensitive content in publishable evidence must refuse publication"
  assert_contains "$out" "patterns loaded: 1 (scope=evidence, list=sensitive" \
    "evidence scan did not record its separate sensitive pattern count"
  assert_contains "$out" "hit: file=evidence[1] lines=1 count=1" \
    "evidence hit did not report only its safe file index, line, and count"
  assert_not_contains "$out" "private-marker" \
    "evidence hit record echoed the matched source text"
  assert_not_contains "$out" "private[-_]marker" \
    "evidence hit record echoed the matched pattern text"
  assert_contains "$out" "fm-push-scan: result: hits found" \
    "unsafe evidence did not produce a refusing hit result"
  pass "fm-push-scan.sh: publishable evidence uses the separate sensitive list without echoing hits"
}

test_evidence_writer_redacts_operator_home_before_output() {
  local repo home operator_home raw_path raw_file redacted_file out rc
  repo=$(new_repo evidence-redaction feature/safe-redaction 'safe diff' 'safe message' 'Safe Author' 'safe@example.invalid')
  operator_home="$TMP_ROOT/evidence-redaction-operator"
  home="$operator_home/fleet"
  raw_path="$operator_home/private/tool/output.log"
  raw_file="$operator_home/raw-input.txt"
  redacted_file="$home/redacted-evidence.txt"
  mkdir -p "$home/config"
  write_pr_text "$home/pr" 'Safe title' 'Safe body'
  printf '%s\n' 'never-match-this' > "$home/config/sensitive-terms.txt"
  printf 'command used %s\nand alias ~/.private/tool\n' "$raw_path" > "$raw_file"

  HOME="$operator_home" "$SCAN" redact-evidence --output "$redacted_file" < "$raw_file" \
    || fail "redact-evidence mode refused valid input"
  assert_present "$redacted_file" "redact-evidence mode did not write its destination"
  assert_no_grep "$operator_home" "$redacted_file" \
    "redacted evidence retained the absolute operator home"
  # shellcheck disable=SC2088 # Assert the literal home alias was redacted from evidence.
  assert_no_grep "~/" "$redacted_file" \
    "redacted evidence retained the operator-home alias"
  assert_grep "<HOME>/private/tool/output.log" "$redacted_file" \
    "redacted evidence did not replace the absolute operator home"
  assert_grep "<HOME>/.private/tool" "$redacted_file" \
    "redacted evidence did not replace the operator-home alias"

  out=$(cd "$repo/nested" && HOME="$operator_home" FM_HOME="$home" "$SCAN" sensitive \
    --pr-title-file "$home/pr/title.txt" --pr-body-file "$home/pr/body.txt" \
    --evidence-file "$raw_file" 2>&1); rc=$?
  expect_code 1 "$rc" "unredacted operator-home evidence must refuse publication"
  assert_contains "$out" "hit: file=evidence[1]" \
    "operator-home evidence refusal omitted its safe evidence location"
  assert_not_contains "$out" "$operator_home" \
    "operator-home evidence refusal leaked the personal path"
  # shellcheck disable=SC2088 # Assert the literal home alias was not emitted.
  assert_not_contains "$out" "~/" \
    "operator-home evidence refusal leaked the home alias"

  out=$(cd "$repo/nested" && HOME="$operator_home" FM_HOME="$home" "$SCAN" sensitive \
    --pr-title-file "$home/pr/title.txt" --pr-body-file "$home/pr/body.txt" \
    --evidence-file "$redacted_file" 2>&1); rc=$?
  expect_code 0 "$rc" "pre-write redacted evidence should pass a clean sensitive scan"
  assert_contains "$out" "fm-push-scan: result: clean" \
    "pre-write redacted evidence did not complete cleanly"
  pass "fm-push-scan.sh: evidence writer redacts operator-home paths before destination output"
}

test_required_write_failures_stop_without_a_result() {
  local repo home out rc
  repo=$(new_repo write-failure feature/write-failure 'safe diff' 'safe message' 'Safe Author' 'safe@example.invalid')
  home="$TMP_ROOT/write-failure-home"
  mkdir -p "$home/config"
  write_pr_text "$home/pr" 'Safe title' 'Safe body'
  printf '%s\n' 'forbidden' > "$home/config/company-push-terms.txt"

  out=$(run_scan_with_printf_failure "$repo" "$home" company branch); rc=$?
  expect_code 2 "$rc" "an unwritable branch source must fail closed"
  assert_contains "$out" "patterns loaded: 1 (list=company" \
    "branch-write failure did not reach source materialization"
  assert_contains "$out" "materializing the branch scan source failed" \
    "branch-write failure did not identify the omitted source"
  assert_no_result "$out" "branch-write failure"

  out=$(run_scan_with_printf_failure "$repo" "$home" company loaded-count); rc=$?
  expect_code 2 "$rc" "an unwritable pattern-count record must fail closed"
  assert_contains "$out" "could not write loaded-pattern count scan record" \
    "pattern-count write failure did not use the scanner diagnostic path"
  assert_no_result "$out" "pattern-count write failure"

  out=$(run_scan_with_printf_failure "$repo" "$home" company clean-result); rc=$?
  expect_code 2 "$rc" "an unwritable clean-result record must fail closed"
  assert_contains "$out" "patterns loaded: 1 (list=company" \
    "clean-result write failure omitted the completed pattern count"
  assert_contains "$out" "could not write final result scan record" \
    "clean-result write failure did not use the scanner diagnostic path"
  assert_no_result "$out" "clean-result write failure"
  pass "fm-push-scan.sh: source and result write failures cannot report clean"
}

test_temp_descriptor_failures_stop_without_a_result() {
  local repo home out rc
  repo=$(new_repo descriptor-failure feature/safe-descriptor 'contains forbidden-token' 'safe message' 'Safe Author' 'safe@example.invalid')
  home="$TMP_ROOT/descriptor-failure-home"
  mkdir -p "$home/config"
  write_pr_text "$home/pr" 'Safe title' 'Safe body'
  printf '%s\n' 'forbidden[ _-]token' > "$home/config/company-push-terms.txt"

  out=$(run_scan_with_temp_failure "$repo" "$home" company match-output); rc=$?
  expect_code 2 "$rc" "an unopened match-output descriptor must fail closed"
  assert_contains "$out" "patterns loaded: 1 (list=company" \
    "match-output failure did not reach surface scanning"
  assert_contains "$out" "opening the match output for diff pattern 1 failed" \
    "match-output failure was interpreted as a grep result"
  assert_no_result "$out" "match-output descriptor failure"

  out=$(run_scan_with_temp_failure "$repo" "$home" company pattern-input); rc=$?
  expect_code 2 "$rc" "an unopened pattern-input descriptor must fail closed"
  assert_contains "$out" "patterns loaded: 1 (list=company" \
    "pattern-input failure did not reach surface scanning"
  assert_contains "$out" "opening the pattern input for diff failed" \
    "pattern-input failure was interpreted as an empty scan"
  assert_no_result "$out" "pattern-input descriptor failure"
  pass "fm-push-scan.sh: temporary descriptor failures cannot report clean"
}

test_missing_list_fails_without_cwd_or_other_list_fallback
test_script_root_default_is_cwd_independent
test_empty_list_fails_for_zero_patterns
test_comment_only_list_fails_for_zero_patterns
test_unreadable_list_fails_for_the_list_reason
test_every_required_surface_is_scanned
test_clean_scan_passes_with_count_and_comments_removed
test_evidence_uses_the_sensitive_list_without_echoing_hits
test_evidence_writer_redacts_operator_home_before_output
test_required_write_failures_stop_without_a_result
test_temp_descriptor_failures_stop_without_a_result
