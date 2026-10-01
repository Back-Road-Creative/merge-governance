#!/usr/bin/env bash
# Authorized PR merge — root-owned, requires sudo.
# This is the intended merge path: review the PR on GitHub, then run this.
# Merges the PR, deletes the source branch, and resyncs local base branch.
#
# Usage:
#   sudo merge-approved <PR number>
#   sudo merge-approved <PR number> --merge
#   sudo merge-approved <PR number> --rebase
#   sudo merge-approved <PR number> --repo Owner/Repo
#   sudo merge-approved <PR number> --yes
#   sudo merge-approved <PR number> --wait       # poll up to 60m for green
#   sudo merge-approved <PR number> --wait=90    # …or up to 90m
#   sudo merge-approved <PR number> --force      # override CI-red/CI-pending gate
#
# --wait exists because every gate below refuses a PENDING suite
# (exit 3), so a command pasted the moment a PR is pushed CANNOT succeed yet and
# the operator is forced to re-run it until CI happens to be green — the human
# becomes the polling loop. With --wait an UNDECIDED outcome (checks pending,
# workflow runs in flight, no run registered yet, no checks yet) polls instead of
# exiting; a DECIDED bad outcome (red, cancelled, stale base, unevaluable) still
# stops immediately — waiting is only ever for "not yet decided".
#
# When the wait ends, EVERY gate re-runs from scratch — including the stale-base
# file-overlap gate — against a freshly resolved head SHA; no verdict computed
# before the wait is carried forward. The merge stays pinned with
# --match-head-commit to the SHA the gates actually passed on. A force-push
# mid-wait moves the head and kills the run being watched, so the wait detects
# the move and restarts against the new head.
#
# Exit codes: 1 usage/abort, 2 CI red, 3 CI pending (also: --wait deadline
#             expired with CI still undecided), 4 no CI runs/checks,
#             5 stale base with file overlap (or overlap undeterminable),
#             6 gates unevaluable (identity/compare API failure, or the PR's base
#               branch is unknown — fail CLOSED, never fail open; an unknown
#               base is never replaced by a guessed default and is not
#               overridable with --force).
#
# Configuration. The binary/timing seams double as the offline test harness's
# injection points and default to the real thing in production:
#   GH_BIN               - the gh binary                    (default: /usr/bin/gh)
#   GH_MERGE_POLL_SECS   - --wait poll interval, seconds     (default: 75)
#   GH_MERGE_WAIT_SECS   - override the whole --wait budget, in seconds
#   MERGE_RUN_AS         - the account whose gh/git credentials to use when this
#                          runs as root (default: $SUDO_USER). Root has no gh
#                          auth of its own and git refuses another user's
#                          checkout, so every read and every local git call is
#                          dropped back to this user.
#   MERGE_APPROVED_LOG   - where --force overrides are recorded
#                          (default: /var/log/merge-approved.log; falls back to
#                          syslog when that path is not writable)
#   GH_MERGE_APPROVED_TEST_MODE - skip the root requirement and the GH_TOKEN
#                          hand-off. Honoured ONLY when not already root, and
#                          `sudo` scrubs the environment, so it cannot weaken the
#                          privileged path. It grants nothing: every gate still
#                          runs and gh falls back to the invoking user's own auth.

# The policy contract this file enforces. Documented in README.md ("Policy
# contract") and stated machine-readably in policy/contract.v1.json; the test
# harness fails if the three disagree. Bump it, and add a new contract file,
# when a gate or exit code changes meaning.
MERGE_POLICY_VERSION=1

GH_BIN="${GH_BIN:-/usr/bin/gh}"
GH_MERGE_POLL_SECS="${GH_MERGE_POLL_SECS:-75}"
MERGE_APPROVED_LOG="${MERGE_APPROVED_LOG:-/var/log/merge-approved.log}"

test_mode=0
if [[ "${GH_MERGE_APPROVED_TEST_MODE:-0}" == "1" && $EUID -ne 0 ]]; then
    test_mode=1
fi

if [[ $EUID -ne 0 && $test_mode -ne 1 ]]; then
    echo "" >&2
    echo "  ERROR: requires sudo." >&2
    echo "  Usage: sudo merge-approved <PR number> [--repo Owner/Repo] [--squash|--merge|--rebase] [--yes] [--wait[=<mins>]] [--force]" >&2
    echo "" >&2
    exit 1
fi

if [[ -z "$1" ]]; then
    echo "" >&2
    echo "  Usage: sudo merge-approved <PR number> [--repo Owner/Repo] [--squash|--merge|--rebase] [--yes] [--wait[=<mins>]] [--force]" >&2
    echo "" >&2
    exit 1
fi

