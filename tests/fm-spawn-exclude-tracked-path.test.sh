#!/usr/bin/env bash
# Regression test for exclude_path in bin/fm-spawn.sh.
#
# fm-spawn writes per-lane harness wiring into the worktree (for Claude, that is
# .claude/settings.local.json) and then calls exclude_path to keep the write out
# of git's view, so teardown's dirty check and the no-mistakes clean-tree gate
# stay green. exclude_path implements that by appending the path to
# .git/info/exclude.
#
# info/exclude governs UNTRACKED paths only. If a project commits the file - as
# drone-games-iot did - the exclude entry is inert, the per-lane write shows up
# as a tracked modification, and every crewmate in that repo trips the gate. The
# original bug was that this failed SILENTLY: exclude_path appended the line,
# reported success, and protected nothing.
#
# This test asserts both halves of the contract against the real function text
# lifted out of fm-spawn.sh: an untracked path is still excluded quietly, and a
# tracked path is left alone and warned about with the untracking remedy named.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-exclude-tracked)
REPO="$TMP_ROOT/project"
fm_git_init_commit "$REPO"

# A committed file (the drone-games-iot shape) and an untracked one.
mkdir -p "$REPO/.claude"
printf '{"tracked":true}\n' > "$REPO/.claude/settings.local.json"
git -C "$REPO" add -f .claude/settings.local.json
git -C "$REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -qm 'track settings.local.json'
printf 'token\n' > "$REPO/.fm-turn-end"

# Lift the real exclude_path out of fm-spawn.sh rather than restating it, so
# this test fails if the function is changed or removed.
FN="$TMP_ROOT/exclude_path.sh"
awk '/^exclude_path\(\) \{/,/^\}/' "$ROOT/bin/fm-spawn.sh" > "$FN"
[ -s "$FN" ] || fail "could not lift exclude_path() out of bin/fm-spawn.sh"
assert_grep 'ls-files --error-unmatch' "$FN" \
  'exclude_path no longer checks whether the path is tracked'

# The writes run in the caller's cwd, which fm-spawn never moves to $WT, so a
# relative --git-path answer must be anchored to the worktree. Run every case
# from a directory that is NOT the repo, so an unanchored write would miss.
cd "$TMP_ROOT" || fail "could not leave the repo directory"

EXCL="$REPO/.git/info/exclude"

# --- untracked path: excluded quietly ---------------------------------------
out=$(WT="$REPO"; . "$FN"; exclude_path '.fm-turn-end' 2>&1)
assert_grep '.fm-turn-end' "$EXCL" \
  'an untracked path should still be appended to .git/info/exclude'
assert_not_contains "$out" 'warning:' \
  'excluding an untracked path must stay silent'

# Idempotent: a relaunch must not duplicate the entry.
(WT="$REPO"; . "$FN"; exclude_path '.fm-turn-end' >/dev/null 2>&1)
count=$(grep -cxF '.fm-turn-end' "$EXCL")
[ "$count" = 1 ] || fail "exclude_path duplicated an existing entry (found $count)"

# --- tracked path: refused, and said out loud -------------------------------
out=$(WT="$REPO"; . "$FN"; exclude_path '.claude/settings.local.json' 2>&1)
code=$?
expect_code 0 "$code" 'a tracked path must not make exclude_path fail the spawn'
assert_no_grep '.claude/settings.local.json' "$EXCL" \
  'a tracked path must NOT be written to info/exclude - the entry would be inert'
assert_contains "$out" 'warning:' \
  'a tracked path must warn instead of silently protecting nothing'
assert_contains "$out" 'is tracked in this project' \
  'the warning must say the path is tracked'
assert_contains "$out" 'git rm --cached .claude/settings.local.json' \
  'the warning must name the untracking remedy'

pass 'exclude_path excludes untracked paths and warns instead of pretending on tracked ones'
