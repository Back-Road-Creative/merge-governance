#!/usr/bin/env bash
# Offline hermetic harness for the two privileged merge tools — bin/merge-batch.sh
# (t*) AND bin/merge-approved.sh's --wait mode (w*).
# No network, no real gh/git, no sudo: everything goes through the tools'
# injection seams (GH_BIN / GIT_BIN / MERGE_APPROVED_BIN /
# GH_MERGE_APPROVED_TEST_MODE) to fakes in a temp dir. The fake gate records
# its argv so flag forwarding is assertable; the fake git records fetch calls and
# can be told to fail; the fake gh for the gate serves a DIFFERENT fixture per
# poll so a CI transition (pending → green / red / force-push) can be replayed.
#
# Waiting is made fast, not skipped: GH_MERGE_POLL_SECS drops the poll interval
# to 0.2s and GH_MERGE_WAIT_SECS replaces the whole minute-granularity budget
# with a couple of seconds, so the real loop runs — nothing is stubbed out.
#
# Run:  bash test-merge-batch.sh    → exits 0 only if every test passes.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/../bin/merge-batch.sh"
APPROVED="$HERE/../bin/merge-approved.sh"
SLUG="example-org/example-repo"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"
POLL=0.2

# ── fakes ─────────────────────────────────────────────────────────────────
cat >"$BIN/fake-gh" <<'FAKE'
#!/usr/bin/env bash
# Canned gh for the BATCH tool: answers `pr view` / `pr checks` from files in
# $FAKE_DIR. `pr checks` supports per-poll fixtures: pr<N>.checks.<k> is served
# on the k-th call for that PR (k from 0), falling back to the static
# pr<N>.checks — that is how a PR transitions from pending to green mid-wait.
# Every invocation is appended to gh.calls so "was this re-read on each poll?"
# is assertable.
printf '%s\n' "$*" >>"$FAKE_DIR/gh.calls"
args=("$@")
json=""
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[$i]}" == "--json" ]] && json="${args[$((i + 1))]}"
done
if [[ "${args[0]:-}" == "pr" && "${args[1]:-}" == "view" ]]; then
  pr="${args[2]}"
  case "$json" in
    state)            cat "$FAKE_DIR/pr$pr.state" 2>/dev/null || exit 1 ;;
    mergeStateStatus) cat "$FAKE_DIR/pr$pr.mss"   2>/dev/null || echo CLEAN ;;
    baseRefName)      cat "$FAKE_DIR/pr$pr.base"  2>/dev/null || echo master ;;
  esac
elif [[ "${args[0]:-}" == "pr" && "${args[1]:-}" == "checks" ]]; then
  pr="${args[2]}"
  k="$(cat "$FAKE_DIR/pr$pr.checkn" 2>/dev/null || echo 0)"
  echo $((k + 1)) >"$FAKE_DIR/pr$pr.checkn"
  if [[ -e "$FAKE_DIR/pr$pr.checks.$k" ]]; then
    cat "$FAKE_DIR/pr$pr.checks.$k"
  else
    cat "$FAKE_DIR/pr$pr.checks" 2>/dev/null || true
  fi
fi
exit 0
FAKE

cat >"$BIN/fake-gh-approved" <<'FAKE'
#!/usr/bin/env bash
# Canned gh for the WRAPPER tests. Fixtures are per GATE EVALUATION: the poll
# index advances once per pass, on the `--json statusCheckRollup` call the
# wrapper makes exactly once per evaluation. Files in $FAKE_DIR:
#   rollup.<n>  | rollup.default   statusCheckRollup JSON
#   head.<n>    | head.default     head SHA
#   runs.<sha>  | runs.<n> | runs.default   `gh run list --commit <sha>` JSON
#   compare.<n> | compare.default  base...head compare JSON
#   basecmp.<n> | basecmp.default  mergebase...base compare JSON
#   prfiles.<n> | prfiles.default  PR filenames, one per line
# Every invocation is appended to gh.calls; `pr merge` also lands in merge.calls
# (whose mere existence means "a merge happened").
printf '%s\n' "$*" >>"$FAKE_DIR/gh.calls"

