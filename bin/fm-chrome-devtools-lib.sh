#!/usr/bin/env bash
# Task-scoped chrome-devtools-axi bridge bindings.
#
# fm_chrome_task_session_name <state-dir> <task-id>
#   Prints a deterministic, non-default chrome-devtools-axi session name bound
#   to one task in one Firstmate home. The task-id prefix is diagnostic only;
#   the digest prevents equal task ids in separate homes from sharing a bridge.
#
# fm_chrome_binding_write <state-dir> <task-id>
#   Atomically writes <state-dir>/<task-id>.chrome-devtools-session, mode 0600,
#   with the exact session and a started marker, then exports the session through
#   FM_CHROME_TASK_SESSION. Every later rewriter of that record - the worker's
#   launcher under its own ambient umask, and cleanup's marker reset - restores
#   the same mode, so the record never widens after the task's first browser call.
#   A fresh record starts at started=0; rewriting the record for the same session
#   (relaunch) keeps an existing started=1 so a prior incarnation's live bridge
#   stays owned by the task.
#
# fm_chrome_launcher_dir_create <parent-dir>
#   Prints a fresh launcher directory created under an already-verified private
#   parent. The name carries a random component from mktemp, so the launcher
#   path is unpredictable even though the task temp root it lives in is a
#   derivable /tmp/fm-<id> name. mktemp also fails rather than reusing an
#   existing directory, so nothing pre-created can become the launcher.
#
# fm_chrome_wrapper_write <state-dir> <task-id> <wrapper-path> <real-tool>
#   Writes a task-private chrome-devtools-axi launcher. Before any browser action
#   can auto-start the bridge, the launcher atomically changes started=0 to
#   started=1. Read-only home/help/version and setup/stop commands do not mark it,
#   and a delegated stop that the tool reports succeeded clears the marker back to
#   started=0 the same way cleanup does, so a worker that shuts its own bridge down
#   is not later described as one whose bridge went missing. A stop the tool
#   reports failed leaves the marker set, so that task stays cleanup-eligible.
#   Every delegated command - marking or not - is then handed to the real tool
#   with the recorded session forced and any ambient CHROME_DEVTOOLS_AXI_PORT
#   dropped, so the binding holds even when the pane shell's exports did not
#   survive to the caller: a scrubbed environment, a nested shell, or an rc file
#   that re-exports the port can no longer put a marked task's bridge on the
#   captain's shared session. The launcher refuses to be written at all unless the
#   session it would force is the one already recorded for the task.
#   The launcher becomes the first entry on the worker's PATH, so it is written
#   only into a directory this user owns that no one else can write, and both the
#   directory and its parent are checked: the task temp root is a predictable
#   /tmp path, and a pre-created one must never let a local user shadow the
#   worker's commands. A directory that fails the check is refused, and the
#   caller drops the PATH prepend instead of launching through it.
#
# fm_chrome_bridge_bound
#   Prints the seconds one browser call may take, from FM_CHROME_BRIDGE_TIMEOUT:
#   unset, non-numeric, and zero take the 20-second default, and anything above
#   the 120-second ceiling is cut to it rather than honoured. A knob that bounds
#   teardown-time work cannot itself be a way to un-bound teardown.
#
# fm_chrome_bound_was_enforced <started-at-epoch> <bound-seconds>
#   Whether a call that came back with the bound-was-hit status really spent the
#   bound. fm_run_timed reports that status for its own scratch-file failure, for
#   a runner killed from outside, and for a tool that exits 124 by itself, none of
#   which say anything about whether the tool answers. An unreadable clock proves
#   nothing either, so it answers no.
#
# fm_chrome_axi_run <session> [args...]
#   The single door to the browser tool. Every call names the session, drops an
#   ambient CHROME_DEVTOOLS_AXI_PORT (which the tool documents as overriding the
#   port it otherwise derives from the session name, so an inherited one would
#   silently retarget another bridge), and runs under a hard bound because the
#   tool can be a wrapper chain onto a browser that stopped answering. It returns
#   124 only for a bound this call is measured to have actually consumed; a
#   bound-was-hit status from any other cause is reported as 125, which reads as
#   one more unusable answer about one name rather than as a verdict on the tool.
#   Once a call in this process has spent the bound the tool is not answering at
#   all, so later calls report the bound status without invoking it again:
#   teardown asks about every task and runs cleanup twice per task, and none of
#   those calls can learn anything a hung tool did not already refuse to say.
#
# fm_chrome_session_liveness <session>
#   Prints inactive, present, unreadable, or unresponsive for that exact named
#   session by asking the tool for its status. The tool's only statement this repo
#   has evidence for is the negative one - it reports "no active session" for a
#   name with no bridge behind it - so inactive is the single confident answer,
#   and no wording for a live bridge is guessed at. The rest separate "the tool
#   said something about this name that was not the gone answer" (present) from
#   "the tool said nothing usable at all" - empty output (unreadable) or the bound
#   was hit (unresponsive). The last two are the same absence of evidence about
#   this name and neither ever warrants a stop; they are named apart only because
#   a tool that never returns is a fact about the host that need not be
#   rediscovered per task.
#
# fm_chrome_ownership_evidence <session>
#   Proof, not assumption, that the resolved tool acts on the session it is
#   given: a sibling probe session this fleet never starts must read inactive,
#   and only that answer clears a stop. A PATH shim that rewrites every
#   invocation onto one shared bridge, or an inherited port that pins every
#   invocation to one bridge, answers active or unrecognized for that unused name
#   and fails the proof. This prints the probe's own liveness rather than a
#   verdict so callers can tell that failure - a tool that demonstrably pins every
#   call to one bridge - apart from a probe that answered nothing readable at all,
#   which establishes neither and must not be reported as a property of the host.
#   Consequence worth stating plainly: on a host whose resolved chrome-devtools-axi
#   is such a wrapper - one that hardcodes a single shared session name for every
#   call - the proof fails every time, so this reclamation is inert there. That is
#   the deliberate trade: the only stop that wrapper would carry out is a stop of
#   the captain's own bridge. Task-scoped reclamation starts working on that host
#   as soon as its wrapper passes CHROME_DEVTOOLS_AXI_SESSION through instead of
#   pinning it. The proof can only speak when the shared bridge is busy: while it
#   is idle such a wrapper answers "no active session" for every name, exactly as
#   an honest tool with nothing running would, so no probe can tell them apart.
#   fm_chrome_bridge_cleanup covers that blind spot by stating what its silence
#   does and does not establish whenever a task that recorded a bridge start needs
#   no stop, instead of letting that read as a completed reclamation.
#
# fm_chrome_binding_clear_started <state-dir> <task-id>
#   Resets the startup marker to 0 once the task's bridge is known gone or has
#   been stopped, preserving the record's 0600 mode.
#
# fm_chrome_bridge_cleanup <state-dir> <task-id>
#   Reads only that task's validated binding and never targets the default or
#   another task's session. A confident inactive makes no stop call, so a task
#   that never started a bridge and a bridge this teardown already stopped are
#   both silent. A present answer is evidence a bridge exists under this task's
#   own derived name - which a task that never started one cannot have - so it
#   reaches the stop whether or not the launcher marked the start; that is what
#   reclaims a bridge the worker opened around the launcher. An unreadable answer
#   is no evidence at all, so it never reaches a stop, marker or no marker: a
#   recorded start says a bridge was opened under this name, not that one is
#   running now, and a bounded-out or silent tool could equally be a session-blind
#   dispatcher answering for the captain's own bridge. The marker still decides
#   what is said - an unreclaimed bridge may be left behind, and that is reported.
#   Every stop still passes the ownership proof, which itself needs a confident
#   inactive on a never-used probe name. That pairing is the whole warrant for
#   acting: the same tool answers "gone" for a name nobody started and something
#   else for this task's name. A tool that cannot produce that pair - one that
#   pins every call to one bridge, or whose answers cannot be read at all - never
#   reaches a stop, so the captain's own bridge is never the thing that gets
#   stopped, and the two are reported apart because only the first is a standing
#   property of the host. Missing bindings are no-ops, missing tools, unproved
#   ownership, unreadable answers, and stop errors warn but remain non-fatal, and
#   callers own record retirement.

