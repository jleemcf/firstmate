# shellcheck shell=bash
# Shared fail-safe ownership proof for a task worktree resolved from state/<id>.meta.
# Usage: source this file after bin/fm-backend.sh when Orca tasks are possible.
#
# fm_worktree_ownership_prove <state-dir> <task-id> <meta-file>
# proves that the meta has one inspectable worktree claim, no other task in the
# same home claims the canonical path, and the strongest available positive
# provider binding agrees with the task.
# An Orca worktree id must resolve back to the exact path.
# A secondmate home must carry its exact .fm-secondmate-home marker.
# A crewmate worktree must never carry another task's .fm-task-owner marker;
# that marker binds both task id and spawn generation to protect a slot recycled
# to a later spawn of the same task id.
# A matching owner marker proves an ordinary ship or scout without requiring a
# branch, which covers every unbranched scout and ship before its first action.
# When no marker exists for a pre-marker task, refs/heads/fm/<task-id> proves
# ownership, another fm/<id> branch refuses, and an unattributed checkout falls
# back to membership in the task's recorded project.
# A recorded path that no longer exists holds nothing this task could destroy,
# so it is proved once no other task claims it and no provider binding
# contradicts it. A record that claims no path at all has nothing to prove and
# publishes an empty path, unless an interrupted retirement's backup is still
# sitting beside it; either way every path-keyed destructive helper still
# refuses through fm_worktree_claim_retire_begin's expected-path match.
# The function prints a concrete REFUSED reason and returns nonzero whenever a
# proof is missing, contradictory, unreadable, or ambiguous.
# On success it sets FM_WORKTREE_OWNERSHIP_PATH and
# FM_WORKTREE_OWNERSHIP_PROOF. FM_WORKTREE_OWNERSHIP_PROOF names the single
# strongest binding, so an independently verified Orca id/path match is
# published separately as FM_WORKTREE_OWNERSHIP_ORCA_PATH_MATCH=1: a marker
# that outranks it in the proof string must not cost the caller a second
# provider round trip it has already paid for.
#
# fm_worktree_claim_retire_begin <meta-file> <expected-worktree>
# removes the exact worktree= claim before a provider return or removal can
# make the path reusable, while retaining a byte-for-byte recovery copy.
# Call fm_worktree_claim_retire_release once the provider has released the
# path, or fm_worktree_claim_retire_restore when the provider operation failed.
# It retires the worktree's .fm-task-owner marker in the same step, since that
# marker is the in-worktree half of the same claim.
# This ordering makes a crash leave an unclaimed retained slot rather than a
# returned slot with a stale destructive claim, and every later refusal over a
# record with no claim names the surviving backup as its recovery source.
#
# fm_worktree_claim_retire_release ends the retirement the moment the provider
# reports the path released, because the provider may hand that path to another
# task immediately. The claim and the marker are gone for good: both backups are
# dropped, neither can be restored, and what survives is a retirement receipt
# beside the record. The receipt is evidence, never authority - it records that
# this record's provider step already ran so a rerun can skip it and finish the
# remaining cleanup, and it never satisfies an ownership proof or supplies a
# path any destructive helper can act on.
# fm_worktree_claim_retire_restore is therefore reachable only while the
# provider operation is known to have failed, and puts back both halves.
# fm_worktree_claim_retire_abandon closes an interrupted retirement whose
# provider outcome is unknown: it never restores, and leaves the surviving
# backup as the recovery source every later refusal names.
# fm_worktree_claim_retire_commit discards a retirement's leftovers once the
# record it describes is gone.

FM_WORKTREE_OWNERSHIP_PATH=
FM_WORKTREE_OWNERSHIP_PROOF=
FM_WORKTREE_OWNERSHIP_ORCA_PATH_MATCH=0
FM_WORKTREE_CLAIM_RETIRE_META=
FM_WORKTREE_CLAIM_RETIRE_BACKUP=
FM_WORKTREE_CLAIM_RETIRE_PATH=
FM_WORKTREE_CLAIM_RETIRE_ACTIVE=0
# Distinguishes "the provider released the path but the retirement could not be
# recorded" from an ordinary provider failure, which is the opposite situation.
FM_WORKTREE_RETIREMENT_UNRECORDED=4
FM_WORKTREE_CLAIM_RETIRE_MARKER=
FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP=
# Stamped by bin/fm-spawn.sh into a crewmate worktree once the task owns it, and
# removed by bin/fm-teardown.sh when the slot is released.
FM_WORKTREE_TASK_OWNER_MARKER=.fm-task-owner
FM_WORKTREE_TASK_BRANCH_CONFLICT=