serve() { # <fixture-basename>
  local n; n="$(cat "$FAKE_DIR/cur" 2>/dev/null || echo 0)"
  if [[ -e "$FAKE_DIR/$1.$n" ]]; then
    cat "$FAKE_DIR/$1.$n"
  elif [[ -e "$FAKE_DIR/$1.default" ]]; then
    cat "$FAKE_DIR/$1.default"
  fi
}

args=("$@")
json=""; commit=""
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[$i]}" == "--json"   ]] && json="${args[$((i + 1))]}"
  [[ "${args[$i]}" == "--commit" ]] && commit="${args[$((i + 1))]}"
done

case "${args[0]:-}:${args[1]:-}" in
  pr:view)
    case "$json" in
      baseRefName) echo master ;;
      url)         echo "https://github.com/Fake/Repo/pull/${args[2]}" ;;
      headRefOid)  serve head ;;
      statusCheckRollup)
        n="$(cat "$FAKE_DIR/step" 2>/dev/null || echo 0)"
        echo "$n" >"$FAKE_DIR/cur"
        echo $((n + 1)) >"$FAKE_DIR/step"
        serve rollup ;;
      *) echo "  PR #${args[2]}: fixture" ;;
    esac ;;
  pr:merge)
    printf '%s\n' "$*" >>"$FAKE_DIR/merge.calls"
    # Simulate a merge-queue repo: real `gh` refuses --delete-branch outright
    # and merges NOTHING. Only the retry without the flag succeeds.
    if [[ -e "$FAKE_DIR/queue_repo" && "$*" == *"--delete-branch"* ]]; then
      echo "X Cannot use \`-d\` or \`--delete-branch\` when merge queue enabled" >&2
      exit 1
    fi
    # Queue enabled but allow_auto_merge off: the retry ALSO fails, because a
    # queue is entered through the auto-merge API.
    if [[ -e "$FAKE_DIR/no_automerge" ]]; then
      echo "GraphQL: Auto merge is not allowed for this repository (enablePullRequestAutoMerge)" >&2
      exit 1
    fi ;;
  run:list)
    if [[ -n "$commit" && -e "$FAKE_DIR/runs.$commit" ]]; then
      cat "$FAKE_DIR/runs.$commit"
    else
      serve runs
    fi ;;
  api:*)
    case "${args[1]}" in
      */compare/master...*) serve compare ;;
      */compare/*...master) serve basecmp ;;
      */pulls/*/files)      serve prfiles ;;
      repos/*)
        # delete_branch_on_merge probe: true unless the fixture says otherwise.
        [[ -e "$FAKE_DIR/dbom_off" ]] && echo false || echo true ;;
    esac ;;
esac
exit 0
FAKE

cat >"$BIN/fake-git" <<'FAKE'
#!/usr/bin/env bash
# Records every invocation; fails when $FAKE_DIR/git.fail exists.
printf '%s\n' "$*" >>"$FAKE_DIR/git.calls"
[[ -e "$FAKE_DIR/git.fail" ]] && exit 128
exit 0
FAKE

cat >"$BIN/fake-wrapper" <<'FAKE'
#!/usr/bin/env bash
# Stand-in for the merge wrapper: records argv, then flips the PR to MERGED
# like the real wrapper's successful merge would.
printf '%s\n' "$*" >>"$FAKE_DIR/wrapper.calls"
if [[ "${1:-}" =~ /pull/([0-9]+) ]]; then
  echo MERGED >"$FAKE_DIR/pr${BASH_REMATCH[1]}.state"
fi
exit 0
FAKE
chmod +x "$BIN"/fake-*

# ── plumbing ──────────────────────────────────────────────────────────────
pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

new_case() {
  export FAKE_DIR="$TMP/$1"
  mkdir -p "$FAKE_DIR"
  echo "── $1"
}

# green_pr <num>: seed an OPEN, CLEAN, all-checks-green PR.
green_pr() {
  echo OPEN  >"$FAKE_DIR/pr$1.state"
  echo CLEAN >"$FAKE_DIR/pr$1.mss"
  printf 'build\tpass\thttps://ci/x\n' >"$FAKE_DIR/pr$1.checks"
  echo master >"$FAKE_DIR/pr$1.base"
}

# pending_checks <num> <n-polls>: the PR reads PENDING for its first <n-polls>
# `pr checks` calls, then falls back to whatever pr<num>.checks says.
pending_checks() {
  local n
  for ((n = 0; n < $2; n++)); do
    printf 'suite\tpending\thttps://ci/x\n' >"$FAKE_DIR/pr$1.checks.$n"
  done
}

run_tool() {
  GH_BIN="$BIN/fake-gh" GIT_BIN="$BIN/fake-git" \
    MERGE_APPROVED_BIN="$BIN/fake-wrapper" GH_MERGE_POLL_SECS="$POLL" \
    bash "$TOOL" "$@" >"$FAKE_DIR/out" 2>"$FAKE_DIR/err" </dev/null
  echo $? >"$FAKE_DIR/rc"
}

run_tool_stdin() { # <stdin-file> <args…>
  local f="$1"; shift
  GH_BIN="$BIN/fake-gh" GIT_BIN="$BIN/fake-git" \
    MERGE_APPROVED_BIN="$BIN/fake-wrapper" GH_MERGE_POLL_SECS="$POLL" \
    bash "$TOOL" "$@" >"$FAKE_DIR/out" 2>"$FAKE_DIR/err" <"$f"
  echo $? >"$FAKE_DIR/rc"
}

# The wrapper runs from $FAKE_DIR (not a git repo) so its post-merge local
# resync is a no-op regardless of where the harness was started.
run_approved() {
  ( cd "$FAKE_DIR" && GH_MERGE_APPROVED_TEST_MODE=1 GH_BIN="$BIN/fake-gh-approved" \
      GH_MERGE_POLL_SECS="$POLL" bash "$APPROVED" "$@" ) \
      >"$FAKE_DIR/out" 2>"$FAKE_DIR/err" </dev/null
  echo $? >"$FAKE_DIR/rc"
}

rollup_pending() { printf '{"statusCheckRollup":[{"__typename":"CheckRun","name":"CI","status":"IN_PROGRESS","conclusion":null}]}\n'; }
rollup_green()   { printf '{"statusCheckRollup":[{"__typename":"CheckRun","name":"CI","status":"COMPLETED","conclusion":"SUCCESS"}]}\n'; }
rollup_red()     { printf '{"statusCheckRollup":[{"__typename":"CheckRun","name":"CI","status":"COMPLETED","conclusion":"FAILURE"}]}\n'; }

# Baseline wrapper fixtures: green checks, green run, base not behind. Tests
# override the numbered variants to script a transition.
seed_approved() {
  rollup_green >"$FAKE_DIR/rollup.default"
  printf '[{"status":"completed","conclusion":"success","name":"CI"}]\n' >"$FAKE_DIR/runs.default"
  printf 'aaaaaaaaaaaa\n' >"$FAKE_DIR/head.default"
  printf '{"behind_by":0,"merge_base_commit":{"sha":"mb0"}}\n' >"$FAKE_DIR/compare.default"
  printf '{"files":[]}\n' >"$FAKE_DIR/basecmp.default"
  printf 'x.py\n' >"$FAKE_DIR/prfiles.default"
}

expect_rc()  { local got; got="$(cat "$FAKE_DIR/rc")"; [[ "$got" == "$1" ]] && ok "$2" || bad "$2 (rc=$got, want $1)"; }
expect_out() { grep -qF -- "$1" "$FAKE_DIR/out" && ok "$2" || bad "$2 (no '$1' in stdout)"; }
expect_err() { grep -qF -- "$1" "$FAKE_DIR/err" && ok "$2" || bad "$2 (no '$1' in stderr)"; }
refute_out() { grep -qF -- "$1" "$FAKE_DIR/out" && bad "$2 ('$1' present in stdout)" || ok "$2"; }
refute_err() { grep -qF -- "$1" "$FAKE_DIR/err" && bad "$2 ('$1' present in stderr)" || ok "$2"; }
expect_gh()  { grep -qF -- "$1" "$FAKE_DIR/gh.calls" && ok "$2" || bad "$2 (no '$1' in gh.calls)"; }
expect_merged()    { [[ -e "$FAKE_DIR/merge.calls" ]] && ok "$1" || bad "$1 (no gh pr merge call)"; }
refute_merged()    { [[ -e "$FAKE_DIR/merge.calls" ]] && bad "$1 (a merge was issued!)" || ok "$1"; }
wrapper_lines() { if [[ -e "$FAKE_DIR/wrapper.calls" ]]; then wc -l <"$FAKE_DIR/wrapper.calls"; else echo 0; fi; }

# ── batch tool: pre-existing behaviour (must stay green) ──────────────────

new_case t1-yes-forwarded
green_pr 101
run_tool "$SLUG" 101 --yes
expect_rc 0 "single green PR merges, exit 0"
grep -qF -- "--yes" "$FAKE_DIR/wrapper.calls" \
  && ok "--yes forwarded to the wrapper" || bad "--yes forwarded to the wrapper"
grep -qF -- "pull/101 --repo example-org/example-repo" "$FAKE_DIR/wrapper.calls" \
  && ok "wrapper got URL + --repo" || bad "wrapper got URL + --repo"

new_case t2-yes-after-positionals
green_pr 111; green_pr 112
export GH_MERGE_BATCH_REPO_MAP="other/repo=/nope $SLUG=$FAKE_DIR/checkout"
run_tool "$SLUG" 111 112 --yes
unset GH_MERGE_BATCH_REPO_MAP
expect_rc 0 "trailing --yes after positional PRs accepted"
[[ "$(wrapper_lines)" -eq 2 ]] && ok "wrapper called twice" || bad "wrapper called twice ($(wrapper_lines))"
[[ "$(grep -c -- '--yes' "$FAKE_DIR/wrapper.calls")" -eq 2 ]] \
  && ok "--yes on both wrapper calls" || bad "--yes on both wrapper calls"
expect_out "MERGED: 111 112" "both PRs reported merged"
grep -qF -- "-C $FAKE_DIR/checkout fetch origin master --quiet" "$FAKE_DIR/git.calls" \
  && ok "slug mapped by GH_MERGE_BATCH_REPO_MAP refetches its own checkout" \
  || bad "slug mapped by GH_MERGE_BATCH_REPO_MAP refetches its own checkout"

new_case t2b-repo-map-file
green_pr 121
mkdir -p "$FAKE_DIR/checkout"
cat >"$FAKE_DIR/repo-map" <<EOF
# comment line, then a blank one

other/repo   /nope
$SLUG   $FAKE_DIR/checkout
EOF
export GH_MERGE_BATCH_REPO_MAP_FILE="$FAKE_DIR/repo-map"
run_tool "$SLUG" 121 --yes
unset GH_MERGE_BATCH_REPO_MAP_FILE
expect_rc 0 "map FILE form merges, exit 0"
grep -qF -- "-C $FAKE_DIR/checkout fetch origin master --quiet" "$FAKE_DIR/git.calls" \
  && ok "map file resolves the checkout dir (comments and blanks ignored)" \
  || bad "map file resolves the checkout dir (comments and blanks ignored)"
refute_err "no repo-dir mapping" "a mapped slug does not WARN"

new_case t3-stop-on-pending
green_pr 201; green_pr 202; green_pr 203
printf 'suite\tpending\thttps://ci/x\n' >"$FAKE_DIR/pr202.checks"
run_tool "$SLUG" 201 202 203 --yes
expect_rc 1 "pending checks stop the batch, exit 1"
expect_out "STOPPED-AT: 202 (checks PENDING)" "stop reason names the PR + PENDING"
expect_out "REMAINING: 202 203" "remaining lists stopped PR + everything after"
[[ "$(wrapper_lines)" -eq 1 ]] \
  && ok "wrapper never called for the pending or later PR" \
  || bad "wrapper never called for the pending or later PR ($(wrapper_lines))"

new_case t4-already-merged-skip
green_pr 301; green_pr 302
echo MERGED >"$FAKE_DIR/pr301.state"
run_tool "$SLUG" 301 302 --yes
expect_rc 0 "already-MERGED PR is success, batch continues"
expect_out "skip  #301 (already MERGED)" "skip line printed"
expect_out "MERGED: 301 302" "both counted as merged"
[[ "$(wrapper_lines)" -eq 1 ]] && grep -qF -- "pull/302" "$FAKE_DIR/wrapper.calls" \
  && ok "wrapper called only for the open PR" || bad "wrapper called only for the open PR"

new_case t5-unmapped-slug
green_pr 401
run_tool Somewhere/else 401 --yes
expect_rc 0 "unmapped slug still merges, exit 0"
expect_err "WARN: no repo-dir mapping for slug 'Somewhere/else'" "loud WARN on stderr"
[[ ! -e "$FAKE_DIR/git.calls" ]] \
  && ok "refetch skipped (no git call)" || bad "refetch skipped (no git call)"
[[ "$(wrapper_lines)" -eq 1 ]] && ok "merge still went through" || bad "merge still went through"

new_case t6-refetch-fail-continues
green_pr 501; green_pr 502
: >"$FAKE_DIR/git.fail"
export GH_MERGE_BATCH_REPO_DIR="$FAKE_DIR/somerepo"
run_tool "$SLUG" 501 502 --yes
unset GH_MERGE_BATCH_REPO_DIR
expect_rc 0 "refetch failure does not stop the batch"
expect_err "WARN: base refetch failed" "refetch failure surfaces as WARN"
expect_out "MERGED: 501 502" "both PRs merged despite refetch failure"
[[ "$(grep -c "somerepo fetch origin master" "$FAKE_DIR/git.calls")" -eq 2 ]] \
  && ok "env-override repo dir used for both refetch attempts" \
  || bad "env-override repo dir used for both refetch attempts"

new_case t7-unknown-flag
run_tool --bogus example-org/example-repo 601
expect_rc 2 "unknown flag exits 2"
expect_err "unknown option: --bogus" "unknown flag named on stderr"

new_case t8-from-ready
green_pr 701; green_pr 702
cat >"$FAKE_DIR/stdin" <<'EOF'
  sudo merge-approved https://github.com/example-org/example-repo/pull/701 --repo example-org/example-repo
some unrelated dashboard noise
  sudo merge-approved https://github.com/example-org/example-repo/pull/702 --repo example-org/example-repo
EOF
run_tool_stdin "$FAKE_DIR/stdin" --from-ready example-org/example-repo --yes
expect_rc 0 "--from-ready parses stdin and merges"
expect_out "MERGED: 701 702" "both stdin PRs merged in order"
[[ "$(sed -n 1p "$FAKE_DIR/wrapper.calls")" == *pull/701* ]] \
  && ok "stdin order preserved (701 first)" || bad "stdin order preserved (701 first)"
[[ "$(grep -c -- '--yes' "$FAKE_DIR/wrapper.calls")" -eq 2 ]] \
  && ok "--yes forwarded in --from-ready mode" || bad "--yes forwarded in --from-ready mode"

# ── batch tool: --wait ────────────────────────────────────────────────────

new_case t9-batch-wait-pending-then-green
green_pr 801
pending_checks 801 2
run_tool "$SLUG" 801 --yes --wait
expect_rc 0 "--wait: a PENDING PR waits and then merges, exit 0"
expect_out "wait  #801 — checks PENDING" "progress line names the PR being waited on"
expect_out "MERGED: 801" "PR merged after the wait"
grep -qE -- "--wait=[0-9]+" "$FAKE_DIR/wrapper.calls" \
  && ok "remaining shared budget forwarded to the wrapper as --wait=<mins>" \
  || bad "remaining shared budget forwarded to the wrapper as --wait=<mins>"
# 2 pending polls + the green one: state and mergeability are RE-READ every
# poll, so a PR that goes closed/DIRTY mid-wait is caught, not carried forward.
t9_states="$(grep -cE 'pr view 801 .*--json state' "$FAKE_DIR/gh.calls")"
[[ "$t9_states" -eq 3 ]] \
  && ok "every poll re-verifies state/mergeability from scratch (3 re-reads)" \
  || bad "every poll re-verifies state/mergeability from scratch (got $t9_states, want 3)"

new_case t10-batch-wait-fail-still-stops
green_pr 811; green_pr 812
printf 'suite\tfail\thttps://ci/x\n' >"$FAKE_DIR/pr811.checks"
run_tool "$SLUG" 811 812 --yes --wait
expect_rc 1 "--wait: a FAILING check still stops the drain, exit 1"
expect_out "STOPPED-AT: 811 (checks FAIL)" "stop reason names the PR + FAIL"
expect_out "REMAINING: 811 812" "remaining lists stopped PR + everything after"
refute_out "wait  #811" "a red PR is never waited on"
[[ "$(wrapper_lines)" -eq 0 ]] && ok "no merge attempted" || bad "no merge attempted ($(wrapper_lines))"

# Timing contract of this case: #821 stays pending for 6 polls (>=1.2s of real
# sleeping, so at least one whole second is provably spent) and then goes green,
# well inside the 5s budget; #822 is pending forever and must therefore stop on
# what is LEFT of that same budget. A per-PR deadline would print "5s left" on
# #822's first wait line — a shared one cannot.
new_case t11-batch-wait-shared-deadline
green_pr 821; green_pr 822
pending_checks 821 6
printf 'suite\tpending\thttps://ci/x\n' >"$FAKE_DIR/pr822.checks"
export GH_MERGE_WAIT_SECS=5
run_tool "$SLUG" 821 822 --yes --wait
unset GH_MERGE_WAIT_SECS
expect_rc 1 "--wait: drain stops when the shared deadline expires, exit 1"
[[ "$(grep -c 'SHARED across' "$FAKE_DIR/out")" -eq 1 ]] \
  && ok "exactly ONE shared deadline announced for the whole drain" \
  || bad "exactly ONE shared deadline announced for the whole drain"
expect_out "MERGED: 821" "the PR that went green during the wait merged"
expect_out "STOPPED-AT: 822 (checks PENDING at the shared --wait deadline (5s))" \
  "second PR stops on the SHARED deadline"
t11_left="$(grep -m1 -- 'wait  #822' "$FAKE_DIR/out" | sed -E 's/.*\(([0-9]+)s left.*/\1/')"
[[ -n "$t11_left" && "$t11_left" -lt 5 ]] \
  && ok "second PR inherits the REMAINING budget (${t11_left}s of 5s), not a fresh one" \
  || bad "second PR inherits the REMAINING budget (got '${t11_left}', want <5)"