# Single gh entry point. The --wait polling calls deliberately go through it
# rather than opening a second auth path: root has no gh state, so the token is
# taken ONCE from the invoking user below and exported for every call, polls
# included.
gh_q() { "$GH_BIN" "$@"; }

# Root has no gh credentials and git refuses a checkout it does not own, so
# every credentialed call drops back to the human who invoked sudo. There is no
# hardcoded account: set MERGE_RUN_AS if it is not $SUDO_USER.
RUN_AS="${MERGE_RUN_AS:-${SUDO_USER:-}}"
as_user() {
    if [[ $EUID -eq 0 && -n "$RUN_AS" ]]; then
        sudo -u "$RUN_AS" "$@"
    else
        "$@"
    fi
}

# Source GH_TOKEN from the invoking user (root has no gh auth state)
if [[ $test_mode -ne 1 ]]; then
    export GH_TOKEN
    GH_TOKEN=$(as_user "$GH_BIN" auth token 2>/dev/null || true)
    if [[ -z "$GH_TOKEN" ]]; then
        echo "" >&2
        echo "  ERROR: no gh token available for '${RUN_AS:-root}'." >&2
        echo "  Run \`gh auth login\` as that user, or set MERGE_RUN_AS=<user>." >&2
        echo "" >&2
        exit 1
    fi
fi

pr="$1"
shift

# Parse optional flags
strategy="--squash"
auto_confirm=0
force_ci_override=0
wait_enabled=0
wait_mins=60
repo_flag=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            if [[ -z "${2:-}" ]]; then
                echo "  ERROR: --repo requires an argument (Owner/Repo)" >&2
                exit 1
            fi
            repo_flag=(--repo "$2")
            shift 2
            ;;
        --squash|--merge|--rebase)
            strategy="$1"
            shift
            ;;
        --yes|-y)
            auto_confirm=1
            shift
            ;;
        --wait)
            # Bare --wait defaults to 60 minutes; `--wait 90` is accepted too,
            # but only when the next token is a bare number (so `--wait --yes`
            # still means "60 minutes", not "unknown argument").
            wait_enabled=1
            wait_mins=60
            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                wait_mins="$2"
                shift
            fi
            shift
            ;;
        --wait=*)
            wait_enabled=1
            wait_mins="${1#*=}"
            shift
            ;;
        --force)
            force_ci_override=1
            shift
            ;;
        *)
            echo "  ERROR: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ "$wait_enabled" -eq 1 ]]; then
    if ! [[ "$wait_mins" =~ ^[0-9]+$ ]] || [[ "$wait_mins" -lt 1 ]]; then
        echo "  ERROR: --wait needs a positive whole number of minutes (got '$wait_mins')" >&2
        exit 1
    fi
fi

wait_secs=$(( wait_mins * 60 ))
wait_label="${wait_mins}m"
if [[ -n "${GH_MERGE_WAIT_SECS:-}" ]]; then
    wait_secs="$GH_MERGE_WAIT_SECS"
    wait_label="${wait_secs}s"
fi

# --wait only ever defers an UNDECIDED gate, and --force means "merge now
# anyway", so --force wins outright: never sit waiting for a suite the caller
# has already declared irrelevant.
should_wait() { [[ "$wait_enabled" -eq 1 && "$force_ci_override" -ne 1 ]]; }

# Central helper for the force-override escape: log (file, then syslog) and
# continue. Every gate refusal below funnels through refuse_or_force so no
# gate can be overridden without a log line being attempted.
refuse_or_force() { # <exit-code> <log-tag> <refusal-lines...>
    local code="$1" tag="$2"
    shift 2
    if [[ "$force_ci_override" -ne 1 ]]; then
        local line
        for line in "$@"; do echo "  $line"; done
        echo ""
        exit "$code"
    fi
    echo "  ⚠️  --force supplied; bypassing this gate."
    local log_msg
    log_msg="$(date -Is) PR=#$pr user=${SUDO_USER:-?} force-override $tag"
    echo "$log_msg" >> "$MERGE_APPROVED_LOG" 2>/dev/null || \
        logger -t merge-approved "$log_msg" 2>/dev/null || true
    echo ""
}

# Get base branch before merge: the stale-base gate compares against it and the
# post-merge resync resets to it. It is read from the PR and NEVER guessed. A
# guessed base ("master") on a repo whose base is something else makes the
# stale-base gate compare the wrong branch and the resync reset the wrong one,
# so an unknown base is a refusal, not a default. Three outcomes are kept apart
# so the diagnostic says which one happened:
#   lookup failed (gh exited non-zero)  -> API failure
#   lookup succeeded, empty or null     -> PR reports no base
#   lookup succeeded, a name            -> proceed (master, main, staging, ...)
# Not overridable with --force: --force skips a gate, but it cannot supply the
# base branch the gates and the resync are defined against.
base_rc=0
base_branch=$(gh_q pr view "$pr" "${repo_flag[@]}" --json baseRefName --jq '.baseRefName' 2>/dev/null) || base_rc=$?
if [[ "$base_rc" -ne 0 ]]; then
    echo "  ❌ Could not read the base branch of PR #$pr (gh exited $base_rc — API failure?)." >&2
    echo "     Base branch unknown; refusing to guess one. Nothing was merged." >&2
    echo "     Retry when the API answers. --force does not apply here." >&2
    echo "" >&2
    exit 6
