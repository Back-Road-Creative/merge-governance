#!/usr/bin/env bash
# merge-queue.sh — ONE cross-session merge queue per repo, plus the named lease
# that stops two sessions doing the same round of work.
#
# Why a file and not a note somewhere: concurrent sessions do not see each
# other. Two of them reaching "these PRs are ready" independently produce two
# merge blocks for the same PRs, and — worse — two post-merge rebase rounds.
# Where many worktrees share one .git, concurrent rounds clobber shared branch
# refs.
#
# The lease exists because "is anybody already doing this?" has no other answer.
# Any hand-off convention records intent to START work; the session that is
# ALREADY mid-run has nothing to move, so it looks idle. Hence `lease` below is
# deliberately generic — any name, not just a repo drain — so a set of worktrees
# can be claimed the same way. See `lease acquire`.
#
# CROSS-UID, and this is the part that bites: the two sessions may run as
# different users sharing only a group (a host account and a container account,
# say). With the usual umask 0022 a file created the ordinary way is 0644 and
# the OTHER user cannot rewrite it — the queue would work for whoever created it
# and fail closed for the other. So: the state dir is setgid group-writable
# (2775), this script sets `umask 0002` for its own writes, and the lease is an
# atomically created DIRECTORY (mkdir), never an flock held across turns — an
# flock dies with the shell that took it, which is exactly when the lease still
# needs to hold. flock IS used, but only to serialize an append inside one
# command; that is safe (same kernel, same inode) and is all it is asked to do.
#
# The parent dir must NOT be sticky: with the sticky bit only the owner may
# unlink an entry, so neither user could ever release a lease the other took.
#
# Usage:
#   merge-queue.sh add <repo-slug> <PR-url-or-number> [note...]
#   merge-queue.sh list [repo-slug]
#   merge-queue.sh remove <repo-slug> <PR>
#   merge-queue.sh drain <repo-slug>        # verify + emit ONE batch line; HOLDS the lease
#   merge-queue.sh done <repo-slug>         # drop merged PRs from the queue, release the lease
#   merge-queue.sh lease acquire <name> [ttl-seconds] [label...]
#   merge-queue.sh lease release <name> [--force]
#   merge-queue.sh lease status [name]
#
# Configuration:
#   MERGE_QUEUE_DIR         state dir; must be reachable by EVERY user that
#                           shares the queue (default: /var/tmp/merge-governance)
#   MERGE_QUEUE_LEASE_TTL   default lease ttl in seconds (default: 1800)
#   MERGE_APPROVED_CMD      command `drain` emits for one PR  (default: sudo merge-approved)
#   MERGE_BATCH_CMD         command `drain` emits for several (default: sudo merge-batch)
#   GH_BIN                  the gh binary                     (default: gh)
#
# This script NEVER merges. `drain` prints the line a human runs; that is the
# whole contract (people merge, sessions do not).
set -uo pipefail
umask 0002

STATE_DIR="${MERGE_QUEUE_DIR:-/var/tmp/merge-governance}"
QUEUES="$STATE_DIR/queue"
LEASES="$STATE_DIR/leases"
DEFAULT_TTL="${MERGE_QUEUE_LEASE_TTL:-1800}"
GH_BIN="${GH_BIN:-gh}"
# The merge commands `drain` PRINTS (it never runs them). Both are configurable
# so the queue can front whatever gate a project actually installs, under
# whatever privilege escalation it uses — or none.
MERGE_APPROVED_CMD="${MERGE_APPROVED_CMD:-sudo merge-approved}"
MERGE_BATCH_CMD="${MERGE_BATCH_CMD:-sudo merge-batch}"

die() { echo "merge-queue: $*" >&2; exit 2; }

# 2775 on every level: setgid so entries inherit the group, group-writable so the
# other UID can write, never sticky so the other UID can also release.
ensure_state() {
  local d
  for d in "$STATE_DIR" "$QUEUES" "$LEASES"; do
    [ -d "$d" ] || mkdir -p "$d" || die "cannot create $d"
    chmod 2775 "$d" 2>/dev/null
  done
}