new_case t12-from-ready-with-wait
green_pr 901
pending_checks 901 2
cat >"$FAKE_DIR/stdin" <<'EOF'
  sudo merge-approved https://github.com/example-org/example-repo/pull/901 --repo example-org/example-repo
EOF
run_tool_stdin "$FAKE_DIR/stdin" --from-ready example-org/example-repo --yes --wait
expect_rc 0 "--from-ready still works with --wait"
expect_out "wait  #901" "--from-ready PR waits on PENDING"
expect_out "MERGED: 901" "--from-ready PR merges after the wait"

new_case t13-batch-wait-defaults-60
green_pr 911
run_tool "$SLUG" 911 --yes --wait
expect_rc 0 "bare --wait accepted, exit 0"
expect_out "--wait budget 60m SHARED across 1 PR(s)" "bare --wait defaults to 60 minutes"

new_case t14-batch-wait-bad-value
green_pr 921
run_tool "$SLUG" 921 --yes --wait=abc
expect_rc 2 "--wait=<non-number> exits 2"
expect_err "--wait needs a positive whole number of minutes" "bad --wait value explained"

# ── wrapper: --wait ───────────────────────────────────────────────────────

new_case w1-approved-wait-pending-then-green
seed_approved
rollup_pending >"$FAKE_DIR/rollup.0"
run_approved 42 --repo Fake/Repo --wait --yes
expect_rc 0 "--wait: pending → green merges, exit 0"
expect_out "up to 60m." "bare --wait defaults to a 60m budget"
expect_out "waiting on PR #42" "progress line printed on each poll"
expect_out "elapsed 0s" "progress line shows elapsed time"
expect_out "CI decided green" "the green transition is announced"
expect_merged "merge issued after the wait"
grep -qF -- "--match-head-commit aaaaaaaaaaaa" "$FAKE_DIR/merge.calls" \
  && ok "merge pinned to the SHA the gates passed on" \
  || bad "merge pinned to the SHA the gates passed on"
