#!/usr/bin/env bash
# Behavior tests for the untrusted no-mistakes validation-workspace refusal.
#
# The failure this prevents, verified 19 August 2026 on drone-games-iot: a gate
# run failed at the review step because the validation workspace under
# ~/.no-mistakes/repos/<hash>.git had never been granted Claude Code's
# per-directory trust. The review agent exited before reading any of the diff and
# the run still reported "findings: none", so it was misdiagnosed as quota
# exhaustion and restarted unchanged.
#
# bin/fm-nm-trust-lib.sh detects that state from the project's `no-mistakes`
# remote plus the trust store in ~/.claude.json (or
# $CLAUDE_CONFIG_DIR/.claude.json), and bin/fm-spawn.sh refuses a --mode
# no-mistakes dispatch on it. Every assertion below drives those real functions
# and the real fm-spawn.sh; nothing here restates the condition.
#
# Coverage:
#   - workspace resolution from the real git remote (present, absent, non-local)
#   - the three verdicts, including "unknown" so a machine that cannot answer the
#     question never produces a false refusal
#   - the refusal itself: exit code, the workspace path, the human remedy
#   - the trust store is left byte-identical, so detection never remediates
#   - end-to-end through fm-spawn.sh: refused before any endpoint exists, and no
#     regression for a trusted workspace
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TRUST_LIB="$ROOT/bin/fm-nm-trust-lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"

TMP=$(fm_test_tmproot fm-nm-trust)
fm_git_identity fmtest fmtest@example.invalid

# Fragments of the operator-facing refusal that must survive any rewording.
WS_MSG='has not been trusted'
REMEDY_MSG='hasTrustDialogAccepted'

# --- fixtures ---------------------------------------------------------------

# make_project <dir> <workspace-url> -> a git repo whose `no-mistakes` remote is
# <workspace-url>, exactly as `no-mistakes init` registers it. An empty
# workspace-url leaves the project without that remote.
make_project() {
  local dir=$1 url=${2:-}
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  [ -z "$url" ] || git -C "$dir" remote add no-mistakes "$url"
  printf '%s\n' "$dir"
}

# make_workspace <root> -> a bare repo at <root>/.no-mistakes/repos/<hash>.git,
# reproducing the validation-workspace path shape no-mistakes creates.
make_workspace() {
  local root=$1 ws="$1/.no-mistakes/repos/d4ac26285349.git"
  mkdir -p "$root/.no-mistakes/repos"
  git init -q --bare "$ws"
  printf '%s\n' "$ws"
}

# write_config <file> <workspace> <true|false|absent> -> a Claude Code config
# whose projects map grants, withholds, or omits trust for <workspace>.
write_config() {
  local file=$1 ws=$2 grant=$3
  mkdir -p "$(dirname "$file")"
  case "$grant" in
    true)  printf '{"projects":{"/some/other/dir":{"hasTrustDialogAccepted":true},"%s":{"hasTrustDialogAccepted":true,"allowedTools":[]}}}\n' "$ws" > "$file" ;;
    false) printf '{"projects":{"%s":{"allowedTools":[],"projectOnboardingSeenCount":0}}}\n' "$ws" > "$file" ;;
    absent) printf '{"projects":{"/some/other/dir":{"hasTrustDialogAccepted":true}}}\n' > "$file" ;;
    *) fail "write_config: unknown grant '$grant'" ;;
  esac
}

WS=$(make_workspace "$TMP/home")
PROJ_TRUSTED=$(make_project "$TMP/proj-trusted" "$WS")
PROJ_NO_REMOTE=$(make_project "$TMP/proj-no-remote")
PROJ_SSH_REMOTE=$(make_project "$TMP/proj-ssh" "git@github.com:example/repo.git")

CFG_TRUSTED="$TMP/cfg-trusted.json";  write_config "$CFG_TRUSTED" "$WS" true
CFG_FLAG_OFF="$TMP/cfg-flagoff.json"; write_config "$CFG_FLAG_OFF" "$WS" false
CFG_NO_ENTRY="$TMP/cfg-noentry.json"; write_config "$CFG_NO_ENTRY" "$WS" absent
CFG_MISSING="$TMP/cfg-missing.json"

# --- the real library, driven directly --------------------------------------