slug_file() { printf '%s' "${1//\//__}"; }

# A PR number from a bare number or a …/pull/<n> URL — the same two shapes
# merge-batch accepts, so a queued token and a merge line agree.
pr_num() {
  local raw="$1"
  if [[ "$raw" =~ /pull/([0-9]+) ]]; then printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "$raw" =~ ^[0-9]+$ ]]; then printf '%s' "$raw"
  else return 1; fi
}

now() { date +%s; }

# ---------------------------------------------------------------- queue

cmd_add() {
  local slug="${1:?repo-slug required}"; shift
  local raw="${1:?PR url or number required}"; shift
  local note="$*"
  local pr; pr="$(pr_num "$raw")" || die "not a PR number or URL: $raw"
  ensure_state
  local qf="$QUEUES/$(slug_file "$slug").tsv"
  [ -e "$qf" ] || { : >"$qf"; chmod 0664 "$qf" 2>/dev/null; }
  # Already queued? Re-adding would merge it twice in one batch line.
  if awk -F'\t' -v p="$pr" '$3==p{found=1} END{exit !found}' "$qf" 2>/dev/null; then
    echo "already queued: $slug#$pr"; return 0
  fi
  # flock serializes the append against the other session; >> alone is not
  # enough once a line can be written by two writers in the same instant.
  # The lock lives on its OWN file, never on the queue: `remove` rewrites the
  # queue through a temp file and renames, so a lock taken on the queue's inode
  # would be guarding a file nobody is writing to any more.
  ( flock 9 || die "cannot lock $qf"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(now)" "$(id -un)" "$pr" \
      "https://github.com/$slug/pull/$pr" "$note" >>"$qf"
  ) 9>>"$qf.lock" || return 1
  echo "queued: $slug#$pr${note:+ — $note}"
}

cmd_list() {
  ensure_state
  local slug="${1:-}" f
  for f in "$QUEUES"/*.tsv; do
    [ -e "$f" ] || continue
    local this="${f##*/}"; this="${this%.tsv}"; this="${this//__//}"
    [ -n "$slug" ] && [ "$this" != "$slug" ] && continue
    [ -s "$f" ] || continue
    echo "== $this =="
    awk -F'\t' '{printf "  #%-6s by %-6s %s\n", $3, $2, ($5==""?"-":$5)}' "$f"
  done
}

cmd_remove() {
  local slug="${1:?repo-slug required}" pr_raw="${2:?PR required}"
  local pr; pr="$(pr_num "$pr_raw")" || die "not a PR number or URL: $pr_raw"
  ensure_state
  local qf="$QUEUES/$(slug_file "$slug").tsv"
  [ -s "$qf" ] || { echo "queue empty: $slug"; return 0; }
  ( flock 9 || die "cannot lock $qf"
    tmp="$qf.$$"
    awk -F'\t' -v p="$pr" '$3!=p' "$qf" >"$tmp" && chmod 0664 "$tmp" 2>/dev/null && mv "$tmp" "$qf"
  ) 9>>"$qf.lock"
  echo "dequeued: $slug#$pr"
}

# ---------------------------------------------------------------- lease

lease_dir() { printf '%s/%s.d' "$LEASES" "${1//\//__}"; }

# Read a holder field without trusting the file to exist.
holder_get() { sed -n "s/^$2=//p" "$1/holder" 2>/dev/null | head -1; }