fm_worktree_meta_exact_value() {  # <meta-file> <key>
  local meta=$1 key=$2 count value
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ -n "$count" ] || count=0
  [ "$count" -eq 1 ] || return 1
  value=$(grep "^${key}=" "$meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

# 0 and prints the single nonempty claim, 2 when the record carries no claim at
# all (absent or empty), 1 when several lines make the claim ambiguous.
fm_worktree_meta_claim() {  # <meta-file> <key>
  local meta=$1 key=$2 count value
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ -n "$count" ] || count=0
  case "$count" in
    0) return 2 ;;
    1) ;;
    *) return 1 ;;
  esac
  value=$(grep "^${key}=" "$meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$value" ] || return 2
  printf '%s' "$value"
}

fm_worktree_canonical_existing_dir() {  # <path>
  local path=$1
  [ -n "$path" ] && [ -d "$path" ] || return 1
  (CDPATH='' cd -- "$path" 2>/dev/null && pwd -P)
}

fm_worktree_claim_comparison_path() {  # <path>
  local path=$1 parent base
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  if [ -d "$path" ]; then
    fm_worktree_canonical_existing_dir "$path"
    return
  fi
  parent=${path%/*}
  base=${path##*/}
  [ -n "$parent" ] || parent=/
  # A vanished parent still leaves the absolute claim comparable against every
  # other absolute claim, so a removed pool root cannot strand the record.
  parent=$(fm_worktree_canonical_existing_dir "$parent") || {
    printf '%s\n' "$path"
    return 0
  }
  printf '%s/%s\n' "${parent%/}" "$base"
}

