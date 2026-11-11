#!/usr/bin/env bash

# Describe every split skill's update within one total time budget (#15), so slow upstreams cannot
# use up the update job's time limit before any per-skill pull request opens.
#
# usage: describe-skill-updates.sh <describer> <out-dir> < <manifest>
#
# <manifest> has one `<slug><TAB><path>` line per split skill. For each line, in order, the describer
# (describe-skill-update.sh) writes <out-dir>/<slug>.md. A skill described before the budget is spent
# keeps its full description. A describer that fails, or that is stopped because the budget ran out
# while it was working, leaves the visible warning body instead, and so does every skill reached
# after the budget is spent: those are not described at all. The run always succeeds once every
# skill has a body, so the job goes on to open every pull request.
#
# The budget: the update job has 60 minutes (`timeout-minutes: 60`). The steps before this one took
# about 30 seconds in a real run, but `gh skill update` has no bound of its own, so they keep the
# first half of the hour. One describer run can take up to three bounded fetches of 300 seconds each
# plus lookups without a bound, so a budget of 30 minutes still fits two worst-case skills, and a
# typical skill takes seconds. A describer still running at the deadline is stopped (then killed
# after a grace of $kill_grace_seconds seconds), so the step ends within the budget plus that grace,
# leaving the upload and the other half of the hour untouched.
#
# DESCRIBE_SKILL_UPDATES_BUDGET_SECONDS replaces the budget, for tests only.

set -euo pipefail

budget_seconds=1800
kill_grace_seconds=10

[[ $# -eq 2 ]] || {
  echo "usage: describe-skill-updates.sh <describer> <out-dir> < <manifest>" >&2
  exit 2
}
describer="$1"
out_dir="$2"
budget="${DESCRIBE_SKILL_UPDATES_BUDGET_SECONDS:-$budget_seconds}"
[[ "$budget" =~ ^[0-9]+$ ]] || {
  echo "describe-skill-updates: the budget must be a whole number of seconds, got '$budget'" >&2
  exit 2
}

logs="$(mktemp -d)"
trap 'rm -rf "$logs"' EXIT

now() { date +%s; }

# bounded <seconds> <out> <err> <command...>: runs the command in its own process group with stdout
# to <out> and stderr to <err>, and stops the whole group when it outlives <seconds>. A grandchild
# that moved to a group of its own (the describer's own `timeout` around a fetch) is not reached, but
# it has its own bound, and the files keep it from holding this step's output open.
bounded() {
  local seconds="$1" out="$2" err="$3" pid watcher rc=0
  shift 3
  set -m
  "$@" >"$out" 2>"$err" </dev/null &
  pid=$!
  (
    sleep "$seconds"
    kill -TERM -- "-$pid" 2>/dev/null || exit 0
    sleep "$kill_grace_seconds"
    kill -KILL -- "-$pid" 2>/dev/null || true
  ) >/dev/null 2>&1 </dev/null &
  watcher=$!
  set +m
  wait "$pid" || rc=$?
  # Whatever is left in the group once the describer has exited, such as a child that ignored the
  # stop, is a straggler: it is killed now, before the watcher that would have escalated goes.
  kill -KILL -- "-$pid" 2>/dev/null || true
  kill -TERM -- "-$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return "$rc"
}

fallback() { # <body>
  {
    echo "> [!WARNING]"
    echo "> - The upstream range, licence and repository state of this update could not be described; review them by hand."
    echo
    echo "Automated update of this agent skill to its latest version."
    echo
    echo "Each changed skill gets its own pull request, so one blocked update does not hold back the others."
  } >"$1"
}

deadline=$(($(now) + budget))
n=0
while IFS=$'\t' read -r slug path; do
  body="$out_dir/${slug}.md"
  n=$((n + 1))
  remaining=$((deadline - $(now)))
  if ((remaining <= 0)); then
    echo "::warning::The time budget for describing updates is spent, so ${path} was not described; its PR says so."
    fallback "$body"
    continue
  fi
  rc=0
  bounded "$remaining" "$body" "$logs/$n.err" bash "$describer" "$path" || rc=$?
  cat "$logs/$n.err" >&2
  if ((rc != 0)); then
    echo "::warning::Could not describe the update of ${path}; its PR says so."
    fallback "$body"
  fi
done
