#!/usr/bin/env bash
# pr-ready.sh — a read-only merge dashboard for one GitHub repo.
#
# merge-batch's `--from-ready` mode reads a PR list off stdin, in the order
# given. This is the tool that produces that list.
#
# It NEVER merges and never writes to a repo. It prints what is ready and the
# merge lines a human runs — the same `<merge-cmd> <url> --repo <slug>` shape
# merge-batch parses off stdin, in the order printed.
#
# ORDER IS DISJOINT-FIRST, and that is the whole point of computing file sets
# here. The wrapper's stale-base gate is file-overlap only: a PR that is behind
# master but shares no file with what landed merges with NO rebase, while two
# PRs touching one file mean whichever lands second is refused. So PRs that
# overlap nobody go first and land free; the entangled ones sort last, where at
# most one rebase round follows them instead of preceding everything.
#
# Usage:
#   pr-ready.sh <repo-slug> [--yes]
#   pr-ready.sh <repo-slug> --lines        # merge lines only (pipe-friendly)
#   pr-ready.sh example-org/example-repo --lines \
#       | sudo merge-batch --from-ready example-org/example-repo --yes
#
# Configuration:
#   MERGE_APPROVED_CMD   command printed for one PR  (default: sudo merge-approved)
#   MERGE_BATCH_CMD      command printed for several (default: sudo merge-batch)
#   GH_BIN               the gh binary               (default: gh)
#   VERDICT_JQ           path to pr-verdict.jq       (default: next to this file)
set -uo pipefail

GH_BIN="${GH_BIN:-gh}"
LIB="${VERDICT_JQ:-$(dirname "$(readlink -f "$0")")/pr-verdict.jq}"
MERGE_APPROVED_CMD="${MERGE_APPROVED_CMD:-sudo merge-approved}"
MERGE_BATCH_CMD="${MERGE_BATCH_CMD:-sudo merge-batch}"

slug=""; yes_flag=""; lines_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) yes_flag=" --yes"; shift ;;
    --lines)  lines_only=1; shift ;;
    -h|--help) sed -n '/^# Usage:/,/^set /p' "$0" | sed 's/^# \{0,1\}//;$d'; exit 0 ;;
    -*) echo "pr-ready: unknown option: $1" >&2; exit 2 ;;
    *)  [ -z "$slug" ] && slug="$1" || { echo "pr-ready: unexpected argument: $1" >&2; exit 2; }
        shift ;;
  esac
done
[ -n "$slug" ] || { echo "pr-ready: missing <repo-slug>" >&2; exit 2; }
[ -r "$LIB" ] || { echo "pr-ready: missing $LIB" >&2; exit 2; }

json="$("$GH_BIN" pr list --repo "$slug" --state open --limit 100 \
        --json number,url,title,state,mergeable,statusCheckRollup,files 2>/dev/null)"
[ -n "$json" ] || { echo "pr-ready: could not list PRs for $slug" >&2; exit 1; }
[ "$(printf '%s' "$json" | jq 'length')" -gt 0 ] || { echo "no open PRs in $slug"; exit 0; }

# Intersection of two path sets, jq-style: A ∩ B is A - (A - B).
order='
  def paths: [ (.files // [])[].path ];
  [ .[] | . + {v: pr_verdict, p: paths} ] as $all
  | [ $all[] | select(.v == "READY") ] as $ready
  | $ready
  | map(. + {ov: (. as $x
        | [ $ready[] | select(.number != $x.number)
            | select(((($x.p - ($x.p - .p))) | length) > 0) ] | length)})
  | sort_by(.ov, .number)
'

if [ "$lines_only" -eq 0 ]; then
  echo "== open PRs in $slug =="
  printf '%s' "$json" | jq -r "$(cat "$LIB")"'
    .[] | "\(.number)\t\(pr_verdict[0:27])\t\(.title[0:58])"' \
    | awk -F'\t' '{printf "  #%-6s %-28s %s\n", $1, $2, $3}'
  echo
fi

ready_count="$(printf '%s' "$json" | jq -r "$(cat "$LIB") $order | length")"
if [ "$ready_count" -eq 0 ]; then
  [ "$lines_only" -eq 0 ] && echo "nothing ready to merge in $slug"
  exit 0
fi

if [ "$lines_only" -eq 0 ]; then
  echo "== ready, disjoint-first (overlap count in brackets) =="
  printf '%s' "$json" | jq -r "$(cat "$LIB") $order"' | .[] | "  #\(.number) [\(.ov)] \(.title[0:64])"'
  echo
fi

# Two output shapes, never both at once — a reader who sees a batch line AND a
# per-PR line beside it cannot tell which one to run, and running both merges
# the same PRs twice.
#   --lines : the per-PR wrapper lines merge-batch --from-ready eats off stdin.
#   default : the ONE line the operator runs for the sitting.
if [ "$lines_only" -eq 1 ]; then
  printf '%s' "$json" | jq -r "$(cat "$LIB") $order"' | .[]
    | "'"$MERGE_APPROVED_CMD"' \(.url) --repo '"$slug --wait$yes_flag"'"'
elif [ "$ready_count" -gt 1 ]; then
  nums="$(printf '%s' "$json" | jq -r "$(cat "$LIB") $order"' | map(.number|tostring) | join(" ")')"
  echo "$MERGE_BATCH_CMD $slug $nums --wait$yes_flag"
else
  url="$(printf '%s' "$json" | jq -r "$(cat "$LIB") $order"' | .[0].url')"
  echo "$MERGE_APPROVED_CMD $url --repo $slug --wait$yes_flag"
fi
