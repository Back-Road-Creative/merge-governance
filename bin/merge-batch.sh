#!/usr/bin/env bash
# merge-batch — collapse N human-gated `merge-approved` merges into ONE ordered,
# fail-stopping invocation so the manual merge gate stops being the
# serialization point. Privileged tool: it runs with the same privilege as
# `merge-approved`, which it REUSES for the actual merge — it never
# re-implements merging and never forces.
#
# Pairs with pr-ready.sh — the read-only dashboard that emits the per-PR
# `… merge-approved <url> --repo <slug>` lines this tool consumes via
# --from-ready.
#
# Usage:
#   merge-batch <repo-slug> <PR> [<PR> ...] [--yes] [--wait[=<mins>]]
#       e.g. merge-batch example-org/example-repo 1147 1148 --yes
#   merge-batch --from-ready <repo-slug> [--yes] [--wait[=<mins>]]
#       read lines carrying a `…/pull/<n>` URL on stdin and extract the PR list
#       (in the order given), e.g. as one pipe:
#         pr-ready.sh example-org/example-repo --lines \
#           | sudo merge-batch --from-ready example-org/example-repo --yes
#
# Safety contract (the whole point — green-or-STOP, never force):
#   For each PR, in the order given (the order IS the merge order; the caller
#   sequences dependent PRs):
#     1. Re-verify NOW (state may have changed since the dashboard ran):
#          - `gh pr view`  state must be OPEN  (an already-MERGED PR is treated as
#            success — skip and continue, so a re-run after a partial batch resumes
#            cleanly). A DIRTY (conflicting) merge state stops the batch.
#          - `gh pr checks` must have NO failing and NO pending check.
#     2. If green => merge via the existing approved path:
#          merge-approved <PR-url> --repo <slug> [--yes]
#     3. If NOT green (closed / conflict / failed / merge error) => STOP the batch
#        immediately, print which PR blocked and why, list the remaining un-merged
#        PRs, and exit non-zero. Never skip-and-continue (a later PR may depend on
#        the blocked one).
#     4. After a successful merge, re-fetch the base branch so the next PR's
#        mergeability is evaluated against the new tip, then continue.
#   NEVER --force, NEVER --admin, NEVER override a failing check.
#
# --wait: PENDING is the one non-green verdict that resolves by
#   itself, and stopping the drain on it just hands the operator a command line
#   that cannot succeed yet — so they re-run it until it does. With --wait a
#   PENDING PR is POLLED and then RE-VERDICTED (state, mergeability and checks
#   all re-read), instead of stopping the drain. FAIL and DIRTY still stop it:
#   green-or-STOP is preserved for every outcome that will not fix itself.
#   The budget is ONE deadline SHARED by the whole drain (default 60m), not
#   per-PR — N pending PRs must not multiply the wall time. What is LEFT of that
#   shared budget is forwarded to the wrapper as --wait=<mins>, so the wrapper's
#   run-level gate (jobs not yet registered as checks are invisible to
#   `gh pr checks`) can wait too without escaping the batch's single deadline;
#   the minute-granularity floor means it may overshoot by at most 60s.
#
# Final summary (always): MERGED, and on a stop also STOPPED-AT + REMAINING.
#
# Configuration. The binaries double as the offline test harness's injection
# seams, and default to the real thing in production:
#   GH_BIN                       - the gh binary   (default: gh)
#   GIT_BIN                      - the git binary  (default: git)
#   MERGE_APPROVED_BIN           - the merge gate  (default: merge-approved)
#   GH_MERGE_BATCH_REPO_DIR      - one checkout dir, used for whatever slug runs
#   GH_MERGE_BATCH_REPO_MAP      - space-separated `owner/repo=/path` pairs
#   GH_MERGE_BATCH_REPO_MAP_FILE - file of `owner/repo /path` lines, '#' comments
#                                  (default: $XDG_CONFIG_HOME/merge-governance/repo-map)
#   GH_MERGE_POLL_SECS           - --wait poll interval, seconds  (default: 75)
#   GH_MERGE_WAIT_SECS           - override the whole shared --wait budget, in seconds
#
# There are NO built-in repo mappings. An unmapped slug WARNs loudly on stderr
# and skips the between-merge refetch; it never merges anything less carefully.
set -uo pipefail

GH_BIN="${GH_BIN:-gh}"
MERGE_APPROVED_BIN="${MERGE_APPROVED_BIN:-merge-approved}"
GIT_BIN="${GIT_BIN:-git}"
GH_MERGE_POLL_SECS="${GH_MERGE_POLL_SECS:-75}"