# Directory of this library, used to locate the sibling bounded runner. Resolved
# at source time from BASH_SOURCE so it works whether sourced by a bin/ script
# (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CHROME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CHROME_LIB_DIR="."
# A browser tool that never returns is a property of this host, not of any one
# session name, so one process pays that bound once. Set only by cleanup, which
# runs in the caller's own shell; the bounded runner reads it from its command
# substitutions, where a write would be lost with the subshell.
_FM_CHROME_TOOL_UNRESPONSIVE=0
# fm_run_timed owns bounded execution for this repo, including the hung-grandchild
# case a vendor CLI behind a wrapper script creates. It declares `set -u` for its
# own hygiene, which must not leak onto this library's consumers.
case $- in *u*) _fm_chrome_nounset=on ;; *) _fm_chrome_nounset=off ;; esac
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$_FM_CHROME_LIB_DIR/fm-timeout-lib.sh"
[ "$_fm_chrome_nounset" = on ] || set +u

fm_chrome_task_session_name() {  # <state-dir> <task-id>
  local state=$1 id=$2 state_real digest prefix
  state_real=$(CDPATH='' cd -- "$state" 2>/dev/null && pwd -P) || return 1
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s\n%s' "$state_real" "$id" | shasum -a 256 2>/dev/null | awk '{print $1}') || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s\n%s' "$state_real" "$id" | sha256sum 2>/dev/null | awk '{print $1}') || return 1
  else
    return 1
  fi
  case "$digest" in
    ''|*[!a-fA-F0-9]*) return 1 ;;
  esac
  prefix=${id:0:28}
  printf 'fm-%s-%s\n' "$prefix" "${digest:0:28}"
}