# The first evaluation returned PENDING at the checks gate, before the
# stale-base gate is ever reached — so ANY compare call proves the full gate
# set re-ran after the wait.
expect_gh "api repos/Fake/Repo/compare/master...aaaaaaaaaaaa" \
  "stale-base gate re-ran from scratch AFTER the wait"

new_case w2-approved-wait-then-red
seed_approved
rollup_pending >"$FAKE_DIR/rollup.0"
rollup_red >"$FAKE_DIR/rollup.default"
run_approved 43 --repo Fake/Repo --wait --yes
expect_rc 2 "--wait: pending → red exits 2"
expect_out "CI red on PR #43" "red is reported"
refute_merged "nothing merged when the wait ends red"

new_case w3-approved-wait-deadline
seed_approved
rollup_pending >"$FAKE_DIR/rollup.default"
export GH_MERGE_WAIT_SECS=1
run_approved 44 --repo Fake/Repo --wait --yes
unset GH_MERGE_WAIT_SECS
expect_rc 3 "--wait: deadline expiry exits non-zero (3)"
expect_out "--wait deadline (1s) expired" "expiry is explicit"
expect_out "Still pending: checks still running: CI" "expiry names what was still pending"
expect_out "gh pr checks 44 --repo Fake/Repo --watch" "expiry says what to do next"
refute_merged "nothing merged when the deadline expires"

