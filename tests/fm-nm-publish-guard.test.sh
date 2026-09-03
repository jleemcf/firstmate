#!/usr/bin/env bash
# Behavior tests for the no-mistakes pre-publication base guard.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-nm-publish-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-publish-guard)
fm_git_identity

make_world() { # <name>
  local name=$1 world
  world="$TMP_ROOT/$name"
  mkdir -p "$world/admin"
  git init -q --bare "$world/origin.git"
  git -C "$world/origin.git" symbolic-ref HEAD refs/heads/main
  git -C "$world/admin" init -q -b main
  printf 'base\n' > "$world/admin/value"
  git -C "$world/admin" add value
  git -C "$world/admin" commit -qm base
  git -C "$world/admin" remote add origin "$world/origin.git"
  git -C "$world/admin" push -q -u origin main
  git clone -q "$world/origin.git" "$world/work"
  git -C "$world/work" checkout -q -b feature
  printf 'feature\n' >> "$world/work/value"
  git -C "$world/work" add value
  git -C "$world/work" commit -qm feature
  printf '%s\n' "$world"
}

run_guard() { # <worktree>
  (
    cd "$1" || exit 111
    "$GUARD"
  ) 2>&1
}

test_current_base_passes() {
  local world out rc
  world=$(make_world current)
  rc=0
  out=$(run_guard "$world/work") || rc=$?
  expect_code 0 "$rc" "a head based on current main should pass"
  assert_contains "$out" "verified: validated head contains current origin/main" \
    "the passing result did not identify the proven current base"
  pass "fm-nm-publish-guard: a current-base head passes"
}

test_stale_base_refuses() {
  local world out rc refs_before refs_after
  world=$(make_world stale)
  printf 'main advanced\n' >> "$world/admin/value"
  git -C "$world/admin" add value
  git -C "$world/admin" commit -qm "advance main"
  git -C "$world/admin" push -q origin main

  refs_before=$(git -C "$world/work" for-each-ref --format='%(refname) %(objectname)' | sort)
  rc=0
  out=$(run_guard "$world/work") || rc=$?
  refs_after=$(git -C "$world/work" for-each-ref --format='%(refname) %(objectname)' | sort)
  [ "$rc" -ne 0 ] || fail "a stale-base head passed the publication guard"
  assert_contains "$out" "REFUSED" "the stale-base failure was not an explicit refusal"
  assert_contains "$out" "does not contain origin/main" \
    "the stale-base refusal did not identify the missing current base"
  [ "$refs_before" = "$refs_after" ] \
    || fail "the stale-base check moved a named ref"
  pass "fm-nm-publish-guard: a stale-base head is refused without moving refs"
}

test_undeterminable_base_refuses() {
  local world out rc
  world=$(make_world undeterminable)
  git -C "$world/origin.git" symbolic-ref HEAD refs/heads/missing

  rc=0
  out=$(run_guard "$world/work") || rc=$?
  [ "$rc" -ne 0 ] || fail "an undeterminable base passed the publication guard"
  assert_contains "$out" "REFUSED" \
    "the undeterminable-base failure was not an explicit refusal"
  assert_contains "$out" "could not determine origin's current default branch" \
    "the undeterminable-base refusal did not identify the missing base"
  pass "fm-nm-publish-guard: an undeterminable base fails closed"
}

test_trusted_config_wires_the_guard() {
  local configured
  configured=$(awk '
    /^commands:[[:space:]]*$/ { in_commands=1; next }
    in_commands && /^[^[:space:]#]/ { in_commands=0 }
    in_commands && $1 == "format:" {
      count++
      value=$0
      sub(/^[[:space:]]*format:[[:space:]]*/, "", value)
      quote=sprintf("%c", 39)
      if (substr(value, 1, 1) != quote || substr(value, length(value), 1) != quote) exit 1
      value=substr(value, 2, length(value) - 2)
    }
    END { if (count == 1 && value != "") print value; else exit 1 }
  ' "$ROOT/.no-mistakes.yaml") || fail "trusted no-mistakes config has no unique commands.format"
  [ "$configured" = "bin/fm-nm-publish-guard.sh" ] \
    || fail "trusted no-mistakes config does not invoke the publication guard"
  pass "no-mistakes trusted config invokes the base guard at Push entry"
}

test_current_base_passes
test_stale_base_refuses
test_undeterminable_base_refuses
test_trusted_config_wires_the_guard