fm_chrome_binding_write() {  # <state-dir> <task-id>
  local state=$1 id=$2 session record tmp old_umask started=0 prior_session prior_started
  session=$(fm_chrome_task_session_name "$state" "$id") || return 1
  [ "$session" != default ] || return 1
  record="$state/$id.chrome-devtools-session"
  if [ -f "$record" ] && [ ! -L "$record" ]; then
    prior_session=$(sed -n 's/^session=//p' "$record" 2>/dev/null || true)
    prior_started=$(sed -n 's/^started=//p' "$record" 2>/dev/null || true)
    if [ "$prior_session" = "$session" ] && [ "$prior_started" = 1 ]; then
      started=1
    fi
  fi
  tmp="$state/.$id.chrome-devtools-session.${BASHPID:-$$}"
  old_umask=$(umask)
  umask 077
  if ! printf 'session=%s\nstarted=%s\n' "$session" "$started" > "$tmp" || ! mv -f -- "$tmp" "$record"; then
    rm -f -- "$tmp" 2>/dev/null || true
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
  # shellcheck disable=SC2034 # Output variable consumed by the sourcing caller.
  FM_CHROME_TASK_SESSION=$session
}

fm_chrome_dir_is_task_private() {  # <dir>
  local dir=$1 mode
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  [ -O "$dir" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f %Lp "$dir" 2>/dev/null) || return 1
  else
    mode=$(stat -c %a "$dir" 2>/dev/null) || return 1
  fi
  case "$mode" in
    ''|*[!0-7]*) return 1 ;;
  esac
  case "$mode" in
    *[2367]) return 1 ;;
    *[2367]?) return 1 ;;
  esac
  return 0
}

fm_chrome_launcher_dir_create() {  # <parent-dir>
  local parent=$1 dir
  fm_chrome_dir_is_task_private "$parent" || return 1
  dir=$(umask 077; mktemp -d -- "$parent/bin.XXXXXXXXXXXX" 2>/dev/null) || return 1
  if ! fm_chrome_dir_is_task_private "$dir"; then
    rmdir -- "$dir" 2>/dev/null || true
    return 1
  fi
  printf '%s\n' "$dir"
}