fi
if [[ -z "$base_branch" || "$base_branch" == "null" ]]; then
    echo "  ❌ PR #$pr reports no base branch (empty or null baseRefName)." >&2
    echo "     Base branch unknown; refusing to guess one. Nothing was merged." >&2
    echo "     Check the PR on GitHub (repo, number, --repo). --force does not apply here." >&2
    echo "" >&2
    exit 6
fi

# Show what is about to be merged
echo ""
gh_q pr view "$pr" "${repo_flag[@]}" --json number,title,baseRefName,headRefName,url \
    --template "  PR #{{.number}}: {{.title}}
  {{.headRefName}} → {{.baseRefName}}
  {{.url}}
"
echo ""

# ─── Already-merged short-circuit ──────────────────────────────────────
# Every gate below reasons about MERGING this PR. Once it is MERGED none of
# them are meaningful, and the stale-base gate becomes actively wrong: the base
# now contains this PR's OWN squashed commit, so the gate lists the PR's own
# files as a conflicting change and ends its remedy with "or pass --force" —
# training a force at the exact moment there is nothing to force. It is easy to
# hit: re-running the command seconds after a clean merge does it.
# "The PR you asked to merge is merged" is the desired end state, so this
# exits 0.
pr_state=$(gh_q pr view "$pr" "${repo_flag[@]}" --json state --jq '.state' 2>/dev/null || echo "")
if [[ "$pr_state" == "MERGED" ]]; then
    merge_sha=$(gh_q pr view "$pr" "${repo_flag[@]}" --json mergeCommit \
        --jq '.mergeCommit.oid // ""' 2>/dev/null || echo "")
    echo "  ✅ Already merged${merge_sha:+ as ${merge_sha:0:9}} — nothing to do."
    echo ""
    exit 0
fi
if [[ "$pr_state" == "CLOSED" ]]; then
    echo "  ⛔ PR #$pr is CLOSED, not merged — refusing." >&2
    echo "     Reopen it or check the number; no gate below can act on a closed PR." >&2
    echo ""
    exit 1
fi