cmd_lease_acquire() {
  local name="${1:?lease name required}"; shift || true
  local ttl="${DEFAULT_TTL}"
  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then ttl="$1"; shift; fi
  local label="$*"
  ensure_state
  local d; d="$(lease_dir "$name")"

  if mkdir "$d" 2>/dev/null; then
    chmod 2775 "$d" 2>/dev/null
    { echo "user=$(id -un)"; echo "pid=$$"; echo "host=$(hostname)";
      echo "epoch=$(now)"; echo "ttl=$ttl"; echo "label=$label"; } >"$d/holder"
    chmod 0664 "$d/holder" 2>/dev/null
    echo "lease ACQUIRED: $name (ttl ${ttl}s)${label:+ — $label}"
    return 0
  fi

  # Held. Expired leases are stolen — but LOUDLY, because a session that is
  # merely slow looks identical to one that died, and silence here would
  # recreate the very collision this file exists to prevent.
  local hu he ht age
  hu="$(holder_get "$d" user)"; he="$(holder_get "$d" epoch)"; ht="$(holder_get "$d" ttl)"
  [ -n "$he" ] || he=0; [ -n "$ht" ] || ht="$DEFAULT_TTL"
  age=$(( $(now) - he ))
  if [ "$age" -gt "$ht" ]; then
    echo "lease STALE (held by ${hu:-?}, ${age}s old > ${ht}s ttl) — stealing" >&2
    rm -rf "$d" 2>/dev/null || die "cannot remove stale lease $d (cross-UID? check dir is 2775 and not sticky)"
    cmd_lease_acquire "$name" "$ttl" "$label"
    return $?
  fi
  echo "lease HELD by ${hu:-?} for ${age}s (ttl ${ht}s): $name" >&2
  [ -n "$(holder_get "$d" label)" ] && echo "  label: $(holder_get "$d" label)" >&2
  echo "  wait, or: $0 lease release $name --force" >&2
  return 3
}

cmd_lease_release() {
  local name="${1:?lease name required}" force="${2:-}"
  local d; d="$(lease_dir "$name")"
  [ -d "$d" ] || { echo "lease not held: $name"; return 0; }
  local hu; hu="$(holder_get "$d" user)"
  # Same-user release is the normal path; another user's lease needs --force so
  # a cross-UID release is always a deliberate act, never a side effect.
  if [ "$hu" != "$(id -un)" ] && [ "$force" != "--force" ]; then
    echo "lease held by $hu, not $(id -un) — pass --force to release it anyway" >&2
    return 3
  fi
  rm -rf "$d" 2>/dev/null || die "cannot remove $d"
  echo "lease released: $name"
}

cmd_lease_status() {
  ensure_state
  local want="${1:-}" d found=0
  for d in "$LEASES"/*.d; do
    [ -d "$d" ] || continue
    local n="${d##*/}"; n="${n%.d}"; n="${n//__//}"
    [ -n "$want" ] && [ "$n" != "$want" ] && continue
    found=1
    local age=$(( $(now) - $(holder_get "$d" epoch) ))
    local ttl; ttl="$(holder_get "$d" ttl)"; [ -n "$ttl" ] || ttl="$DEFAULT_TTL"
    local state="live"; [ "$age" -gt "$ttl" ] && state="STALE"
    printf '%-28s %-6s held by %-6s %ss/%ss %s\n' "$n" "$state" \
      "$(holder_get "$d" user)" "$age" "$ttl" "$(holder_get "$d" label)"
  done
  [ "$found" -eq 0 ] && echo "no leases held${want:+ for $want}"
  return 0
}

# ---------------------------------------------------------------- drain

# Ready = OPEN + MERGEABLE + every check concluded SUCCESS/SKIPPED.
# Deliberately re-asked here rather than trusted from the dashboard: state moves
# between the two, and a merge line has been emitted twice for an already-merged
# PR because only mergeStateStatus was checked and .state was not.
#
# The verdict itself lives in pr-verdict.jq — ONE definition, shared with
# pr-ready.sh, so the list the dashboard proposes and the list this drain
# re-verifies cannot drift apart.
VERDICT_JQ="${VERDICT_JQ:-$(dirname "$(readlink -f "$0")")/pr-verdict.jq}"

pr_verdict() {
  local slug="$1" pr="$2" json
  [ -r "$VERDICT_JQ" ] || die "missing $VERDICT_JQ"
  json="$("$GH_BIN" pr view "$pr" --repo "$slug" \
            --json state,mergeable,statusCheckRollup 2>/dev/null)"
  [ -n "$json" ] || { echo "ERR could not read PR"; return 0; }
  printf '%s' "$json" | jq -r "$(cat "$VERDICT_JQ") pr_verdict"
}