# Names an interrupted claim retirement's recovery copy, so a record whose
# worktree= was stripped between the rewrite and the commit/restore points at
# the file that still holds it.
fm_worktree_claim_backup_hint() {  # <meta-file>
  local meta=$1 dir base candidate
  dir=${meta%/*}
  base=${meta##*/}
  for candidate in "$dir/.${base}.worktree-claim-backup."*; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

# The durable evidence that a provider already released this record's worktree.
# It carries no path authority: nothing resolves a target through it, and a
# record that has one still proves ownership of no path at all.
fm_worktree_retirement_receipt_path() {  # <meta-file>
  local meta=$1 dir base
  dir=${meta%/*}
  base=${meta##*/}
  printf '%s/.%s.worktree-retired' "$dir" "$base"
}

fm_worktree_record_identity() {  # <meta-file>
  local meta=$1 base=${1##*/}
  printf '%s' "${base%.meta}"
}

# 0 and prints the path the provider released, 1 otherwise. A receipt speaks
# only for the exact incarnation that wrote it: it is bound to the record's task
# id and spawn generation, and it is only believed while the record still claims
# no path. A leaked receipt therefore says nothing about a later task that
# reuses the id, and never about a record holding a live claim.
fm_worktree_retirement_receipt_present() {  # <meta-file>
  local meta=$1 receipt released claim_rc=0
  receipt=$(fm_worktree_retirement_receipt_path "$meta")
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_worktree_meta_exact_value "$receipt" schema 2>/dev/null || true)" = fm-worktree-retired.v1 ] || return 1
  [ "$(fm_worktree_meta_exact_value "$receipt" task_id 2>/dev/null || true)" \
    = "$(fm_worktree_record_identity "$meta")" ] || return 1
  [ "$(fm_worktree_meta_exact_value "$receipt" spawn_gen 2>/dev/null || true)" \
    = "$(fm_worktree_meta_exact_value "$meta" spawn_gen 2>/dev/null || true)" ] || return 1
  fm_worktree_meta_claim "$meta" worktree >/dev/null || claim_rc=$?
  [ "$claim_rc" -eq 2 ] || return 1
  released=$(fm_worktree_meta_exact_value "$receipt" released_worktree 2>/dev/null || true)
  printf '%s' "$released"
}

fm_worktree_retirement_receipt_write() {  # <meta-file> <released-worktree>
  local meta=$1 released=$2 receipt tmp generation
  receipt=$(fm_worktree_retirement_receipt_path "$meta")
  generation=$(fm_worktree_meta_exact_value "$meta" spawn_gen 2>/dev/null || true)
  tmp="$receipt.next.${BASHPID:-$$}"
  if ! (umask 077; {
      printf '%s\n' 'schema=fm-worktree-retired.v1'
      printf 'task_id=%s\n' "$(fm_worktree_record_identity "$meta")"
      printf 'spawn_gen=%s\n' "$generation"
      printf 'released_worktree=%s\n' "$released"
    } > "$tmp") || ! mv -f -- "$tmp" "$receipt"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_worktree_retirement_receipt_clear() {  # <meta-file>
  local meta=$1 receipt candidate dir base rc=0
  receipt=$(fm_worktree_retirement_receipt_path "$meta")
  rm -f -- "$receipt" || rc=1
  dir=${meta%/*}
  base=${meta##*/}
  for candidate in "$dir/.${base}.worktree-claim-backup."*; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
    rm -f -- "$candidate" || rc=1
  done
  return "$rc"
}

fm_worktree_refuse() {  # <message>
  printf 'REFUSED: %s\n' "$1" >&2
  return 1
}

fm_worktree_no_conflicting_claim() {  # <state-dir> <task-id> <meta-file> <canonical-worktree>
  local state=$1 id=$2 own_meta=$3 canonical=$4 other_meta other_id count other other_canonical
  [ -d "$state" ] || {
    fm_worktree_refuse "cannot inspect task $id ownership because state directory $state is unavailable."
    return 1
  }
  for other_meta in "$state"/*.meta; do
    [ -e "$other_meta" ] || [ -L "$other_meta" ] || continue
    [ "$other_meta" != "$own_meta" ] || continue
    other_id=${other_meta##*/}
    other_id=${other_id%.meta}
    if [ ! -f "$other_meta" ] || [ -L "$other_meta" ]; then
      fm_worktree_refuse "cannot prove task $id owns $canonical because task $other_id has unsafe metadata at $other_meta."
      return 1
    fi
    count=$(grep -c '^worktree=' "$other_meta" 2>/dev/null || true)
    if [ -z "$count" ]; then
      fm_worktree_refuse "cannot prove task $id owns $canonical because task $other_id's metadata at $other_meta could not be read."
      return 1
    fi
    case "$count" in
      0) continue ;;
      1) ;;
      *)
        fm_worktree_refuse "cannot prove task $id owns $canonical because task $other_id has $count recorded worktree claims."
        return 1
        ;;
    esac
    other=$(grep '^worktree=' "$other_meta" | cut -d= -f2-)
    [ -n "$other" ] || continue
    if [ "$other" = "$canonical" ]; then
      fm_worktree_refuse "worktree $canonical is also claimed by task $other_id; task $id cannot act on it."
      return 1
    fi
    other_canonical=$(fm_worktree_claim_comparison_path "$other" 2>/dev/null || true)
    if [ -n "$other_canonical" ] && [ "$other_canonical" = "$canonical" ]; then
      fm_worktree_refuse "worktree $canonical is also claimed by task $other_id as $other; task $id cannot act on it."
      return 1
    fi
  done
}