# Read-only gh lookups must use the INVOKING user's gh auth. This tool is run
# under sudo (the privileged-merge path), so a bare `gh` runs as root, which has
# no gh credentials -> every `gh pr view/checks` returns empty and the batch
# wrongly STOPS with state=ERR. When running as root with a known $SUDO_USER,
# drop back to that user (with their HOME, so gh finds its config) for all
# read-only queries. The actual merge still goes through merge-approved, which
# handles its own privilege.
#
# git gets the same drop: a root-run fetch dies on git's dubious-ownership check
# or writes root-owned objects into the shared .git.
if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" ]]; then
  gh_q()  { sudo -H -u "$SUDO_USER" "$GH_BIN" "$@"; }
  git_q() { sudo -H -u "$SUDO_USER" "$GIT_BIN" "$@"; }
else
  gh_q()  { "$GH_BIN" "$@"; }
  git_q() { "$GIT_BIN" "$@"; }
fi

usage() {
  cat <<'EOF'
Usage:
  merge-batch <repo-slug> <PR> [<PR> ...] [--yes] [--wait[=<mins>]]
  merge-batch --from-ready <repo-slug> [--yes] [--wait[=<mins>]]   # PR list parsed from PR URLs on stdin

Flags:
  --yes, -y          forward --yes to the merge gate (no per-PR interactive prompt)
  --wait[=<mins>]    a PENDING PR waits and is re-verdicted instead of stopping the
                     drain; ONE deadline (default 60 minutes) is shared by the whole
                     batch. FAIL / DIRTY still stop it.
  -h, --help         show this help

Merges the given PRs in order: green-or-STOP, never forces. Reuses merge-approved.
EOF
}

