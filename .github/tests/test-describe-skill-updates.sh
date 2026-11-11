#!/usr/bin/env bash
# Contract test for the budgeted describing loop (#15): every split skill gets a body, a skill
# described before the time budget is spent keeps its description, and once the budget is spent every
# remaining skill gets the visible warning body while the step still succeeds, so every per-skill
# pull request opens. A describer that fails costs only its own skill, and one still running at the
# deadline is stopped together with its children.
#
# Time is a fake clock (a `date` stub that the stub describer moves forward), so no case waits on a
# real budget; only the deadline case waits one real second.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
loop="$repo_root/.github/scripts/describe-skill-updates.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ── the fake clock and the stub describer ────────────────────────────────────────────────────
mkdir -p "$work/bin"
real_date="$(command -v date)"
cat >"$work/bin/date" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == "+%s" ]]; then cat "\$CLOCK"; else exec "$real_date" "\$@"; fi
EOF
chmod +x "$work/bin/date"
export PATH="$work/bin:$PATH" CLOCK="$work/clock"

# The stub describes <path> as one line. STUB_STEP moves the clock forward per call, STUB_FAIL names a
# path it fails for, and STUB_HANG a path it hangs on with a child, recording the child's pid.
cat >"$work/describer.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"$STUB_CALLS"
echo "$(($(cat "$CLOCK") + ${STUB_STEP:-0}))" >"$CLOCK"
if [[ "$1" == "${STUB_FAIL:-}" ]]; then echo "partial"; exit 3; fi
if [[ "$1" == "${STUB_HANG:-}" ]]; then
  echo "partial"
  sleep 60 &
  echo "$!" >"$STUB_CHILD"
  wait
fi
echo "described $1"
EOF
export STUB_CALLS="$work/calls" STUB_CHILD="$work/child"

fallback_body='> [!WARNING]
> - The upstream range, licence and repository state of this update could not be described; review them by hand.

Automated update of this agent skill to its latest version.

Each changed skill gets its own pull request, so one blocked update does not hold back the others.'

out="$work/out"
run_loop() { # <budget>: runs the loop over skills a, b and c; stdout and stderr go to $work/log
  rm -rf "$out" "$STUB_CALLS"
  mkdir -p "$out"
  : >"$STUB_CALLS"
  echo 1000 >"$CLOCK"
  printf 'a\tskills/a\nb\tskills/b\nc\tskills/c\n' >"$work/manifest.tsv"
  DESCRIBE_SKILL_UPDATES_BUDGET_SECONDS="$1" bash "$loop" "$work/describer.sh" "$out" \
    <"$work/manifest.tsv" >"$work/log" 2>&1 || fail "the loop must succeed (budget $1):"$'\n'"$(cat "$work/log")"
}
described() { [[ "$(cat "$out/$1.md")" == "described skills/$1" ]] || fail "$2: skill $1 must keep its description, got:"$'\n'"$(cat "$out/$1.md")"; }
fell_back() { [[ "$(cat "$out/$1.md")" == "$fallback_body" ]] || fail "$2: skill $1 must get the warning body, got:"$'\n'"$(cat "$out/$1.md")"; }
calls() { [[ "$(tr '\n' ' ' <"$STUB_CALLS")" == "$1" ]] || fail "$2: expected describer calls '$1', got '$(tr '\n' ' ' <"$STUB_CALLS")'"; }

# ── every skill inside the budget ────────────────────────────────────────────────────────────
STUB_STEP=10 run_loop 100
for s in a b c; do described "$s" "inside the budget"; done
calls "skills/a skills/b skills/c " "inside the budget"
grep -q '::warning::' "$work/log" && fail "no warning is due inside the budget:"$'\n'"$(cat "$work/log")"
echo "ok: every skill described inside the budget keeps its description"

# ── the budget is spent by the first skill ───────────────────────────────────────────────────
STUB_STEP=100 run_loop 100
described a "the first skill, described before the budget ran out"
fell_back b "the budget spent"
fell_back c "the budget spent"
calls "skills/a " "the budget spent"
[[ "$(grep -c 'time budget for describing updates is spent' "$work/log")" == 2 ]] ||
  fail "each skill left undescribed must be named in a warning:"$'\n'"$(cat "$work/log")"
echo "ok: once the budget is spent, the remaining skills get the warning body and the step succeeds"

# ── a describer that fails costs only its own skill ──────────────────────────────────────────
STUB_STEP=10 STUB_FAIL=skills/b run_loop 100
described a "before a failing describer"
fell_back b "a failing describer"
described c "after a failing describer"
calls "skills/a skills/b skills/c " "a failing describer"
grep -qF '::warning::Could not describe the update of skills/b; its PR says so.' "$work/log" ||
  fail "a failing describer must be named in a warning:"$'\n'"$(cat "$work/log")"
echo "ok: a describer that fails for one skill leaves the others their chance"

# ── a budget of zero ─────────────────────────────────────────────────────────────────────────
run_loop 0
for s in a b c; do fell_back "$s" "a budget of zero"; done
calls "" "a budget of zero"
echo "ok: a budget of zero describes nothing and still gives every skill its body"

# ── a describer still running at the deadline is stopped with its children ──────────────────
# Skill a uses 99 of the 100 fake seconds, so skill b, which hangs, has one real second left. The
# stop must come at that second, not at the whole budget and not after the kill grace.
start="$("$real_date" +%s)"
STUB_STEP=99 STUB_HANG=skills/b run_loop 100
elapsed=$(($("$real_date" +%s) - start))
((elapsed < 8)) || fail "the loop must stop a hanging describer when the budget runs out, it took ${elapsed}s"
described a "before the hanging describer"
fell_back b "a describer stopped at the deadline"
fell_back c "after the budget ran out during a describer"
calls "skills/a skills/b " "a describer stopped at the deadline"
child="$(cat "$STUB_CHILD")"
sleep 1
if kill -0 "$child" 2>/dev/null; then
  kill "$child" 2>/dev/null || true
  fail "the stopped describer's child must be stopped with it"
fi
echo "ok: a describer still running at the deadline is stopped with its children and falls back"

# ── usage ────────────────────────────────────────────────────────────────────────────────────
if DESCRIBE_SKILL_UPDATES_BUDGET_SECONDS=soon bash "$loop" "$work/describer.sh" "$out" </dev/null 2>/dev/null; then
  fail "a budget that is not a whole number of seconds must be refused"
fi
if bash "$loop" "$work/describer.sh" </dev/null 2>/dev/null; then fail "a missing argument must be refused"; fi
grep -qE '^budget_seconds=[0-9]+$' "$loop" || fail "the budget must be one named value in the loop"
[[ "$(grep -c 'budget_seconds' "$loop")" == 2 ]] || fail "the budget is set in one place and read in one"
echo "ok: the budget is one named whole number of seconds"

echo "PASS: the describing loop keeps to its time budget and always leaves every skill a body"