# ─── Gates ────────────────────────────────────────────────────────────
# ALL gates live in one function so --wait can re-run the WHOLE set from
# scratch after the wait — a verdict computed before the wait (green checks, a
# fresh base, a head SHA) is worthless afterwards. Contract:
#   return 0  => every gate passed; $head_sha holds the SHA they passed on.
#   return 1  => an UNDECIDED gate deferred to --wait; $gate_pending says which.
#   exit      => a decided refusal (red / stale / unevaluable), as before.
# The body is deliberately left at column 0: these gates are load-bearing and
# heavily commented, and re-indenting ~200 unchanged lines would have buried the
# actual behaviour change in a whitespace diff. The `}` at "return 0" closes it.
gate_pending=""
evaluate_gates() {
gate_pending=""

# ─── CI gate ──────────────────────────────────────────────────────────
# GitHub Free private orgs don't enforce branch protection (the REST
# protection endpoint 403s with "Upgrade to GitHub Pro"), so the platform
# never blocks merges on red CI and there is no such thing as a "required
# check" there. On such a repo this script is the ONLY gate. --force overrides
# for genuine emergencies; the override is logged to $MERGE_APPROVED_LOG when
# writable, and to syslog otherwise.
#
# Fetched once: several independent questions are asked of the same rollup.
rollup=$(gh_q pr view "$pr" "${repo_flag[@]}" --json statusCheckRollup 2>/dev/null || echo '{}')

# Repo/head identifiers, needed by the run-level and stale-base gates below.
# Re-resolved on EVERY evaluation: under --wait a force-push can move the head
# mid-flight, and the caller must never merge a SHA it did not gate.
repo_nwo=$(gh_q pr view "$pr" "${repo_flag[@]}" --json url --jq '.url' 2>/dev/null \
    | sed -E 's#^https://github\.com/([^/]+/[^/]+)/pull/.*$#\1#')
head_sha=$(gh_q pr view "$pr" "${repo_flag[@]}" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "")

# 0. IDENTITY RESOLUTION — the run-level (2b) and stale-base (4) gates need
#    the repo and head SHA. The previous version silently SKIPPED both gates
#    when either lookup failed, so a transient API error became a gate
#    bypass. Fail closed instead.
if [[ -z "$repo_nwo" || -z "$head_sha" ]]; then
    echo "  ❌ Could not resolve repo/head SHA for PR #$pr (API failure?)"
    echo "     The run-level and stale-base gates cannot run without them."
    echo ""
    refuse_or_force 6 "IDENTITY-UNRESOLVED" \
        "Refusing to merge blind. Retry, or pass --force to override (will be logged)."
fi

# 1. Red CI. Covers BOTH rollup shapes: Actions/check-suite entries
#    (CheckRun.conclusion) and legacy commit statuses (StatusContext.state),
#    which the conclusion-only test silently ignored. CANCELLED /
#    ACTION_REQUIRED / STALE are red too: a cancelled suite is
#    status=COMPLETED, so without these it passed every gate — an
#    operator-cancelled run read as green.
#
#    Red is a DECIDED outcome, so --wait never defers it: the whole point of
#    waiting is "not yet decided".
ci_failures=$(echo "$rollup" \
    | jq -r '[.statusCheckRollup[]?
        | select((.conclusion // "") == "FAILURE"
              or (.conclusion // "") == "TIMED_OUT"
              or (.conclusion // "") == "STARTUP_FAILURE"
              or (.conclusion // "") == "CANCELLED"
              or (.conclusion // "") == "ACTION_REQUIRED"
              or (.conclusion // "") == "STALE"
              or (.state // "") == "FAILURE"
              or (.state // "") == "ERROR")
        | (.name // .context // "unnamed")] | join(", ")' 2>/dev/null || echo "")

if [[ -n "$ci_failures" ]]; then
    echo "  ❌ CI red on PR #$pr"
    echo "     Failing checks: $ci_failures"
    echo ""
    refuse_or_force 2 "CI-FAILURES=\"$ci_failures\"" \
        "Refusing to merge. Pass --force to override (will be logged)."
fi

# 2. INCOMPLETE CI — a check that has not finished has conclusion=null, so
#    the red-CI test above cannot see it and the merge sails through while
#    the suite is still running. This is not hypothetical: a PR has merged
#    with its whole per-service test matrix still pending, because that matrix
#    only fans out AFTER a discovery job passes — at the moment the fast
#    governance checks went green the PR looked complete, and the actual test
#    jobs had not been created yet.
#    Pending is NOT green. Wait for it (--wait does exactly that), or --force
#    deliberately.
#    StatusContext EXPECTED counts as pending too (a promised-but-unreported
#    context is not success).
ci_pending=$(echo "$rollup" \
    | jq -r '[.statusCheckRollup[]?
        | select((.__typename == "CheckRun" and (.status // "") != "COMPLETED")
              or (.__typename == "StatusContext"
                  and ((.state // "") == "PENDING" or (.state // "") == "EXPECTED")))
        | (.name // .context // "unnamed")] | join(", ")' 2>/dev/null || echo "")

if [[ -n "$ci_pending" ]]; then
    if should_wait; then
        gate_pending="checks still running: $ci_pending"
        return 1
    fi
    echo "  ⏳ CI still running on PR #$pr"
    echo "     Pending checks: $ci_pending"
    echo ""
    refuse_or_force 3 "CI-PENDING=\"$ci_pending\"" \
        "Refusing to merge an unfinished suite. Wait for it, then re-run:" \
        "  gh pr checks $pr ${repo_flag[*]} --watch" \
        "Or re-run this command with --wait to poll until it is green." \
        "Or pass --force to merge anyway (will be logged)."
fi

# 2b. RUN-LEVEL INCOMPLETENESS — the gate above can only see checks that EXIST.
#     A matrix job is not registered as a check until its `needs:` dependency
#     finishes, so between "the last quality job completes" and "the test jobs
#     get created" the rollup momentarily reads as fully COMPLETED while
#     the suite has barely started. That blind window is the ACTUAL shape of the
#     failure described above, and a rollup-only gate does not close it.
#
#     Observed directly: statusCheckRollup listed every entry as
#     COMPLETED/SUCCESS while `gh run list --commit <head>` reported the CI run
#     as `queued`, with its test jobs not yet created.
#
#     The workflow RUN status is the authoritative "is CI finished" signal.
#     Scoped to Actions runs deliberately: a third-party check-suite (e.g. a
#     review app) that never completes must not deadlock merges forever.
if [[ -n "$repo_nwo" && -n "$head_sha" ]]; then
    runs_json=$(gh_q run list --repo "$repo_nwo" --commit "$head_sha" \
        --json status,conclusion,name 2>/dev/null || echo '[]')
    runs_pending=$(echo "$runs_json" \
        | jq -r '[.[] | select(.status != "completed") | .name] | unique | join(", ")' 2>/dev/null || echo "")
    runs_total=$(echo "$runs_json" | jq -r 'length' 2>/dev/null || echo 0)

    # ZERO Actions runs for this head is NOT "nothing pending" — it means the
    # workflow never started. The rollup can still look populated (a
    # third-party check app posts its own entries), so gate 3 does not catch
    # this. The likely cause is a PR that breaks the workflow file itself, which
    # is precisely the PR you least want merging unchecked.
    #
    # Under --wait this is UNDECIDED, not decided: for the first seconds after a
    # push GitHub has genuinely not created the run yet, which is exactly when
    # the operator pastes the command. A workflow that is actually broken simply
    # never resolves and the deadline reports it.
    if [[ "$runs_total" -eq 0 ]]; then
        if should_wait; then
            gate_pending="no GitHub Actions run registered for ${head_sha:0:7} yet (a broken workflow file also looks like this)"
            return 1
        fi
        echo "  ⚠️  No GitHub Actions run exists for $head_sha — CI never started."
        echo "     (a broken workflow file on this branch will do this; other apps'"
        echo "      checks can still make the PR look checked)"
        echo ""
        refuse_or_force 4 "NO-ACTIONS-RUN sha=$head_sha" \
            "Refusing to merge. Pass --force to override (will be logged)."
    fi

    # A COMPLETED run that did not succeed is red at the run level even when
    # no per-check entry says FAILURE — `gh run list` reports cancelled /
    # timed_out / action_required / startup_failure runs as status=completed,
    # so the pending test below can never see them. Decided => --wait never
    # defers it.
    runs_bad=$(echo "$runs_json" \
        | jq -r '[.[] | select(.status == "completed")
            | .conclusion = ((.conclusion // "") | ascii_downcase)
            | select(.conclusion != "success" and .conclusion != "skipped" and .conclusion != "neutral")
            | "\(.name) [\(.conclusion)]"] | unique | join(", ")' 2>/dev/null || echo "")

    if [[ -n "$runs_bad" ]]; then
        echo "  ❌ Workflow run(s) for $head_sha completed WITHOUT success:"
        echo "     $runs_bad"
        echo "     (a cancelled suite is not a green suite)"
        echo ""
        refuse_or_force 2 "RUNS-NOT-SUCCESS=\"$runs_bad\"" \
            "Refusing to merge. Re-run the workflow so it finishes green, or pass" \
            "--force to override (will be logged)."
    fi

    if [[ -n "$runs_pending" ]]; then
        if should_wait; then
            gate_pending="workflow run(s) in flight for ${head_sha:0:7}: $runs_pending"
            return 1
        fi
        echo "  ⏳ Workflow run(s) still in flight for $head_sha"
        echo "     Incomplete runs: $runs_pending"
        echo "     (checks may look complete — jobs gated behind 'needs:' are not"
        echo "      registered as checks until their dependency finishes)"
        echo ""
        refuse_or_force 3 "RUNS-PENDING=\"$runs_pending\"" \
            "Refusing to merge before CI has finished. Watch it with:" \
            "  gh run watch --repo $repo_nwo \$(gh run list --repo $repo_nwo --commit $head_sha --json databaseId --jq '.[0].databaseId')" \
            "Or re-run this command with --wait to poll until it is green." \
            "Or pass --force to merge anyway (will be logged)."
    fi
fi

# 3. NO CHECKS AT ALL — an empty rollup means CI never started (bad workflow
#    ref, runner offline). Silence is not success. Under --wait it is undecided
#    for the same reason as the zero-runs case above.
if [[ -z "$(echo "$rollup" | jq -r '[.statusCheckRollup[]?] | length' 2>/dev/null)" ]] \
   || [[ "$(echo "$rollup" | jq -r '[.statusCheckRollup[]?] | length' 2>/dev/null)" == "0" ]]; then
    if should_wait; then
        gate_pending="no CI checks reported yet on PR #$pr"
        return 1
    fi
    echo "  ⚠️  No CI checks reported on PR #$pr — CI may never have started."
    echo ""
    refuse_or_force 4 "NO-CHECKS" \
        "Refusing to merge. Pass --force to override (will be logged)."
fi

# 4. STALE BASE / SEMANTIC DRIFT — green CI proves the PR worked against the
#    base it was TESTED on. It says nothing about the base it will LAND on.
#    On a busy repo — many merges a day, CI latency measured in hours — the
#    base routinely moves underneath a PR, and no check on either side can see
#    the combination. The real cases look mundane: a PR and the commits that
#    land while it waits edit the same two or three shared files.
#
#    This is also why --wait re-runs the gates instead of merging on the
#    verdict it started with: the longer the wait, the more master has moved.
#
#    Blanket "refuse if behind" would fire on nearly every PR here and just
#    train the operator to pass --force, so the gate is narrowed to the case
#    with actual signal: master changed a file THIS PR also changes. Behind
#    with no file overlap is reported and allowed.
#
#    Fail-closed rules: a failed compare call and a truncated file list are
#    both "overlap unknown", which refuses — the previous version read a
#    failed call as behind_by=0 (gate silently passed) and the compare API
#    caps .files at 300 with no pagination (overlap silently under-detected).
if [[ -n "$repo_nwo" && -n "$head_sha" ]]; then
    cmp_json=$(gh_q api "repos/$repo_nwo/compare/$base_branch...$head_sha" 2>/dev/null || echo "{}")
    behind_by=$(echo "$cmp_json" | jq -r '.behind_by // "unknown"' 2>/dev/null || echo "unknown")
    merge_base=$(echo "$cmp_json" | jq -r '.merge_base_commit.sha // ""' 2>/dev/null || echo "")

    if [[ "$behind_by" == "unknown" ]]; then
        echo "  ❌ Could not compare $base_branch...$head_sha (API failure?) —"
        echo "     the stale-base gate cannot run."
        echo ""
        refuse_or_force 6 "STALE-BASE-UNEVALUABLE" \
            "Refusing to merge blind. Retry, or pass --force to override (will be logged)."
        behind_by=0
    fi

    if [[ "$behind_by" -gt 0 && -n "$merge_base" ]]; then
        pr_files=$(gh_q api "repos/$repo_nwo/pulls/$pr/files" --paginate \
            --jq '.[].filename' 2>/dev/null | sort -u)
        base_cmp=$(gh_q api "repos/$repo_nwo/compare/$merge_base...$base_branch" 2>/dev/null || echo "{}")

        if ! echo "$base_cmp" | jq -e '.files' >/dev/null 2>&1; then
            echo "  ❌ Could not list files $base_branch moved since the merge base"
            echo "     (API failure?) — overlap cannot be determined."
            echo ""
            refuse_or_force 6 "STALE-BASE-FILES-UNEVALUABLE behind=$behind_by" \
                "Refusing to merge blind. Retry, or pass --force to override (will be logged)."
            base_cmp='{"files":[]}'
        fi

        base_files_n=$(echo "$base_cmp" | jq -r '.files | length' 2>/dev/null || echo 0)
        if [[ "$base_files_n" -ge 300 ]]; then
            echo "  ⚠️  $base_branch moved ≥300 files since this PR's merge base — the"
            echo "     compare API truncates at 300, so overlap detection is blind past"
            echo "     that. Treating overlap as unknown."
            echo ""
            refuse_or_force 5 "STALE-BASE-TRUNCATED behind=$behind_by files=300+" \
                "Refusing to merge. Rebase onto origin/$base_branch so CI tests the" \
                "real merged content, or pass --force (will be logged)."
        fi

        base_files=$(echo "$base_cmp" | jq -r '.files[]?.filename' 2>/dev/null | sort -u)
        overlap=$(comm -12 <(echo "$pr_files") <(echo "$base_files") 2>/dev/null)

        if [[ -n "$overlap" ]]; then
            echo "  ⚠️  Stale base: $base_branch is $behind_by commit(s) ahead, and has"
            echo "     modified files this PR also modifies — CI tested neither combination:"
            echo "$overlap" | sed 's/^/       /'
            echo ""
            refuse_or_force 5 "STALE-BASE behind=$behind_by overlap=\"$(echo "$overlap" | tr '\n' ' ')\"" \
                "Refusing to merge. Update the branch so CI tests the real merged" \
                "content, then re-run:" \
                "  git fetch origin && git rebase origin/$base_branch && git push --force-with-lease" \
                "Or pass --force if you have confirmed the changes don't interact."
        elif [[ "$behind_by" -gt 0 ]]; then
            echo "  ℹ️  $base_branch is $behind_by commit(s) ahead, but touches no file this"
            echo "     PR touches — proceeding."
            echo ""
        fi
    fi
fi

return 0
}

# ─── --wait loop ──────────────────────────────────────────────────────
# Entered only when evaluate_gates deferred an UNDECIDED outcome. Every poll
# re-runs the ENTIRE gate set (identity, red, pending, run-level, stale base),
# so the merge below is always authorised by a verdict computed on the head SHA
# it is about to pin.
wait_for_green() {
    local start_epoch deadline_epoch now elapsed remaining watch_sha
    start_epoch=$(date +%s)
    deadline_epoch=$(( start_epoch + wait_secs ))
    watch_sha="$head_sha"
    echo "  ⏳ --wait: polling PR #$pr every ${GH_MERGE_POLL_SECS}s, up to ${wait_label}."
    echo "     Not yet decided: $gate_pending"
    echo ""
    while true; do
        now=$(date +%s)
        if (( now >= deadline_epoch )); then
            echo "  ⏰ --wait deadline (${wait_label}) expired — CI on PR #$pr is STILL undecided."
            echo "     Still pending: $gate_pending"
            echo "     Head watched:  ${watch_sha:-unknown}"
            echo "     Nothing was merged. Next:"
            echo "       gh pr checks $pr ${repo_flag[*]} --watch"
            echo "     then re-run this command (add --wait=<mins> for a longer budget)."
            echo ""
            exit 3
        fi
        elapsed=$(( now - start_epoch ))
        remaining=$(( deadline_epoch - now ))
        echo "  ⏳ waiting on PR #$pr — $gate_pending [elapsed ${elapsed}s, ${remaining}s left of ${wait_label}, head ${watch_sha:0:7}]"
        sleep "$GH_MERGE_POLL_SECS"

        if evaluate_gates; then
            echo "  ✅ CI decided green after $(( $(date +%s) - start_epoch ))s — re-running all gates passed on ${head_sha:0:7}."
            echo ""
            return 0
        fi

        # A force-push during the wait resets CI: the run being watched is dead
        # and its outcome is meaningless. Restart the wait against the new head
        # rather than counting down against a corpse.
        if [[ -n "$head_sha" && "$head_sha" != "$watch_sha" ]]; then
            echo "  🔄 head moved ${watch_sha:0:7} → ${head_sha:0:7} (force-push?) — the watched"
            echo "     run is dead; restarting the ${wait_label} wait against the new head."
            watch_sha="$head_sha"
            start_epoch=$(date +%s)
            deadline_epoch=$(( start_epoch + wait_secs ))
        fi
    done
}

if ! evaluate_gates; then
    # Only reachable under --wait: without it every undecided gate exits above.
    wait_for_green
fi

if [[ "$auto_confirm" -eq 1 ]]; then
    confirm="yes"
else
    read -r -p "  Merge this PR? [yes/N] " confirm
    echo ""
fi

if [[ "$confirm" != "yes" ]]; then
    echo "  Aborted." >&2
    exit 1
fi

# Pin the merge to the head SHA every gate above examined — a push landing
# between the checks and this call must fail the merge, not slip through
# ungated. (gh errors out if the head moved; re-run to re-gate the new head.)
# Under --wait this is the SHA of the final, post-wait evaluation.
match_flag=()
[[ -n "$head_sha" ]] && match_flag=(--match-head-commit "$head_sha")

# Merge on GitHub. Squash strategy creates a new SHA so gh's attempt to
# fast-forward the local branch always fails — filter those git warnings
# since we reset the local branch ourselves below.
#
# --delete-branch is incompatible with a merge queue: gh refuses outright with
# "Cannot use `-d` or `--delete-branch` when merge queue enabled" and merges
# NOTHING. Rather than probe for a queue up front — branch-protection and
# ruleset reads 403 on private repos on the free plan — retry once without the
# flag on exactly that error.
#
# The queue also OWNS the merge strategy ("The merge strategy for main is set
# by the merge queue"), so the retry drops $strategy too rather than passing a
# flag GitHub will only warn about.
#
# Branch cleanup on the retry depends on the repo's delete_branch_on_merge.
# Do NOT assume it is on — it varies repo by repo inside the same org. So the
# retry reports what will actually happen instead of promising cleanup it
# cannot deliver.
noise_re="(not possible to fast-forward|Diverging branches|have diverged|git merge|git rebase|advice\.diverging|hint:)"
merge_out=$(gh_q pr merge "$pr" "${repo_flag[@]}" "$strategy" --delete-branch "${match_flag[@]}" 2>&1)
merge_rc=$?

if [[ $merge_rc -ne 0 && "$merge_out" == *"merge queue enabled"* ]]; then
    dbom=$(gh_q api "repos/$repo_nwo" --jq '.delete_branch_on_merge' 2>/dev/null || echo "")
    if [[ "$dbom" == "true" ]]; then
        echo "  Merge queue detected — retrying without --delete-branch (the repo"
        echo "  deletes merged branches itself)."
    else
        echo "  Merge queue detected — retrying without --delete-branch."
        echo "  NOTE: $repo_nwo has delete_branch_on_merge DISABLED, so the branch"
        echo "  will survive the merge. Delete it yourself, or enable the setting:"
        echo "    gh api -X PATCH repos/$repo_nwo -F delete_branch_on_merge=true"
    fi
    merge_out=$(gh_q pr merge "$pr" "${repo_flag[@]}" "${match_flag[@]}" 2>&1)
    merge_rc=$?
    queued=1
fi

printf '%s\n' "$merge_out" | grep -v -E "$noise_re" || true

# A merge queue enqueues THROUGH the auto-merge API, so a repo with
# allow_auto_merge disabled cannot merge via `gh pr merge` at all — the queue
# is enabled but unusable. Name the exact fix rather than leaving a raw
# GraphQL error — the combination happens whenever a queue ruleset is added
# without also enabling allow_auto_merge, which makes every PR in the repo
# unmergeable by this tool.
if [[ $merge_rc -ne 0 && "$merge_out" == *"enablePullRequestAutoMerge"* ]]; then
    echo ""
    echo "  $repo_nwo has a MERGE QUEUE but allow_auto_merge is DISABLED, and a"
    echo "  queue can only be entered through the auto-merge API — so no PR in"
    echo "  this repo can be merged by this tool until one of these is true:"
    echo ""
    echo "    # (a) let the queue work as intended"
    echo "    gh api -X PATCH repos/$repo_nwo -F allow_auto_merge=true"
    echo ""
    echo "    # (b) or bypass the queue for this one merge (admin override)"
    echo "    gh pr merge $pr --repo $repo_nwo $strategy --admin"
    echo ""
    echo "  (a) is the durable fix; (b) skips the queue's own checks."
    echo ""
fi

# With a queue, `gh pr merge` ENQUEUES; it does not produce a merge commit
# now. Say so, so a green exit is not misread as "already on the base branch".
if [[ ${queued:-0} -eq 1 && $merge_rc -eq 0 ]]; then
    echo ""
    echo "  PR #$pr is QUEUED, not yet merged. The queue runs its own checks and"
    echo "  merges when they pass. Watch it with:"
    echo "    gh pr view $pr ${repo_flag[*]} --json state,mergeCommit"
    echo ""
fi

# gh pr merge (with --delete-branch) runs git fetch/checkout as root,
# leaving root-owned files in .git/. Restore ownership to the real user.
real_user="${SUDO_USER:-}"
if [[ -n "$real_user" && -d .git ]]; then
    find . -user root -exec chown "$real_user":"$real_user" {} +
fi

# Resync local base branch — squash merge creates a new SHA on origin,
# causing "diverged branches" errors on the next push. Auto-reset here
# so the local branch is always clean after a merge.
#
# Guarded: this runs in the CALLER'S cwd, which with --repo may be a completely
# different repo, and a bare `checkout <base>` here could yank a parked feature
# branch out from under another session. Two preconditions, both fail-safe to
# "print the manual line":
#   (a) the cwd's origin must BE the merged repo (owner/name match), and
#   (b) the cwd must ALREADY be on $base_branch — we never switch branches.
if [[ $test_mode -ne 1 && $merge_rc -eq 0 ]] && as_user git -C . rev-parse --git-dir &>/dev/null; then
    cwd_origin=$(as_user git -C . remote get-url origin 2>/dev/null || echo "")
    cwd_nwo=$(echo "$cwd_origin" \
        | sed -E -e 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)##' \
                 -e 's#\.git$##' -e 's#/+$##')
    cur_branch=$(as_user git -C . rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ -z "$cwd_nwo" || "${cwd_nwo,,}" != "${repo_nwo,,}" ]]; then
        echo ""
        echo "  Skipping local resync: cwd origin (${cwd_nwo:-none}) is not the merged"
        echo "  repo ($repo_nwo). Run manually in that repo's checkout when ready:"
        echo "    git fetch origin && git reset --hard origin/$base_branch"
        echo ""
    elif [[ "$cur_branch" != "$base_branch" ]]; then
        echo ""
        echo "  Skipping local resync: current branch '$cur_branch' is not '$base_branch'"
        echo "  and this tool never switches branches. Run manually when ready:"
        echo "    git checkout $base_branch && git fetch origin && git reset --hard origin/$base_branch"
        echo ""
    # Guard: refuse to reset if working tree has uncommitted changes
    elif ! as_user git -C . diff --quiet 2>/dev/null || \
       ! as_user git -C . diff --cached --quiet 2>/dev/null || \
       [ -n "$(as_user git -C . ls-files --others --exclude-standard 2>/dev/null)" ]; then
        echo ""
        echo "  WARNING: Working tree has uncommitted changes."
        echo "  Skipping local reset to avoid data loss."
        echo "  Run manually when ready:"
        echo "    git fetch origin && git reset --hard origin/$base_branch"
        echo ""
    else
        as_user git -C . fetch origin
        as_user git -C . reset --hard "origin/$base_branch"
        echo "  Synced local $base_branch → origin/$base_branch"
    fi
fi

exit $merge_rc