# 0 when the checkout positively attributes the worktree to this task, 1 only
# when it positively attributes it to a DIFFERENT fm task, and 2 for every state
# that attributes it to nobody. A checkout is legitimately unattributed far more
# often than it is foreign: a scout never leaves a detached HEAD, a ship stays
# detached until its agent runs `git checkout -b fm/<id>`, and a conflicted
# rebase or a bisect detaches HEAD off the task branch tip for as long as the
# operation is in progress - exactly the wedged state stuck-crewmate recovery
# has to act on. Those stay inconclusive so the owner marker or legacy project
# membership can decide rather than deadlocking every lifecycle verb.
fm_worktree_task_branch_proves_owner() {  # <canonical-worktree> <task-id>
  local worktree=$1 id=$2 branch expected="fm/$2" head expected_head
  FM_WORKTREE_TASK_BRANCH_CONFLICT=
  branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -n "$branch" ]; then
    [ "$branch" != "$expected" ] || return 0
    case "$branch" in
      fm/*)
        FM_WORKTREE_TASK_BRANCH_CONFLICT=$branch
        return 1
        ;;
    esac
    return 2
  fi
  head=$(git -C "$worktree" rev-parse --verify HEAD 2>/dev/null) || return 2
  expected_head=$(git -C "$worktree" rev-parse --verify "refs/heads/$expected" 2>/dev/null) || return 2
  [ "$head" = "$expected_head" ] || return 2
}

# The weakest proof an unbranched worktree can still offer: it must be one of
# the recorded project's registered worktrees. This is the only evidence left at
# that point, so an uninspectable project is a refusal, never a pass - the same
# polarity as worktree_registered_for_project in bin/fm-teardown.sh.
fm_worktree_project_worktree_binding() {  # <project> <canonical-worktree> <task-id>
  local project=$1 canonical=$2 id=$3 listed line listed_path
  [ -n "$project" ] || {
    fm_worktree_refuse "worktree $canonical is detached with no task $id branch and no owner marker, and task $id records no project to attribute it to."
    return 1
  }
  [ -d "$project" ] || {
    fm_worktree_refuse "worktree $canonical is detached with no task $id branch and no owner marker, and task $id's project $project is unavailable to attribute it to."
    return 1
  }
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || {
    fm_worktree_refuse "worktree $canonical is detached with no task $id branch and no owner marker, and task $id's project $project is not an inspectable git repository."
    return 1
  }
  listed=$(git -C "$project" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || {
    fm_worktree_refuse "worktree $canonical is detached with no task $id branch and no owner marker, and task $id's project $project could not list its worktrees."
    return 1
  }
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        listed_path=$(fm_worktree_claim_comparison_path "${line#worktree }" 2>/dev/null || true)
        [ "$listed_path" = "$canonical" ] || continue
        return 0
        ;;
    esac
  done <<EOF
$listed
EOF
  fm_worktree_refuse "worktree $canonical is detached with no task $id branch and no owner marker, and is no longer a registered worktree of its project $project."
  return 1
}

# The per-task ownership marker bin/fm-spawn.sh stamps into every crewmate
# worktree once it owns the slot. 0 when task id and spawn generation match this
# task's metadata, 1 when either differs or the marker cannot be read, and 2
# when no marker has been stamped there yet (a pre-marker task or a returned
# slot). A generation mismatch refuses even when the task id was reused.
fm_worktree_task_owner_marker_binding() {  # <canonical-worktree> <task-id> <spawn-generation>
  local canonical=$1 id=$2 expected_gen=$3 marker=$1/$FM_WORKTREE_TASK_OWNER_MARKER
  local schema owner generation
  [ -e "$marker" ] || [ -L "$marker" ] || return 2
  if [ ! -f "$marker" ] || [ -L "$marker" ]; then
    fm_worktree_refuse "worktree $canonical has a $FM_WORKTREE_TASK_OWNER_MARKER that is not a regular ownership marker, so task $id cannot be proved to own it."
    return 1
  fi
  schema=$(fm_worktree_meta_exact_value "$marker" schema 2>/dev/null || true)
  owner=$(fm_worktree_meta_exact_value "$marker" task_id 2>/dev/null || true)
  generation=$(fm_worktree_meta_exact_value "$marker" spawn_gen 2>/dev/null || true)
  if [ "$schema" != fm-task-owner.v1 ] || [ -z "$owner" ] || [ -z "$generation" ]; then
    fm_worktree_refuse "worktree $canonical has an unreadable or incomplete $FM_WORKTREE_TASK_OWNER_MARKER, so task $id cannot be proved to own it."
    return 1
  fi
  if [ "$owner" != "$id" ]; then
    fm_worktree_refuse "worktree $canonical is marked as task $owner's workspace, not task $id's."
    return 1
  fi
  if [ -z "$expected_gen" ]; then
    fm_worktree_refuse "$marker marks worktree $canonical for task $id generation $generation, but task metadata has no exact spawn generation."
    return 1
  fi
  if [ "$generation" != "$expected_gen" ]; then
    fm_worktree_refuse "$marker marks worktree $canonical for task $id generation $generation, not recorded generation $expected_gen."
    return 1
  fi
  return 0
}

fm_worktree_ownership_prove() {  # <state-dir> <task-id> <meta-file>
  local state=$1 id=$2 meta=$3 worktree canonical kind backend project spawn_gen
  local marker worktree_id resolved resolved_canonical provider_proof='' rc=0 claim_rc=0 present=0
  local backup marker_rc=0
  FM_WORKTREE_OWNERSHIP_PATH=
  FM_WORKTREE_OWNERSHIP_PROOF=
  FM_WORKTREE_OWNERSHIP_ORCA_PATH_MATCH=0
  case "$id" in
    ''|*[!A-Za-z0-9._-]*)
      fm_worktree_refuse "cannot prove worktree ownership for invalid task id '${id:-missing}'."
      return 1
      ;;
  esac
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    fm_worktree_refuse "task $id has no regular metadata at $meta for worktree ownership proof."
    return 1
  }

  kind=$(fm_worktree_meta_exact_value "$meta" kind 2>/dev/null || true)
  [ -n "$kind" ] || kind=ship
  backend=$(fm_worktree_meta_exact_value "$meta" backend 2>/dev/null || true)
  [ -n "$backend" ] || backend=tmux
  project=$(fm_worktree_meta_exact_value "$meta" project 2>/dev/null || true)
  spawn_gen=$(fm_worktree_meta_exact_value "$meta" spawn_gen 2>/dev/null || true)

  worktree=$(fm_worktree_meta_claim "$meta" worktree) || claim_rc=$?
  if [ "$claim_rc" -eq 1 ]; then
    fm_worktree_refuse "task $id has an ambiguous worktree claim in $meta."
    return 1
  fi
  if [ "$claim_rc" -eq 2 ]; then
    # No recorded path at all: there is nothing this task could destroy by
    # path, and fm_worktree_claim_retire_begin still refuses every path-keyed
    # helper whose target the record does not claim.
    backup=$(fm_worktree_claim_backup_hint "$meta" || true)
    if fm_worktree_retirement_receipt_present "$meta" >/dev/null 2>&1; then
      # The receipt settles what the copy can only guess at: this record's
      # provider step completed, so the claim was retired rather than
      # interrupted and that copy describes a path this task no longer owns.
      [ -z "$backup" ] \
        || echo "warning: task $id's retirement is recorded, but a superseded copy of its claim remains at $backup; it names a released path and must never be restored over the record." >&2
      FM_WORKTREE_OWNERSHIP_PROOF=no-worktree-claim
      return 0
    fi
    if [ -n "$backup" ]; then
      fm_worktree_refuse "task $id has no worktree claim in $meta; an interrupted claim retirement left its recoverable copy at $backup."
      return 1
    fi
    FM_WORKTREE_OWNERSHIP_PROOF=no-worktree-claim
    return 0
  fi

  canonical=$(fm_worktree_claim_comparison_path "$worktree") || {
    fm_worktree_refuse "task $id's recorded worktree $worktree is not an absolute path, so ownership cannot be proved."
    return 1
  }
  if [ -d "$canonical" ]; then present=1; fi
  fm_worktree_no_conflicting_claim "$state" "$id" "$meta" "$canonical" || return 1

  if [ "$backend" = orca ] && [ "$kind" != secondmate ]; then
    worktree_id=$(fm_worktree_meta_exact_value "$meta" orca_worktree_id) || {
      fm_worktree_refuse "task $id has no exact Orca worktree id to prove ownership of $canonical."
      return 1
    }
    if ! declare -F fm_backend_worktree_path >/dev/null 2>&1; then
      fm_worktree_refuse "Orca ownership resolver is unavailable for task $id worktree id $worktree_id."
      return 1
    fi
    if resolved=$(fm_backend_worktree_path orca "$worktree_id"); then
      resolved_canonical=$(fm_worktree_claim_comparison_path "$resolved") || {
        fm_worktree_refuse "Orca worktree id $worktree_id for task $id resolved to unusable path ${resolved:-missing}."
        return 1
      }
      if [ "$resolved_canonical" != "$canonical" ]; then
        fm_worktree_refuse "Orca worktree id $worktree_id for task $id resolves to $resolved_canonical, not recorded path $canonical."
        return 1
      fi
      provider_proof=orca-worktree-id
      # Published to callers that source this library.
      # shellcheck disable=SC2034
      FM_WORKTREE_OWNERSHIP_ORCA_PATH_MATCH=1
    else
      # An id the provider cannot resolve binds to no live worktree, so it can
      # only stay a refusal while the recorded path is still there to inspect.
      if [ "$present" -eq 1 ]; then
        fm_worktree_refuse "Orca worktree id $worktree_id for task $id could not be resolved."
        return 1
      fi
    fi
  fi

  if [ "$present" -eq 0 ]; then
    # The recorded path holds nothing: no marker, HEAD, or branch survives to
    # inspect, and no live worker can be destroyed at a path that is gone.
    [ -n "$provider_proof" ] || provider_proof=vacant-worktree
  elif [ "$kind" = secondmate ]; then
    marker="$canonical/.fm-secondmate-home"
    if [ ! -f "$marker" ] || [ -L "$marker" ]; then
      fm_worktree_refuse "secondmate $id worktree $canonical has no regular .fm-secondmate-home ownership marker."
      return 1
    fi
    if [ "$(cat "$marker" 2>/dev/null || true)" != "$id" ]; then
      fm_worktree_refuse "secondmate worktree $canonical is marked for task $(cat "$marker" 2>/dev/null || printf unknown), not task $id."
      return 1
    fi
    [ -n "$provider_proof" ] || provider_proof=secondmate-marker
  else
    marker_rc=0
    fm_worktree_task_owner_marker_binding "$canonical" "$id" "$spawn_gen" || marker_rc=$?
    [ "$marker_rc" -ne 1 ] || return 1
    if [ "$marker_rc" -eq 0 ]; then
      provider_proof=task-owner-marker
    elif [ -n "$provider_proof" ]; then
      :
    else
      rc=0
      fm_worktree_task_branch_proves_owner "$canonical" "$id" || rc=$?
      case "$rc" in
        0) provider_proof=task-branch ;;
        2)
          fm_worktree_project_worktree_binding "$project" "$canonical" "$id" || return 1
          provider_proof='project-worktree'
          ;;
        *)
          fm_worktree_refuse "worktree $canonical is checked out on task branch $FM_WORKTREE_TASK_BRANCH_CONFLICT, not task $id branch fm/$id, and nothing else proves task $id still owns it."
          return 1
          ;;
      esac
    fi
  fi

  # Published to callers that source this library.
  # shellcheck disable=SC2034
  FM_WORKTREE_OWNERSHIP_PATH=$canonical
  # shellcheck disable=SC2034
  FM_WORKTREE_OWNERSHIP_PROOF=$provider_proof
  return 0
}

fm_worktree_claim_retire_begin() {  # <meta-file> <expected-worktree>
  local meta=$1 expected=$2 recorded expected_canonical recorded_canonical dir base backup tmp
  local claim_rc=0 hint released receipt_rc=1
  if [ "$FM_WORKTREE_CLAIM_RETIRE_ACTIVE" != 0 ]; then
    fm_worktree_refuse "cannot retire worktree claim in $meta because another claim retirement is already active on $FM_WORKTREE_CLAIM_RETIRE_META."
    return 1
  fi
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    fm_worktree_refuse "cannot clear worktree claim because $meta is not a regular metadata file."
    return 1
  }
  recorded=$(fm_worktree_meta_claim "$meta" worktree) || claim_rc=$?
  if [ "$claim_rc" -eq 1 ]; then
    fm_worktree_refuse "cannot clear worktree claim because $meta has an ambiguous worktree claim."
    return 1
  fi
  if [ "$claim_rc" -eq 2 ]; then
    if [ -n "$expected" ]; then
      hint=$(fm_worktree_claim_backup_hint "$meta" || true)
      released=$(fm_worktree_retirement_receipt_present "$meta") && receipt_rc=0 || receipt_rc=$?
      if [ -n "$hint" ]; then
        fm_worktree_refuse "cannot clear worktree claim in $meta because it claims no path, yet expected $expected; an interrupted claim retirement left its recoverable copy at $hint."
      elif [ "$receipt_rc" -eq 0 ]; then
        fm_worktree_refuse "cannot clear worktree claim in $meta because the provider already released ${released:-its worktree}; expected $expected."
      else
        fm_worktree_refuse "cannot clear worktree claim in $meta because it claims no path, yet expected $expected."
      fi
      return 1
    fi
    # Nothing is claimed and nothing is targeted by path, so the invariant the
    # retirement exists to establish already holds.
    FM_WORKTREE_CLAIM_RETIRE_META=$meta
    FM_WORKTREE_CLAIM_RETIRE_BACKUP=
    FM_WORKTREE_CLAIM_RETIRE_PATH=
    FM_WORKTREE_CLAIM_RETIRE_MARKER=
    FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP=
    FM_WORKTREE_CLAIM_RETIRE_ACTIVE=1
    return 0
  fi
  recorded_canonical=$(fm_worktree_claim_comparison_path "$recorded" 2>/dev/null || true)
  expected_canonical=$(fm_worktree_claim_comparison_path "$expected" 2>/dev/null || true)
  if [ -z "$recorded_canonical" ] || [ -z "$expected_canonical" ] \
    || [ "$recorded_canonical" != "$expected_canonical" ]; then
    fm_worktree_refuse "cannot clear worktree claim in $meta because it records $recorded, not expected path $expected."
    return 1
  fi
  dir=${meta%/*}
  base=${meta##*/}
  backup=$(umask 077; mktemp "$dir/.${base}.worktree-claim-backup.XXXXXX") || return 1
  tmp=$(umask 077; mktemp "$dir/.${base}.worktree-claim-next.XXXXXX") || {
    rm -f -- "$backup"
    return 1
  }
  if ! cp -p -- "$meta" "$backup" \
    || ! awk '!/^worktree=/' "$meta" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! mv -f -- "$tmp" "$meta"; then
    rm -f -- "$tmp" "$backup"
    fm_worktree_refuse "could not atomically clear task worktree claim in $meta before provider return."
    return 1
  fi
  FM_WORKTREE_CLAIM_RETIRE_META=$meta
  FM_WORKTREE_CLAIM_RETIRE_BACKUP=$backup
  FM_WORKTREE_CLAIM_RETIRE_PATH=$expected
  FM_WORKTREE_CLAIM_RETIRE_ACTIVE=1
  fm_worktree_marker_retire "$dir" "$base" "$expected" || {
    fm_worktree_claim_retire_restore || true
    return 1
  }
}