# lib_call <args...>: source the real library under set -eu in a subshell
# (proving set -eu safety) and run one of its functions. Echoes combined output;
# the function's exit is the caller's $?.
lib_call() {
  (
    set -eu
    # shellcheck source=/dev/null
    . "$TRUST_LIB"
    "$@"
  ) 2>&1
}

test_workspace_resolution() {
  local out rc

  out=$(lib_call fm_nm_trust_workspace_path "$PROJ_TRUSTED"); rc=$?
  expect_code 0 "$rc" "workspace path: an initialized project must resolve"
  [ "$out" = "$WS" ] || fail "workspace path: expected '$WS', got '$out'"

  lib_call fm_nm_trust_workspace_path "$PROJ_NO_REMOTE" >/dev/null; rc=$?
  expect_code 1 "$rc" "workspace path: a project with no no-mistakes remote must not resolve"

  lib_call fm_nm_trust_workspace_path "$PROJ_SSH_REMOTE" >/dev/null; rc=$?
  expect_code 1 "$rc" "workspace path: a non-local remote URL is not a trustable workspace directory"

  pass "fm_nm_trust_workspace_path: resolves the real no-mistakes remote, and only a local one"
}

test_status_verdicts() {
  local out

  out=$(lib_call fm_nm_trust_status "$WS" "$CFG_TRUSTED")
  [ "$out" = trusted ] || fail "status: granted trust must read trusted, got '$out'"

  out=$(lib_call fm_nm_trust_status "$WS" "$CFG_FLAG_OFF")
  [ "$out" = untrusted ] || fail "status: an entry without the flag must read untrusted, got '$out'"

  out=$(lib_call fm_nm_trust_status "$WS" "$CFG_NO_ENTRY")
  [ "$out" = untrusted ] || fail "status: a missing entry must read untrusted, got '$out'"

  out=$(lib_call fm_nm_trust_status "$WS" "$CFG_MISSING")
  [ "$out" = untrusted ] || fail "status: no config at all means no grant exists, got '$out'"

  pass "fm_nm_trust_status: trusted only when the workspace entry actually grants it"
}

test_status_unknown_without_a_reader() {
  local empty out
  # An existing config that cannot be parsed (no node on PATH) must stay
  # undecided rather than manufacture a refusal.
  empty="$TMP/emptybin"; mkdir -p "$empty"
  out=$(PATH="$empty" lib_call fm_nm_trust_status "$WS" "$CFG_NO_ENTRY")
  [ "$out" = unknown ] || fail "status: an unparseable config must read unknown, got '$out'"
  pass "fm_nm_trust_status: reports unknown when the verdict cannot be established"
}

test_config_dir_override() {
  local dir out
  dir="$TMP/altconfig"
  mkdir -p "$dir"
  write_config "$dir/.claude.json" "$WS" true
  out=$(CLAUDE_CONFIG_DIR="$dir" lib_call fm_nm_trust_config_path)
  [ "$out" = "$dir/.claude.json" ] || fail "config path: CLAUDE_CONFIG_DIR must relocate the trust store, got '$out'"
  out=$(CLAUDE_CONFIG_DIR="$dir" lib_call fm_nm_trust_status "$WS")
  [ "$out" = trusted ] || fail "config path: the relocated store must be the one consulted, got '$out'"
  pass "fm_nm_trust_config_path: honors CLAUDE_CONFIG_DIR"
}

test_refusal_message_and_exit() {
  local out rc
  out=$(HOME="$TMP/nohome" lib_call fm_nm_trust_refuse_if_untrusted "$PROJ_TRUSTED"); rc=$?
  expect_code 4 "$rc" "refusal: an untrusted workspace must exit 4"
  assert_contains "$out" "$WS_MSG" "refusal: must say the workspace is untrusted"
  assert_contains "$out" "$WS" "refusal: must name the concrete workspace path"
  assert_contains "$out" "$REMEDY_MSG" "refusal: must name the exact trust flag"
  assert_contains "$out" "performed by a human" "refusal: must make the one-time human grant explicit"
  pass "fm_nm_trust_refuse_if_untrusted: refuses with the workspace path and the human remedy"
}