new_case w4-approved-wait-head-moves
seed_approved
rollup_pending >"$FAKE_DIR/rollup.0"
rollup_pending >"$FAKE_DIR/rollup.1"
printf 'aaaaaaaaaaaa\n' >"$FAKE_DIR/head.0"
printf 'bbbbbbbbbbbb\n' >"$FAKE_DIR/head.1"
printf 'bbbbbbbbbbbb\n' >"$FAKE_DIR/head.default"
run_approved 45 --repo Fake/Repo --wait --yes
expect_rc 0 "--wait: force-push mid-wait still ends in a merge"
expect_out "head moved aaaaaaa → bbbbbbb" "head move detected"
expect_out "restarting the 60m wait against the new head" "wait restarts against the new head"
expect_gh "run list --repo Fake/Repo --commit bbbbbbbbbbbb" \
  "run-level gate re-queried against the NEW head"
grep -qF -- "--match-head-commit bbbbbbbbbbbb" "$FAKE_DIR/merge.calls" \
  && ok "merge pinned to the NEW head, not the dead one" \
  || bad "merge pinned to the NEW head, not the dead one"

new_case w5-approved-wait-stale-base-after
seed_approved
rollup_pending >"$FAKE_DIR/rollup.0"
printf '{"behind_by":3,"merge_base_commit":{"sha":"mb1"}}\n' >"$FAKE_DIR/compare.default"
printf '{"files":[{"filename":"config.py"}]}\n' >"$FAKE_DIR/basecmp.default"
printf 'config.py\n' >"$FAKE_DIR/prfiles.default"
run_approved 46 --repo Fake/Repo --wait --yes
expect_rc 5 "post-wait stale-base overlap refuses, exit 5"
expect_out "Stale base: master is 3 commit(s) ahead" "stale base reported after the wait"
expect_out "config.py" "the overlapping file is named"
refute_merged "no merge on a base that went stale during the wait"