# The in-worktree owner marker is the other half of the same claim, so it is
# retired in the same step: gone before the provider can recycle the slot, and
# put back with the claim if the provider operation fails.
fm_worktree_marker_retire() {  # <state-dir> <meta-basename> <expected-worktree>
  local dir=$1 base=$2 expected=$3 marker stash
  FM_WORKTREE_CLAIM_RETIRE_MARKER=
  FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP=
  [ -n "$expected" ] && [ -d "$expected" ] || return 0
  marker="$expected/$FM_WORKTREE_TASK_OWNER_MARKER"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 0
  stash=$(umask 077; mktemp "$dir/.${base}.task-owner-backup.XXXXXX") || return 1
  if ! cp -p -- "$marker" "$stash" || ! rm -f -- "$marker"; then
    rm -f -- "$stash"
    fm_worktree_refuse "could not retire the $FM_WORKTREE_TASK_OWNER_MARKER in $expected before the provider could reuse it."
    return 1
  fi
  FM_WORKTREE_CLAIM_RETIRE_MARKER=$marker
  FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP=$stash
}

# A failed provider call does not prove the path was not handed on, so the
# marker only goes back onto a path that carries no marker or still carries this
# exact task and generation.
fm_worktree_marker_still_ours() {  # <marker-path> <marker-backup>
  local marker=$1 backup=$2 key
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  for key in task_id spawn_gen; do
    [ "$(fm_worktree_meta_exact_value "$marker" "$key" 2>/dev/null || true)" \
      = "$(fm_worktree_meta_exact_value "$backup" "$key" 2>/dev/null || true)" ] || return 1
  done
}