cmd_drain() {
  local slug="${1:?repo-slug required}"
  ensure_state
  local qf="$QUEUES/$(slug_file "$slug").tsv"
  [ -s "$qf" ] || { echo "queue empty: $slug"; return 0; }

  cmd_lease_acquire "drain-$slug" "$DEFAULT_TTL" "draining $slug merge queue" || return 3

  local ready=() prs; mapfile -t prs < <(awk -F'\t' '{print $3}' "$qf")
  local pr verdict
  for pr in "${prs[@]}"; do
    verdict="$(pr_verdict "$slug" "$pr")"
    printf '  #%-6s %s\n' "$pr" "$verdict"
    [ "${verdict%% *}" = "READY" ] && ready+=("$pr")
  done

  if [ "${#ready[@]}" -eq 0 ]; then
    echo "nothing ready to merge — lease held; run '$0 lease release drain-$slug' if you are done" >&2
    return 1
  fi
  echo
  # A batch line is only honest if the ready PRs are pairwise DISJOINT. The
  # wrapper's stale-base gate is file-overlap: once the first lands, an
  # overlapping sibling is behind-AND-overlapping and is refused (exit 5), so a
  # batch of N mutually-overlapping PRs merges exactly one and stops. A wave of
  # PRs that all edit the same handful of files is exactly this case.
  # Check it here rather than let the operator discover it at the terminal.
  if [ "${#ready[@]}" -gt 1 ]; then
    local overlap_pairs
    overlap_pairs="$("$GH_BIN" pr list --repo "$slug" --state open --limit 100 \
        --json number,files 2>/dev/null | jq -r --argjson want "$(printf '%s\n' "${ready[@]}" \
          | jq -R 'tonumber?' | jq -s -c .)" '
        def paths: [ (.files // [])[].path ];
        [ .[] | select(.number as $n | $want | index($n)) | {number, p: paths} ] as $r
        | [ $r[] as $x | $r[] | select(.number > $x.number)
            | select((($x.p - ($x.p - .p)) | length) > 0) ] | length')"
    if [ -n "$overlap_pairs" ] && [ "$overlap_pairs" -gt 0 ]; then
      echo "# ${#ready[@]} ready, but they share files ($overlap_pairs overlapping pairs) —"
      echo "# a batch would merge the first and STOP. One at a time; re-clear the rest after each."
      echo "$MERGE_APPROVED_CMD https://github.com/$slug/pull/${ready[0]} --repo $slug --wait --yes"
      return 0
    fi
  fi
  if [ "${#ready[@]}" -gt 1 ]; then
    echo "$MERGE_BATCH_CMD $slug ${ready[*]} --wait --yes"
  else
    echo "$MERGE_APPROVED_CMD https://github.com/$slug/pull/${ready[0]} --repo $slug --wait --yes"
  fi
}

cmd_done() {
  local slug="${1:?repo-slug required}"
  ensure_state
  local qf="$QUEUES/$(slug_file "$slug").tsv"
  if [ -s "$qf" ]; then
    local pr state
    while read -r pr; do
      state="$("$GH_BIN" pr view "$pr" --repo "$slug" --json state --jq .state 2>/dev/null)"
      [ "$state" = "MERGED" ] && cmd_remove "$slug" "$pr" >/dev/null && echo "  merged, dequeued: #$pr"
    done < <(awk -F'\t' '{print $3}' "$qf")
  fi
  cmd_lease_release "drain-$slug"
}

# ---------------------------------------------------------------- dispatch

case "${1:-}" in
  add)    shift; cmd_add "$@" ;;
  list)   shift; cmd_list "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  drain)  shift; cmd_drain "$@" ;;
  done)   shift; cmd_done "$@" ;;
  lease)
    shift
    case "${1:-}" in
      acquire) shift; cmd_lease_acquire "$@" ;;
      release) shift; cmd_lease_release "$@" ;;
      status)  shift; cmd_lease_status "$@" ;;
      *) die "lease: expected acquire|release|status" ;;
    esac ;;
  ""|-h|--help)
    sed -n '/^# Usage:/,/^# whole contract/p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command: $1 (try --help)" ;;
esac