fm_chrome_wrapper_write() {  # <state-dir> <task-id> <wrapper-path> <real-tool>
  local state=$1 id=$2 wrapper=$3 tool=$4 record tmp old_umask wrapper_dir session recorded
  record="$state/$id.chrome-devtools-session"
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  session=$(fm_chrome_task_session_name "$state" "$id") || return 1
  [ -n "$session" ] && [ "$session" != default ] || return 1
  recorded=$(sed -n 's/^session=//p' "$record" 2>/dev/null || true)
  [ "$recorded" = "$session" ] || return 1
  case "$tool" in /*) ;; *) return 1 ;; esac
  [ -x "$tool" ] || return 1
  wrapper_dir=$(dirname -- "$wrapper") || return 1
  fm_chrome_dir_is_task_private "$(dirname -- "$wrapper_dir")" || return 1
  (umask 077; mkdir -p -- "$wrapper_dir") || return 1
  fm_chrome_dir_is_task_private "$wrapper_dir" || return 1
  tmp="$wrapper.tmp.${BASHPID:-$$}"
  old_umask=$(umask)
  umask 077
  if ! {
    printf '%s\n' '#!/usr/bin/env bash' 'set -u'
    printf 'record=%q\n' "$record"
    printf 'tool=%q\n' "$tool"
    printf 'session=%q\n' "$session"
    cat <<'SH'
case "${1:-}" in
  ''|-h|--help|-v|-V|--version|setup|stop) ;;
  *)
    if [ ! -f "$record" ] || [ -L "$record" ]; then
      echo "chrome-devtools-axi: task bridge binding is unavailable; refusing to start an untracked bridge" >&2
      exit 1
    fi
    marker_tmp="$record.started.${BASHPID:-$$}"
    if ! (umask 077; awk -F= '
      $1 == "started" { print "started=1"; found=1; next }
      { print }
      END { if (!found) exit 1 }
    ' "$record" > "$marker_tmp") || ! chmod 600 -- "$marker_tmp" \
      || ! mv -f -- "$marker_tmp" "$record"; then
      rm -f -- "$marker_tmp" 2>/dev/null || true
      echo "chrome-devtools-axi: could not record task bridge startup; refusing to start an untracked bridge" >&2
      exit 1
    fi
    ;;
esac
if [ "${1:-}" = stop ]; then
  env -u CHROME_DEVTOOLS_AXI_PORT "CHROME_DEVTOOLS_AXI_SESSION=$session" "$tool" ${1+"$@"}
  stop_status=$?
  if [ "$stop_status" -eq 0 ] && [ -f "$record" ] && [ ! -L "$record" ] \
    && grep -q '^started=1$' "$record" 2>/dev/null; then
    cleared_tmp="$record.stopped.${BASHPID:-$$}"
    if ! (umask 077; sed 's/^started=1$/started=0/' "$record" > "$cleared_tmp") \
      || ! chmod 600 -- "$cleared_tmp" || ! mv -f -- "$cleared_tmp" "$record"; then
      rm -f -- "$cleared_tmp" 2>/dev/null || true
      echo "chrome-devtools-axi: the task bridge binding could not be reset after this stop; teardown will re-check that session" >&2
    fi
  fi
  exit "$stop_status"
fi
exec env -u CHROME_DEVTOOLS_AXI_PORT "CHROME_DEVTOOLS_AXI_SESSION=$session" "$tool" ${1+"$@"}
SH
  } > "$tmp" || ! chmod 700 "$tmp" || ! mv -f -- "$tmp" "$wrapper"; then
    rm -f -- "$tmp" 2>/dev/null || true
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
}

fm_chrome_bridge_bound() {
  local bound=${FM_CHROME_BRIDGE_TIMEOUT:-20}
  case "$bound" in
    ''|*[!0-9]*) printf '20\n'; return 0 ;;
  esac
  while [ "${#bound}" -gt 1 ] && [ "${bound#0}" != "$bound" ]; do
    bound=${bound#0}
  done
  # Four digits or more is already past the ceiling, and comparing it as a number
  # first would hand the shell an overflowing literal.
  if [ "${#bound}" -gt 3 ]; then
    bound=120
  elif [ "$bound" -lt 1 ]; then
    bound=20
  elif [ "$bound" -gt 120 ]; then
    bound=120
  fi
  printf '%s\n' "$bound"
}

fm_chrome_bound_was_enforced() {  # <started-at-epoch> <bound-seconds>
  local started_at=$1 bound=$2 now
  case "$started_at" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s 2>/dev/null || true)
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ "$now" -ge "$started_at" ] || return 1
  [ "$((now - started_at))" -ge "$bound" ] || return 1
  return 0
}

fm_chrome_axi_run() {  # <session> [args...]
  local session=$1 bound started_at status
  shift
  [ "${_FM_CHROME_TOOL_UNRESPONSIVE:-0}" != 1 ] || return 124
  bound=$(fm_chrome_bridge_bound)
  started_at=$(date +%s 2>/dev/null || true)
  fm_run_timed "$bound" \
    env -u CHROME_DEVTOOLS_AXI_PORT "CHROME_DEVTOOLS_AXI_SESSION=$session" \
    chrome-devtools-axi ${1+"$@"} < /dev/null
  status=$?
  # fm_run_timed also returns its bound-was-hit status when its own scratch file
  # could not be made, when the runner itself was killed, and when the tool exits
  # 124 of its own accord. Only a call that actually consumed the bound proves the
  # tool does not answer, so only that one may speak for every later call.
  [ "$status" -eq 124 ] || return "$status"
  fm_chrome_bound_was_enforced "$started_at" "$bound" || return 125
  return 124
}

fm_chrome_session_liveness() {  # <session>
  local session=$1 status answer
  # Both streams and any exit status: a tool that reports the one contract line
  # this repo has evidence for on stderr, or alongside a nonzero status, is still
  # understood. Nothing is inferred from a positive-sounding answer.
  answer=$(fm_chrome_axi_run "$session" 2>&1) && status=0 || status=$?
  case "$answer" in
    *'no active session'*) printf 'inactive\n'; return 0 ;;
  esac
  # 124 is fm_run_timed's bound-was-hit status, so a truncated answer counts as
  # no answer. It is reported apart from an empty answer because a tool that never
  # returns is a property of the host, not of this name: the caller can stop
  # paying the bound for every later name. Anything else the tool actually said
  # about this name is a readable answer that is not the gone answer.
  if [ "$status" = 124 ]; then
    printf 'unresponsive\n'
  elif [ -z "$answer" ]; then
    printf 'unreadable\n'
  else
    printf 'present\n'
  fi
}

fm_chrome_probe_session_name() {  # <session>
  printf 'fmprobe-%s\n' "${1#fm-}"
}

fm_chrome_ownership_evidence() {  # <session>
  local session=$1 probe
  probe=$(fm_chrome_probe_session_name "$session" 2>/dev/null || true)
  if [ -z "$probe" ] || [ "$probe" = "$session" ] || [ "$probe" = default ]; then
    printf 'unreadable\n'
    return 0
  fi
  fm_chrome_session_liveness "$probe"
}

fm_chrome_binding_clear_started() {  # <state-dir> <task-id>
  local state=$1 id=$2 record tmp
  record="$state/$id.chrome-devtools-session"
  [ -f "$record" ] && [ ! -L "$record" ] || return 0
  grep -q '^started=1$' "$record" 2>/dev/null || return 0
  tmp="$record.cleanup.${BASHPID:-$$}"
  if ! (umask 077; sed 's/^started=1$/started=0/' "$record" > "$tmp") \
    || ! chmod 600 -- "$tmp" || ! mv -f -- "$tmp" "$record"; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
  return 0
}

fm_chrome_bridge_cleanup() {  # <state-dir> <task-id>
  local state=$1 id=$2 record session started expected liveness proof tool_known_silent stop_status
  record="$state/$id.chrome-devtools-session"
  [ -e "$record" ] || [ -L "$record" ] || return 0
  if [ ! -f "$record" ] || [ -L "$record" ]; then
    echo "warning: chrome-devtools bridge binding for task $id is not an ordinary file; skipping bridge cleanup" >&2
    return 0
  fi
  if [ "$(wc -l < "$record" 2>/dev/null || printf '0')" -ne 2 ]; then
    echo "warning: chrome-devtools bridge binding for task $id is malformed; skipping bridge cleanup" >&2
    return 0
  fi
  session=$(sed -n 's/^session=//p' "$record" 2>/dev/null || true)
  started=$(sed -n 's/^started=//p' "$record" 2>/dev/null || true)
  expected=$(fm_chrome_task_session_name "$state" "$id" 2>/dev/null || true)
  if [ -z "$session" ] || [ "$session" = default ] || [ -z "$expected" ] || [ "$session" != "$expected" ]; then
    echo "warning: chrome-devtools bridge binding for task $id does not match its task-scoped session; skipping bridge cleanup" >&2
    return 0
  fi
  case "$started" in
    0|1) ;;
    *)
      echo "warning: chrome-devtools bridge binding for task $id has an invalid startup marker; skipping bridge cleanup" >&2
      return 0
      ;;
  esac
  if ! command -v chrome-devtools-axi >/dev/null 2>&1; then
    if [ "$started" = 1 ]; then
      echo "warning: chrome-devtools-axi is unavailable; task $id bridge cleanup was skipped" >&2
    fi
    return 0
  fi
  # The marker only covers bridges opened through the task-private launcher. Ask
  # the tool about this exact session so a bridge started around the launcher is
  # still stopped, so an already-stopped session raises no false failure, and so
  # every stop rests on what the tool said about this name rather than on a
  # record of what happened earlier.
  tool_known_silent=${_FM_CHROME_TOOL_UNRESPONSIVE:-0}
  liveness=$(fm_chrome_session_liveness "$session")
  [ "$liveness" != unresponsive ] || _FM_CHROME_TOOL_UNRESPONSIVE=1
  if [ "$liveness" = inactive ]; then
    # A tool that pins every call to one shared bridge says exactly this, for any
    # name it is handed, whenever that shared bridge happens to be idle - the
    # ownership proof cannot separate it from an honest tool in that moment,
    # because both answer "gone" for every name. So when the task did record a
    # bridge start and no stop was needed, say what was and was not established
    # rather than letting silence read as a completed reclamation.
    if [ "$started" = 1 ]; then
      echo "warning: task $id recorded a chrome-devtools bridge start and chrome-devtools-axi now reports session $session gone, so no stop was issued. That answer is about this task's bridge only if the resolved chrome-devtools-axi passes CHROME_DEVTOOLS_AXI_SESSION through: a wrapper that pins every call to one shared bridge reports the same thing while this task's bridge is still running, and task-scoped bridge reclamation is inert on such a host" >&2
    fi
    fm_chrome_binding_clear_started "$state" "$id" \
      || echo "warning: chrome-devtools bridge for task $id is already gone, but its binding could not be reset" >&2
    return 0
  fi
  case "$liveness" in
    unreadable|unresponsive)
      if [ "$started" = 1 ]; then
        echo "warning: chrome-devtools-axi returned no readable status for task $id session $session, so no stop was issued; that task's launcher did record a bridge start, so a bridge may still be running under that session and needs reclaiming by hand" >&2
      elif [ "$tool_known_silent" != 1 ]; then
        echo "warning: chrome-devtools-axi returned no readable status for task $id session $session; that task's launcher recorded no bridge start, so no stop was issued" >&2
      fi
      return 0
      ;;
  esac
  proof=$(fm_chrome_ownership_evidence "$session")
  [ "$proof" != unresponsive ] || _FM_CHROME_TOOL_UNRESPONSIVE=1
  case "$proof" in
    unreadable|unresponsive)
      echo "warning: chrome-devtools-axi returned no readable status for the ownership probe on task $id, so nothing was established about whether it scopes bridges by session; skipping the bridge stop for session $session" >&2
      return 0
      ;;
  esac
  if [ "$proof" != inactive ]; then
    echo "warning: chrome-devtools-axi does not act on the task-scoped session for task $id; skipping the bridge stop for session $session so no shared bridge is disturbed. Task-scoped bridge reclamation is inert on this host until chrome-devtools-axi passes CHROME_DEVTOOLS_AXI_SESSION through" >&2
    return 0
  fi
  stop_status=0
  fm_chrome_axi_run "$session" stop >/dev/null 2>&1 || stop_status=$?
  if [ "$stop_status" != 0 ]; then
    [ "$stop_status" != 124 ] || _FM_CHROME_TOOL_UNRESPONSIVE=1
    echo "warning: chrome-devtools bridge stop failed for task $id session $session; teardown will continue" >&2
    return 0
  fi
  fm_chrome_binding_clear_started "$state" "$id" \
    || echo "warning: chrome-devtools bridge stopped for task $id, but its binding could not be reset" >&2
  return 0
}