fm_worktree_claim_retire_release() {
  local meta=$FM_WORKTREE_CLAIM_RETIRE_META backup=$FM_WORKTREE_CLAIM_RETIRE_BACKUP
  local released=$FM_WORKTREE_CLAIM_RETIRE_PATH
  local marker_backup=$FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP
  local recorded=0
  [ "$FM_WORKTREE_CLAIM_RETIRE_ACTIVE" != 0 ] || return 0
  FM_WORKTREE_CLAIM_RETIRE_META=
  FM_WORKTREE_CLAIM_RETIRE_BACKUP=
  FM_WORKTREE_CLAIM_RETIRE_PATH=
  FM_WORKTREE_CLAIM_RETIRE_MARKER=
  FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP=
  FM_WORKTREE_CLAIM_RETIRE_ACTIVE=0
  if [ -n "$marker_backup" ] && ! rm -f -- "$marker_backup"; then
    echo "warning: the retired owner marker's copy at $marker_backup could not be removed; it names a slot this task no longer owns and is safe to delete." >&2
  fi
  if [ -z "$released" ] || [ -z "$meta" ] || fm_worktree_retirement_receipt_write "$meta" "$released"; then
    recorded=1
  fi
  if [ "$recorded" -ne 1 ]; then
    # Nothing restores this copy - the path is the provider's again - but with
    # the retirement unrecorded it is the only evidence of what was released, so
    # it stays until the record it describes is gone.
    fm_worktree_refuse "the provider released $released, but the retirement beside $meta could not be recorded; ${backup:-no copy of the record} is the only surviving evidence of it and must never be restored over the record."
    return "$FM_WORKTREE_RETIREMENT_UNRECORDED"
  fi
  if [ -n "$backup" ] && ! rm -f -- "$backup"; then
    echo "warning: the retired worktree claim's copy at $backup could not be removed; $released is released and that copy must never be restored over the record." >&2
  fi
}