test_refusal_noops_when_it_should() {
  local out rc

  out=$(CLAUDE_CONFIG_DIR="$TMP/altconfig" lib_call fm_nm_trust_refuse_if_untrusted "$PROJ_TRUSTED"); rc=$?
  expect_code 0 "$rc" "refusal: a trusted workspace must not refuse"
  [ -z "$out" ] || fail "refusal: a trusted workspace printed output: $out"

  out=$(HOME="$TMP/nohome" lib_call fm_nm_trust_refuse_if_untrusted "$PROJ_NO_REMOTE"); rc=$?
  expect_code 0 "$rc" "refusal: an uninitialized project has no workspace to judge"
  [ -z "$out" ] || fail "refusal: an uninitialized project printed output: $out"

  pass "fm_nm_trust_refuse_if_untrusted: no-op when trusted, and when there is no workspace yet"
}

test_detection_never_remediates() {
  local before after
  before=$(cksum < "$CFG_NO_ENTRY")
  CLAUDE_CONFIG_DIR="$TMP" lib_call fm_nm_trust_refuse_if_untrusted "$PROJ_TRUSTED" >/dev/null || true
  lib_call fm_nm_trust_status "$WS" "$CFG_NO_ENTRY" >/dev/null
  after=$(cksum < "$CFG_NO_ENTRY")
  [ "$before" = "$after" ] || fail "detection rewrote the trust store; granting trust is the captain's decision"
  pass "the trust store is left byte-identical: firstmate detects, never grants"
}

# --- end to end through the real fm-spawn.sh --------------------------------

# A fake tmux/treehouse so fm-spawn resolves the crew worktree from a controlled
# pane path and completes without a live terminal (same shape as
# tests/fm-gate-refuse.test.sh).
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# run_spawn <home> <id> <proj> <pane> <fakebin> [ASSIGN...] -> combined output
run_spawn() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5; shift 5
  mkdir -p "$home/data/$id"
  printf 'Delivery contract: mode=no-mistakes\n' > "$home/data/$id/brief.md"
  ( env "FM_ROOT_OVERRIDE=" "FM_HOME=$home" \
      "FM_STATE_OVERRIDE=$home/state" "FM_DATA_OVERRIDE=$home/data" \
      "FM_PROJECTS_OVERRIDE=$home/projects" "FM_CONFIG_OVERRIDE=$home/config" \
      "FM_SPAWN_NO_GUARD=1" "FM_FAKE_PANE_PATH=$pane" "TMUX=fake,1,0" \
      "PATH=$fakebin:$PATH" "$@" \
      "$SPAWN" "$id" "$proj" codex --mode no-mistakes --yolo off ) 2>&1
}

test_spawn_refuses_untrusted_workspace() {
  local home proj wt fakebin out rc
  home="$TMP/spawn-home"; mkdir -p "$home/data"
  proj=$(make_project "$TMP/spawn-proj" "$WS")
  fm_git_add_origin "$proj" "$TMP/spawn-origin.git"
  fakebin=$(make_spawn_fakebin "$TMP/spawn-fake")
  wt="$TMP/spawn-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1

  # Untrusted: the store has no grant for this workspace.
  out=$(run_spawn "$home" nm-untrusted "$proj" "$wt" "$fakebin" "CLAUDE_CONFIG_DIR=$TMP/cfg-none"); rc=$?
  expect_code 4 "$rc" "spawn: a no-mistakes dispatch onto an untrusted workspace must be refused"
  assert_contains "$out" "$WS_MSG" "spawn: refusal must explain the untrusted workspace"
  assert_contains "$out" "$WS" "spawn: refusal must name the workspace path"
  assert_absent "$home/state/nm-untrusted.meta" "spawn: a refused dispatch must not record the task"

  # Trusted: the same project and workspace, with the grant present.
  out=$(run_spawn "$home" nm-trusted "$proj" "$wt" "$fakebin" "CLAUDE_CONFIG_DIR=$TMP/altconfig"); rc=$?
  expect_code 0 "$rc" "spawn: a trusted workspace must still dispatch"
  assert_not_contains "$out" "$WS_MSG" "spawn: a trusted dispatch must not print the refusal"
  assert_present "$home/state/nm-trusted.meta" "spawn: a trusted dispatch should record the task"

  pass "fm-spawn.sh: refuses a no-mistakes dispatch onto an untrusted workspace, before any endpoint exists"
}

test_workspace_resolution
test_status_verdicts
test_status_unknown_without_a_reader
test_config_dir_override
test_refusal_message_and_exit
test_refusal_noops_when_it_should
test_detection_never_remediates
test_spawn_refuses_untrusted_workspace