# Extract a PR number from a bare number or a …/pull/<n> URL. Echoes the number;
# returns non-zero if the token is neither.
pr_num() {
  local raw="$1"
  if [[ "$raw" =~ /pull/([0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "$raw" =~ ^[0-9]+$ ]]; then
    printf '%s' "$raw"
  else
    return 1
  fi
}

# Repo checkout dir for the between-merge base refetch. This CANNOT be guessed:
# a repo's checkout directory need not match its slug tail — a service can sit
# several levels inside a larger tree under a different name — and an earlier
# version that guessed `$WORKDIR/<slug-tail>` silently refetched nothing in
# exactly those cases. So it is configuration, in three forms, first match wins:
#
#   GH_MERGE_BATCH_REPO_DIR       one dir, applied to whatever slug is running
#   GH_MERGE_BATCH_REPO_MAP       "owner/a=/path/a owner/b=/path/b"  (no spaces in paths)
#   GH_MERGE_BATCH_REPO_MAP_FILE  lines of "owner/repo /path"; '#' comments, blanks ok
#
# The file defaults to $XDG_CONFIG_HOME/merge-governance/repo-map (or
# ~/.config/…). Under sudo that resolves against ROOT's home, so set the
# variable explicitly if the map lives in a human's home directory.
#
# Returns non-zero for an unmapped slug — the caller WARNs and skips the
# refetch, never silently.
repo_dir_for_slug() {
  local slug="$1" pair key val mapfile_path

  if [[ -n "${GH_MERGE_BATCH_REPO_DIR:-}" ]]; then
    printf '%s' "$GH_MERGE_BATCH_REPO_DIR"
    return 0
  fi

  # Deliberately unquoted: the map is whitespace-separated pairs.
  for pair in ${GH_MERGE_BATCH_REPO_MAP:-}; do
    [[ "$pair" == *=* ]] || continue
    key="${pair%%=*}"; val="${pair#*=}"
    if [[ "$key" == "$slug" && -n "$val" ]]; then
      printf '%s' "$val"
      return 0
    fi
  done

  mapfile_path="${GH_MERGE_BATCH_REPO_MAP_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/merge-governance/repo-map}"
  if [[ -r "$mapfile_path" ]]; then
    while read -r key val _; do
      [[ -z "$key" || "$key" == \#* ]] && continue
      if [[ "$key" == "$slug" && -n "$val" ]]; then
        printf '%s' "$val"
        return 0
      fi
    done <"$mapfile_path"
  fi

  return 1
}

# Verdict for a PR's CI checks: echoes PASS|PENDING|FAIL.
# A failing check => FAIL; else a pending check => PENDING; else (incl. zero
# checks reported) => PASS, matching the spec's "every check pass (no pending,
# no fail)". `gh pr checks` exits non-zero on pending/failed checks, so its
# output is captured with `|| true` to not abort under pipefail.
checks_verdict() {
  local pr="$1" slug="$2" out _name state _rest has_fail=0 has_pending=0
  out="$(gh_q pr checks "$pr" --repo "$slug" 2>/dev/null || true)"
  while IFS=$'\t' read -r _name state _rest; do
    [[ -z "$state" ]] && continue
    case "$state" in
      pass|success|successful|neutral|skipping|skipped) ;;
      pending|queued|in_progress|waiting|expected) has_pending=1 ;;
      *) has_fail=1 ;;
    esac
  done <<<"$out"
  if [[ "$has_fail" -eq 1 ]]; then echo FAIL; return; fi
  if [[ "$has_pending" -eq 1 ]]; then echo PENDING; return; fi
  echo PASS
}

main() {
  local slug="" from_ready=0 yes_flag=0 wait_enabled=0 wait_mins=60
  local -a raw_prs=()

  # Real flag parsing: flags are accepted ANYWHERE (before, between, after
  # positionals); unknown flags exit 2. First positional is the slug, the rest
  # are PR numbers/URLs.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage; exit 0 ;;
      --yes|-y)
        yes_flag=1; shift ;;
      --wait)
        # Bare --wait means 60 minutes. Unlike the wrapper, the batch never
        # consumes a following bare number as the budget: here bare numbers are
        # PR arguments, so `--wait 1147` must stay "wait 60m, merge #1147".
        # A non-default budget is written `--wait=<mins>`.
        wait_enabled=1; wait_mins=60; shift ;;
      --wait=*)
        wait_enabled=1; wait_mins="${1#*=}"; shift ;;
      --from-ready)
        if [[ -n "$slug" ]]; then
          echo "merge-batch: --from-ready conflicts with a positional <repo-slug>" >&2
          usage >&2; exit 2
        fi
        if [[ -z "${2:-}" ]]; then
          echo "merge-batch: --from-ready needs a <repo-slug>" >&2; usage >&2; exit 2
        fi
        from_ready=1; slug="$2"; shift 2 ;;
      -*)
        echo "merge-batch: unknown option: $1" >&2; usage >&2; exit 2 ;;
      *)
        if [[ "$from_ready" -eq 0 && -z "$slug" ]]; then
          slug="$1"
        else
          raw_prs+=("$1")
        fi
        shift ;;
    esac
  done

  if [[ -z "$slug" ]]; then
    echo "merge-batch: missing <repo-slug>" >&2; usage >&2; exit 2
  fi

  if [[ "$wait_enabled" -eq 1 ]]; then
    if ! [[ "$wait_mins" =~ ^[0-9]+$ ]] || [[ "$wait_mins" -lt 1 ]]; then
      echo "merge-batch: --wait needs a positive whole number of minutes (got '$wait_mins')" >&2
      exit 2
    fi
  fi

  if [[ "$from_ready" -eq 1 ]]; then
    if [[ "${#raw_prs[@]}" -gt 0 ]]; then
      echo "merge-batch: --from-ready reads PRs from stdin; unexpected arguments: ${raw_prs[*]}" >&2
      usage >&2; exit 2
    fi
    # Parse PR numbers off stdin, in order: any line carrying a `…/pull/<n>`
    # URL. Matching the URL rather than the name of whatever tool printed it
    # keeps this usable with any dashboard, and non-PR chatter has no /pull/ in
    # it. A line with several PR URLs contributes only its first.
    local line
    while IFS= read -r line; do
      if [[ "$line" =~ /pull/([0-9]+) ]]; then
        raw_prs+=("${BASH_REMATCH[1]}")
      fi
    done
  fi

  if [[ "${#raw_prs[@]}" -eq 0 ]]; then
    echo "merge-batch: no PRs to merge" >&2; usage >&2; exit 2
  fi

  # Normalize every token to a PR number, preserving order.
  local -a prs=()
  local r n
  for r in "${raw_prs[@]}"; do
    if ! n="$(pr_num "$r")"; then
      echo "merge-batch: not a PR number or URL: $r" >&2; exit 2
    fi
    prs+=("$n")
  done

  # Resolve the checkout dir for the between-merge base refetch. An unmapped
  # slug is NOT fatal (the refetch is an optimization, the merge path doesn't
  # need it) but it must never be silent.
  local repo_dir=""
  if ! repo_dir="$(repo_dir_for_slug "$slug")"; then
    repo_dir=""
    echo "merge-batch: WARN: no repo-dir mapping for slug '$slug' — the between-merge base refetch will be SKIPPED. Set GH_MERGE_BATCH_REPO_DIR=<checkout-dir> to enable it." >&2
  fi

  # ONE deadline for the whole drain. Per-PR budgets would multiply the wall
  # time by the number of pending PRs, which is the opposite of the point.
  local wait_secs=$(( wait_mins * 60 ))
  local wait_label="${wait_mins}m"
  if [[ -n "${GH_MERGE_WAIT_SECS:-}" ]]; then
    wait_secs="$GH_MERGE_WAIT_SECS"; wait_label="${wait_secs}s"
  fi
  local deadline_epoch=0
  if [[ "$wait_enabled" -eq 1 ]]; then
    deadline_epoch=$(( $(date +%s) + wait_secs ))
    echo "merge-batch: --wait budget ${wait_label} SHARED across ${#prs[@]} PR(s) — one deadline for the whole drain"
  fi

  local -a merged=()
  local -a wrapper_args=()
  local stopped_at="" stop_reason=""
  local i pr state mss verdict base skip_pr now left

  for i in "${!prs[@]}"; do
    pr="${prs[$i]}"

    # Re-verify NOW. Under --wait a PENDING verdict re-enters this loop after a
    # poll and EVERYTHING is re-read (state, mergeability, checks) — a PR can go
    # DIRTY or red while we wait, and a stale verdict must never be carried
    # forward into the merge.
    skip_pr=0
    while true; do
      state="$(gh_q pr view "$pr" --repo "$slug" --json state -q .state 2>/dev/null || echo ERR)"
      case "$state" in
        MERGED)
          # Idempotent-ish: already landed => success, keep going.
          echo "skip  #$pr (already MERGED)"
          merged+=("$pr")
          skip_pr=1
          break ;;
        OPEN) ;;
        *)
          stopped_at="$pr"; stop_reason="state=$state"; break 2 ;;
      esac

      mss="$(gh_q pr view "$pr" --repo "$slug" --json mergeStateStatus -q .mergeStateStatus 2>/dev/null || echo UNKNOWN)"
      if [[ "$mss" == "DIRTY" ]]; then
        stopped_at="$pr"; stop_reason="merge conflict (mergeStateStatus=DIRTY)"; break 2
      fi

      verdict="$(checks_verdict "$pr" "$slug")"
      [[ "$verdict" == "PASS" ]] && break

      # FAIL never resolves itself: green-or-STOP still applies, --wait or not.
      if [[ "$verdict" != "PENDING" || "$wait_enabled" -ne 1 ]]; then
        stopped_at="$pr"; stop_reason="checks $verdict"; break 2
      fi

      now="$(date +%s)"
      if (( now >= deadline_epoch )); then
        stopped_at="$pr"
        stop_reason="checks PENDING at the shared --wait deadline (${wait_label})"
        break 2
      fi
      echo "wait  #$pr — checks PENDING ($(( deadline_epoch - now ))s left of the shared ${wait_label} budget)"
      sleep "$GH_MERGE_POLL_SECS"
    done
    [[ "$skip_pr" -eq 1 ]] && continue

    # Green NOW => merge via the existing approved path (reuse, never
    # re-implement). --yes is forwarded so a non-interactive batch doesn't
    # dead-end at the wrapper's confirmation prompt.
    wrapper_args=("https://github.com/$slug/pull/$pr" --repo "$slug")
    if [[ "$yes_flag" -eq 1 ]]; then
      wrapper_args+=(--yes)
    fi
    if [[ "$wait_enabled" -eq 1 ]]; then
      # The wrapper gates at the RUN level too, and a job not yet registered as
      # a check is invisible to `gh pr checks` above — so a PR that reads green
      # here can still be undecided there. Hand it what is LEFT of the SHARED
      # budget (minimum 1m, the wrapper's granularity) rather than letting it
      # open a second, independent 60m wait.
      left=$(( deadline_epoch - $(date +%s) ))
      (( left < 60 )) && left=60
      wrapper_args+=("--wait=$(( (left + 59) / 60 ))")
    fi
    if ! "$MERGE_APPROVED_BIN" "${wrapper_args[@]}"; then
      stopped_at="$pr"; stop_reason="merge failed"; break
    fi
    echo "merged #$pr"
    merged+=("$pr")

    # Re-fetch the base so the next PR is evaluated against the new tip.
    # Runs as $SUDO_USER (git_q), errors surface as WARN — a failed refetch
    # only staleness-es the next evaluation, so the batch continues.
    base="$(gh_q pr view "$pr" --repo "$slug" --json baseRefName -q .baseRefName 2>/dev/null || echo "")"
    if [[ -n "$base" && -n "$repo_dir" ]]; then
      if ! git_q -C "$repo_dir" fetch origin "$base" --quiet; then
        echo "merge-batch: WARN: base refetch failed ($repo_dir, origin/$base) — continuing; the next PR's mergeability is evaluated against a possibly stale tip" >&2
      fi
    fi
  done

  echo
  echo "MERGED: ${merged[*]:-(none)}"
  if [[ -n "$stopped_at" ]]; then
    # Remaining = the stopped PR plus everything after it (all still un-merged).
    local -a remaining=()
    local j
    for j in "${!prs[@]}"; do
      (( j >= i )) && remaining+=("${prs[$j]}")
    done
    echo "STOPPED-AT: $stopped_at ($stop_reason)"
    echo "REMAINING: ${remaining[*]:-(none)}"
    exit 1
  fi
  echo "REMAINING: (none)"
  exit 0
}

main "$@"