new_case w6-approved-red-never-waits
seed_approved
rollup_red >"$FAKE_DIR/rollup.default"
run_approved 47 --repo Fake/Repo --wait --yes
expect_rc 2 "red on the first look exits 2 even with --wait"
refute_out "waiting on PR #47" "a decided outcome never enters the wait loop"
refute_merged "nothing merged"

new_case w7-approved-wait-value
seed_approved
rollup_pending >"$FAKE_DIR/rollup.0"
run_approved 48 --repo Fake/Repo --wait=5 --yes
expect_rc 0 "--wait=<mins> accepted, exit 0"
expect_out "up to 5m." "explicit budget honoured"
expect_merged "merge issued after the wait"

new_case w8-approved-no-wait-still-exits-3
seed_approved
rollup_pending >"$FAKE_DIR/rollup.default"
run_approved 49 --repo Fake/Repo --yes
expect_rc 3 "WITHOUT --wait a pending suite still refuses, exit 3"
expect_out "CI still running on PR #49" "unchanged refusal text"
refute_out "waiting on PR #49" "no polling without --wait"
refute_merged "nothing merged"

new_case w10-approved-force-beats-wait
seed_approved
rollup_pending >"$FAKE_DIR/rollup.default"
run_approved 51 --repo Fake/Repo --wait --force --yes
expect_rc 0 "--force wins over --wait: merges now, exit 0"
refute_out "waiting on PR #51" "--force never sits in the wait loop"
expect_merged "forced merge issued"