fm_worktree_claim_retire_commit() {
  local backup=$FM_WORKTREE_CLAIM_RETIRE_BACKUP
  local marker_backup=$FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP
  [ "$FM_WORKTREE_CLAIM_RETIRE_ACTIVE" != 0 ] || return 0
  if [ -n "$backup" ] && ! rm -f -- "$backup"; then
    fm_worktree_refuse "worktree claim was cleared, but its retirement backup could not be removed at $backup."
    return 1
  fi
  if [ -n "$marker_backup" ] && ! rm -f -- "$marker_backup"; then
    fm_worktree_refuse "the worktree owner marker was retired, but its backup could not be removed at $marker_backup."
    return 1
  fi
  FM_WORKTREE_CLAIM_RETIRE_META=
  FM_WORKTREE_CLAIM_RETIRE_BACKUP=
  FM_WORKTREE_CLAIM_RETIRE_PATH=
  FM_WORKTREE_CLAIM_RETIRE_MARKER=
  FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP=
  FM_WORKTREE_CLAIM_RETIRE_ACTIVE=0
}

# Closes a retirement interrupted between the claim rewrite and the provider's
# verdict. The provider may or may not have released the path, so the claim is
# never put back: the surviving copy is named as the recovery source and every
# later proof over the claimless record refuses until an operator resolves it.
fm_worktree_claim_retire_abandon() {
  local meta=$FM_WORKTREE_CLAIM_RETIRE_META backup=$FM_WORKTREE_CLAIM_RETIRE_BACKUP
  local marker_backup=$FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP
  [ "$FM_WORKTREE_CLAIM_RETIRE_ACTIVE" != 0 ] || return 0
  FM_WORKTREE_CLAIM_RETIRE_META=
  FM_WORKTREE_CLAIM_RETIRE_BACKUP=
  FM_WORKTREE_CLAIM_RETIRE_PATH=
  FM_WORKTREE_CLAIM_RETIRE_MARKER=
  FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP=
  FM_WORKTREE_CLAIM_RETIRE_ACTIVE=0
  if [ -n "$backup" ] && [ -f "$meta" ] && [ ! -L "$meta" ]; then
    echo "warning: a worktree claim retirement for $meta was interrupted before the provider reported its result; the recoverable claim is at $backup and every lifecycle verb refuses this record until it is resolved." >&2
    [ -z "$marker_backup" ] || rm -f -- "$marker_backup" || true
    return 0
  fi
  [ -z "$backup" ] || rm -f -- "$backup" || true
  [ -z "$marker_backup" ] || rm -f -- "$marker_backup" || true
}

