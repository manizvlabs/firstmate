#!/usr/bin/env bash
# fm-nm-trust-lib.sh - detect an untrusted no-mistakes validation workspace
# before firstmate dispatches work that will run the gate.
#
# The hazard, verified 19 August 2026 on drone-games-iot: a no-mistakes run
# failed at the review step with
#
#   step review failed: agent review: claude exited: exit status 1: Ignoring 3
#   permissions.allow entries from .claude/settings.local.json: this workspace
#   has not been trusted.
#
# The review agent died before reading a line of the diff, and the run still
# reported "findings: none" - which reads like a clean review that failed for an
# unrelated reason. It was diagnosed as quota exhaustion and the gate was
# restarted unchanged, costing roughly two hours and a full session.
#
# The validation workspace is the bare repo no-mistakes registers as the
# project's `no-mistakes` git remote (default ~/.no-mistakes/repos/<hash>.git).
# Claude Code records per-directory trust in ~/.claude.json (or
# $CLAUDE_CONFIG_DIR/.claude.json) under projects[<path>].hasTrustDialogAccepted.
#
# This library DETECTS and REFUSES only. Trusting a workspace is a security
# grant that belongs to the captain, so nothing here writes hasTrustDialogAccepted,
# rewrites Claude configuration, or works around the untrusted state by any other
# means. The refusal names the concrete workspace path and the one-time human
# remedy so the operator can act without reading a stack trace.
#
# Three verdicts, because a false refusal is its own failure:
#
#   trusted   - the workspace entry exists and hasTrustDialogAccepted is true.
#   untrusted - the trust grant is provably absent: the Claude config is readable
#               and has no entry for the workspace, or its entry does not set the
#               flag true, or the config file does not exist at all.
#   unknown   - the verdict cannot be established: the project has no local
#               `no-mistakes` remote (not initialized here yet, so there is no
#               workspace to trust), or no JSON reader is available to parse an
#               existing config. Callers proceed on unknown rather than refusing
#               a spawn on a question this library could not answer.
#
# Sourced by bin/fm-spawn.sh and by tests/fm-nm-trust.test.sh.
# No side effects on source. set -u / set -e safe.

# The exit code the refusal uses, distinct from an ordinary usage error and from
# the gate-context refusal in bin/fm-gate-refuse-lib.sh.
FM_NM_TRUST_EXIT=4

# fm_nm_trust_config_path: print the Claude Code config file that holds per-directory
# trust for this environment. CLAUDE_CONFIG_DIR relocates it (bin/fm-spawn.sh already
# threads that variable through claude launches for work-vs-personal splits).
fm_nm_trust_config_path() {
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    printf '%s\n' "${CLAUDE_CONFIG_DIR%/}/.claude.json"
  else
    printf '%s\n' "${HOME:-}/.claude.json"
  fi
}

# fm_nm_trust_workspace_path <project-dir>: print the local validation workspace
# registered as that project's `no-mistakes` remote, or return 1 when there is
# none. A non-absolute remote URL is not a local workspace directory, so it is
# not the trust-dialog case and returns 1 as well.
fm_nm_trust_workspace_path() {  # <project-dir>
  local dir=$1 url
  url=$(git -C "$dir" remote get-url no-mistakes 2>/dev/null) || return 1
  case "$url" in
    /*) printf '%s\n' "${url%/}" ;;
    *) return 1 ;;
  esac
}

# fm_nm_trust_status <workspace-path> [<config-file>]: print trusted, untrusted,
# or unknown for that exact workspace directory. Reads only; never writes.
fm_nm_trust_status() {  # <workspace-path> [<config-file>]
  local ws=$1 cfg=${2:-} verdict
  [ -n "$ws" ] || { printf 'unknown\n'; return 0; }
  [ -n "$cfg" ] || cfg=$(fm_nm_trust_config_path)
  if [ ! -f "$cfg" ]; then
    # No config file means no directory has ever been granted trust, so this
    # workspace provably has not been either.
    printf 'untrusted\n'
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    printf 'unknown\n'
    return 0
  fi
  verdict=$(FM_NM_TRUST_WS=$ws FM_NM_TRUST_CFG=$cfg node -e '
    const fs = require("fs");
    let cfg;
    try {
      cfg = JSON.parse(fs.readFileSync(process.env.FM_NM_TRUST_CFG, "utf8"));
    } catch (e) {
      process.stdout.write("unknown\n");
      process.exit(0);
    }
    const projects = (cfg && typeof cfg === "object" && cfg.projects) || null;
    if (!projects || typeof projects !== "object") {
      process.stdout.write("untrusted\n");
      process.exit(0);
    }
    const want = process.env.FM_NM_TRUST_WS.replace(/\/+$/, "");
    for (const key of Object.keys(projects)) {
      if (key.replace(/\/+$/, "") !== want) continue;
      const entry = projects[key];
      const ok = entry && typeof entry === "object" && entry.hasTrustDialogAccepted === true;
      process.stdout.write(ok ? "trusted\n" : "untrusted\n");
      process.exit(0);
    }
    process.stdout.write("untrusted\n");
  ' 2>/dev/null) || verdict=unknown
  case "$verdict" in
    trusted|untrusted|unknown) printf '%s\n' "$verdict" ;;
    *) printf 'unknown\n' ;;
  esac
}

# fm_nm_trust_refusal_message <project-dir> <workspace-path> [<config-file>]:
# print the operator-facing refusal. It names the concrete workspace path and the
# exact one-time trust grant the human performs, and states plainly that firstmate
# will not perform that grant itself.
fm_nm_trust_refusal_message() {  # <project-dir> <workspace-path> [<config-file>]
  local dir=$1 ws=$2 cfg=${3:-}
  [ -n "$cfg" ] || cfg=$(fm_nm_trust_config_path)
  cat <<MSG
error: the no-mistakes validation workspace for $dir has not been trusted, so a gate run would fail deep inside the review step - the review agent exits before reading any of the diff and the run still reports "findings: none", which reads like a clean review.
  workspace: $ws
  remedy (one-time, performed by a human): open that directory interactively once with claude and accept the trust dialog, or set projects["$ws"].hasTrustDialogAccepted to true in $cfg
Granting workspace trust is a security decision for the captain, so firstmate refuses this dispatch rather than granting it or working around it.
MSG
}

# fm_nm_trust_refuse_if_untrusted <project-dir>: exit FM_NM_TRUST_EXIT when that
# project's validation workspace is provably untrusted. No-ops (returns 0) when
# the workspace is trusted or the verdict is unknown.
fm_nm_trust_refuse_if_untrusted() {  # <project-dir>
  local dir=$1 ws cfg
  ws=$(fm_nm_trust_workspace_path "$dir") || return 0
  cfg=$(fm_nm_trust_config_path)
  [ "$(fm_nm_trust_status "$ws" "$cfg")" = untrusted ] || return 0
  fm_nm_trust_refusal_message "$dir" "$ws" "$cfg" >&2
  exit "$FM_NM_TRUST_EXIT"
}
