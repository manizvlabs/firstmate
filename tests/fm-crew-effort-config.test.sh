#!/usr/bin/env bash
# Tests for the standing crewmate model/effort pins, config/crew-model and
# config/crew-effort.
#
# Why they exist: before this, --effort was settable per-spawn only. Omit it and
# the crewmate inherits whatever reasoning level the primary session is on -
# invisible at the call site, and expensive, because the primary tends to sit at
# a high level for its own supervision work. A standing pin makes the fleet's
# token profile a property of the home instead of a property of whoever typed
# the last spawn command.
#
# Two halves are under test:
#   A) Resolution. fm-harness.sh crew-model / crew-effort read one value from
#      config/crew-model and config/crew-effort, trimming whitespace, and print
#      nothing when the file is absent or blank. Absent files must stay silent
#      and empty: that is the whole backward-compatibility contract, since an
#      empty value is what makes fm-spawn leave MODEL/EFFORT alone.
#   B) Precedence, asserted against the real fm-spawn.sh source. The pin applies
#      to crewmate and scout spawns only, is skipped for --secondmate (which has
#      its own config/secondmate-harness tokens), is skipped when an explicit
#      harness or raw launch command was given, yields to explicit
#      --model/--effort flags, and validates the effort value rather than
#      passing an unrecognised level through to the launch flag.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-crew-effort-config)
CFG="$TMP_ROOT/config"
mkdir -p "$CFG"

harness() { FM_CONFIG_OVERRIDE="$CFG" "$ROOT/bin/fm-harness.sh" "$1"; }

# --- A) resolution ----------------------------------------------------------

# Absent files resolve to empty, which is what leaves fm-spawn's defaults alone.
[ -z "$(harness crew-effort)" ] || fail "absent config/crew-effort must resolve empty"
[ -z "$(harness crew-model)" ] || fail "absent config/crew-model must resolve empty"

# A blank or whitespace-only file is the same as an absent one, so a half-edited
# pin degrades to "unset" rather than to a garbage launch flag.
printf '\n  \n' > "$CFG/crew-effort"
[ -z "$(harness crew-effort)" ] || fail "whitespace-only config/crew-effort must resolve empty"

# The ordinary case, including the trailing newline every editor writes.
printf 'medium\n' > "$CFG/crew-effort"
assert_contains "$(harness crew-effort)" medium 'config/crew-effort should resolve to its value'
[ "$(harness crew-effort)" = medium ] || fail "config/crew-effort must resolve exactly, unpadded"

printf '  claude-sonnet-5  \n' > "$CFG/crew-model"
[ "$(harness crew-model)" = claude-sonnet-5 ] || fail "config/crew-model must be whitespace-trimmed"

# The pins are separate files from config/crew-harness, which stays a bare
# adapter name; setting one must not perturb the other.
printf 'claude\n' > "$CFG/crew-harness"
[ "$(harness crew)" = claude ] || fail "config/crew-harness must still resolve independently"
[ "$(harness crew-effort)" = medium ] || fail "config/crew-harness must not shadow config/crew-effort"

pass 'config/crew-model and config/crew-effort resolve, trim, and stay independent'

# --- B) precedence, against the real fm-spawn.sh -----------------------------

# Lift the guard rather than restating it, so this fails if the block is
# reworded, moved out from under its condition, or dropped.
SPAWN="$ROOT/bin/fm-spawn.sh"
BLOCK="$TMP_ROOT/crew-pin-block.sh"
awk '/^if \[ "\$KIND" != secondmate \] && \[ -z "\$ARG3" \]; then$/,/^fi$/' "$SPAWN" > "$BLOCK"
[ -s "$BLOCK" ] || fail 'could not lift the crew model/effort pin block out of bin/fm-spawn.sh'

assert_grep 'fm-harness.sh" crew-effort' "$BLOCK" \
  'the pin block must read config/crew-effort through fm-harness.sh'
assert_grep 'fm-harness.sh" crew-model' "$BLOCK" \
  'the pin block must read config/crew-model through fm-harness.sh'
assert_grep '"$EFFORT_SET" -eq 0' "$BLOCK" \
  'an explicit --effort must still win over config/crew-effort'
assert_grep '"$MODEL_SET" -eq 0' "$BLOCK" \
  'an explicit --model must still win over config/crew-model'
assert_grep 'low|medium|high|xhigh|max' "$BLOCK" \
  'config/crew-effort must be validated against the accepted levels'
assert_grep 'is not one of low, medium, high, xhigh, max; ignoring' "$BLOCK" \
  'an unrecognised config/crew-effort value must warn and be ignored, not spawn on it'

# The block's own condition is the secondmate/explicit-harness opt-out. Both
# guards live in the awk anchor above, so assert them on the lifted text too.
assert_grep '"$KIND" != secondmate' "$BLOCK" \
  'the crew pin must not apply to a --secondmate spawn'
assert_grep '-z "$ARG3"' "$BLOCK" \
  'an explicit harness or raw launch command must opt out of the crew pin'

pass 'crew model/effort pins apply to crew and scout spawns only, under explicit-flag precedence'