fm_worktree_claim_retire_restore() {
  local meta=$FM_WORKTREE_CLAIM_RETIRE_META backup=$FM_WORKTREE_CLAIM_RETIRE_BACKUP
  local marker=$FM_WORKTREE_CLAIM_RETIRE_MARKER
  local marker_backup=$FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP
  [ "$FM_WORKTREE_CLAIM_RETIRE_ACTIVE" != 0 ] || return 0
  # Eligibility is settled before either half moves, so a path that has moved on
  # leaves the retirement whole and open rather than half put back.
  if [ -n "$marker_backup" ] && [ -d "${marker%/*}" ] \
    && ! fm_worktree_marker_still_ours "$marker" "$marker_backup"; then
    fm_worktree_refuse "provider return failed, but $marker now belongs to another task, so this record was left retired rather than pointed back at that path."
    return 1
  fi
  if [ -n "$backup" ] && ! mv -f -- "$backup" "$meta"; then
    fm_worktree_refuse "provider return failed and the worktree claim could not be restored to $meta; recover it from $backup."
    return 1
  fi
  if [ -n "$marker_backup" ] && [ -d "${marker%/*}" ] \
    && ! mv -f -- "$marker_backup" "$marker"; then
    fm_worktree_refuse "provider return failed and the worktree owner marker could not be restored to $marker; recover it from $marker_backup."
    return 1
  fi
  [ -z "$marker_backup" ] || rm -f -- "$marker_backup"
  FM_WORKTREE_CLAIM_RETIRE_META=
  FM_WORKTREE_CLAIM_RETIRE_BACKUP=
  FM_WORKTREE_CLAIM_RETIRE_PATH=
  FM_WORKTREE_CLAIM_RETIRE_MARKER=
  FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP=
  FM_WORKTREE_CLAIM_RETIRE_ACTIVE=0
}
