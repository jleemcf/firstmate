#!/usr/bin/env bash
# Task-scoped chrome-devtools-axi bridge bindings.
#
# fm_chrome_task_session_name <state-dir> <task-id>
#   Prints a deterministic, non-default chrome-devtools-axi session name bound
#   to one task in one Firstmate home. The task-id prefix is diagnostic only;
#   the digest prevents equal task ids in separate homes from sharing a bridge.
#
# fm_chrome_binding_write <state-dir> <task-id>
#   Atomically writes <state-dir>/<task-id>.chrome-devtools-session with the
#   exact session and a started marker, then exports the session through
#   FM_CHROME_TASK_SESSION. A fresh record starts at started=0; rewriting the
#   record for the same session (relaunch) keeps an existing started=1 so a
#   prior incarnation's live bridge stays owned by the task.
#
# fm_chrome_wrapper_write <state-dir> <task-id> <wrapper-path> <real-tool>
#   Writes a task-private chrome-devtools-axi launcher. Before any browser action
#   can auto-start the bridge, the launcher atomically changes started=0 to
#   started=1. Read-only home/help/version and setup/stop commands do not mark it.
#
# fm_chrome_session_liveness <session>
#   Prints active, inactive, or unknown for that exact named session by asking
#   the tool for its status. unknown covers a missing, failing, or unrecognized
#   answer, so callers fall back to the recorded marker rather than guessing.
#
# fm_chrome_bridge_cleanup <state-dir> <task-id>
#   Reads only that task's validated binding and never targets the default or
#   another task's session. It stops the bridge when the tool reports that exact
#   session active, or when the launcher recorded a start and liveness cannot be
#   determined; an inactive session makes no stop call, so a task that never
#   started a bridge and a bridge this teardown already stopped are both silent.
#   Missing bindings are no-ops, missing tools and stop errors warn but remain
#   non-fatal, and callers own record retirement.

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

fm_chrome_wrapper_write() {  # <state-dir> <task-id> <wrapper-path> <real-tool>
  local state=$1 id=$2 wrapper=$3 tool=$4 record tmp old_umask
  record="$state/$id.chrome-devtools-session"
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  case "$tool" in /*) ;; *) return 1 ;; esac
  [ -x "$tool" ] || return 1
  mkdir -p -- "$(dirname -- "$wrapper")" || return 1
  tmp="$wrapper.tmp.${BASHPID:-$$}"
  old_umask=$(umask)
  umask 077
  if ! {
    printf '%s\n' '#!/usr/bin/env bash' 'set -u'
    printf 'record=%q\n' "$record"
    printf 'tool=%q\n' "$tool"
    cat <<'SH'
case "${1:-}" in
  ''|-h|--help|-v|-V|--version|setup|stop) ;;
  *)
    if [ ! -f "$record" ] || [ -L "$record" ]; then
      echo "chrome-devtools-axi: task bridge binding is unavailable; refusing to start an untracked bridge" >&2
      exit 1
    fi
    marker_tmp="$record.started.${BASHPID:-$$}"
    if ! awk -F= '
      $1 == "started" { print "started=1"; found=1; next }
      { print }
      END { if (!found) exit 1 }
    ' "$record" > "$marker_tmp" || ! mv -f -- "$marker_tmp" "$record"; then
      rm -f -- "$marker_tmp" 2>/dev/null || true
      echo "chrome-devtools-axi: could not record task bridge startup; refusing to start an untracked bridge" >&2
      exit 1
    fi
    ;;
esac
exec "$tool" "$@"
SH
  } > "$tmp" || ! chmod 700 "$tmp" || ! mv -f -- "$tmp" "$wrapper"; then
    rm -f -- "$tmp" 2>/dev/null || true
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
}

fm_chrome_session_liveness() {  # <session>
  local session=$1 status
  status=$(CHROME_DEVTOOLS_AXI_SESSION="$session" chrome-devtools-axi 2>/dev/null) || {
    printf 'unknown\n'
    return 0
  }
  case "$status" in
    *'no active session'*) printf 'inactive\n' ;;
    '') printf 'unknown\n' ;;
    *page:*|*pages:*|*target:*|*targets:*) printf 'active\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

fm_chrome_binding_clear_started() {  # <state-dir> <task-id>
  local state=$1 id=$2 record tmp
  record="$state/$id.chrome-devtools-session"
  [ -f "$record" ] && [ ! -L "$record" ] || return 0
  grep -q '^started=1$' "$record" 2>/dev/null || return 0
  tmp="$record.cleanup.${BASHPID:-$$}"
  if ! sed 's/^started=1$/started=0/' "$record" > "$tmp" || ! mv -f -- "$tmp" "$record"; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
  return 0
}

fm_chrome_bridge_cleanup() {  # <state-dir> <task-id>
  local state=$1 id=$2 record session started expected liveness
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
  # still stopped, and so an already-stopped session raises no false failure.
  liveness=$(fm_chrome_session_liveness "$session")
  case "$liveness" in
    active) ;;
    inactive)
      fm_chrome_binding_clear_started "$state" "$id" \
        || echo "warning: chrome-devtools bridge for task $id is already gone, but its binding could not be reset" >&2
      return 0
      ;;
    *)
      [ "$started" = 1 ] || return 0
      ;;
  esac
  if ! CHROME_DEVTOOLS_AXI_SESSION="$session" chrome-devtools-axi stop >/dev/null 2>&1; then
    echo "warning: chrome-devtools bridge stop failed for task $id session $session; teardown will continue" >&2
    return 0
  fi
  fm_chrome_binding_clear_started "$state" "$id" \
    || echo "warning: chrome-devtools bridge stopped for task $id, but its binding could not be reset" >&2
  return 0
}