new_case w9-approved-wait-bad-value
seed_approved
run_approved 50 --repo Fake/Repo --wait=abc --yes
expect_rc 1 "--wait=<non-number> exits 1"
expect_err "--wait needs a positive whole number of minutes" "bad --wait value explained"

new_case q1-approved-merge-queue-retries-without-delete-branch
seed_approved
: >"$FAKE_DIR/queue_repo"
run_approved 60 --repo Fake/Repo --yes
expect_rc 0 "merge-queue repo still merges, exit 0"
expect_out "Merge queue detected" "explains the retry"
grep -qF -- "--delete-branch" "$FAKE_DIR/merge.calls" \
  && ok "first attempt did carry --delete-branch" \
  || bad "first attempt should have tried --delete-branch"
grep -vF -- "--delete-branch" "$FAKE_DIR/merge.calls" | grep -q "pr merge" \
  && ok "retry dropped --delete-branch" \
  || bad "retry should have dropped --delete-branch"
expect_out "QUEUED, not yet merged" "says the PR is queued, not merged"
rm -f "$FAKE_DIR/queue_repo"

new_case q2-non-queue-repo-keeps-delete-branch
seed_approved
run_approved 61 --repo Fake/Repo --yes
expect_rc 0 "non-queue repo merges, exit 0"
refute_out "Merge queue detected" "no queue path on a normal repo"
[[ "$(grep -c 'pr merge' "$FAKE_DIR/merge.calls")" == 1 ]] \
  && ok "exactly one merge attempt (no needless retry)" \
  || bad "expected exactly one merge attempt"

new_case q3-queue-without-automerge-explains-the-fix
seed_approved
: >"$FAKE_DIR/queue_repo"; : >"$FAKE_DIR/no_automerge"
run_approved 62 --repo Fake/Repo --yes
expect_rc 1 "unmergeable queue repo exits non-zero"
expect_out "allow_auto_merge is DISABLED" "names the actual blocker"
expect_out "allow_auto_merge=true" "gives the durable fix"
expect_out "--admin" "gives the one-off bypass"
rm -f "$FAKE_DIR/queue_repo" "$FAKE_DIR/no_automerge"

new_case q4-queue-repo-without-dbom-warns-branch-survives
seed_approved
: >"$FAKE_DIR/queue_repo"; : >"$FAKE_DIR/dbom_off"
run_approved 63 --repo Fake/Repo --yes
expect_rc 0 "still merges, exit 0"
expect_out "delete_branch_on_merge DISABLED" "warns the branch will survive"
refute_out "deletes merged branches itself" "does not promise cleanup it cannot do"
rm -f "$FAKE_DIR/queue_repo" "$FAKE_DIR/dbom_off"

# ── summary ───────────────────────────────────────────────────────────────
echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
exit 0
