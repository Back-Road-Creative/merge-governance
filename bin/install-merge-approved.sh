#!/usr/bin/env bash
# Install bin/merge-approved.sh to /usr/local/bin/merge-approved, safely.
#
# Why this exists: a merge gate is the last file you want a stale copy of, and
# `cp` cannot tell. Two ways that goes wrong, both of which have happened:
#   1. cp from a "reference copy" kept elsewhere in the tree, thousands of
#      bytes behind the real thing
#   2. cp run on the line after a `git pull` that had FAILED (the tree was on a
#      feature branch, so it could not fast-forward) -- separate lines, so the
#      cp ran anyway, on the old content
#
# Both are content problems, so this checks the CONTENT rather than trusting the
# path or the exit status of whatever ran before it. It refuses to install a file
# that is missing the markers a working gate must have, and it refuses to
# install a DOWNGRADE without --allow-downgrade.
#
# Usage:
#   sudo bash bin/install-merge-approved.sh
#   sudo bash bin/install-merge-approved.sh --dry-run
#   sudo bash bin/install-merge-approved.sh --from <path>   # e.g. a worktree
#   sudo bash bin/install-merge-approved.sh --to <path>     # non-default target
#   sudo bash bin/install-merge-approved.sh --allow-downgrade
#
# MERGE_APPROVED_TARGET sets the install path when --to is not given.

set -euo pipefail

TARGET="${MERGE_APPROVED_TARGET:-/usr/local/bin/merge-approved}"
SRC=""
DRY=0
ALLOW_DOWNGRADE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)             SRC="${2:-}"; shift 2 ;;
        --to)               TARGET="${2:-}"; shift 2 ;;
        --dry-run)          DRY=1; shift ;;
        --allow-downgrade)  ALLOW_DOWNGRADE=1; shift ;;
        -h|--help)          sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -n "$TARGET" ]] || { echo "--to needs a path" >&2; exit 2; }

# Default source: the copy sitting next to this script.
if [[ -z "$SRC" ]]; then
    SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/merge-approved.sh"
fi

fail() { echo "" >&2; echo "  REFUSING: $*" >&2; echo "" >&2; exit 1; }

[[ -f "$SRC" ]] || fail "source not found: $SRC"

# --- Content gates: what a working gate must contain -----------------------
# Each marker is a capability that a past regression actually removed.
bash -n "$SRC" 2>/dev/null || fail "$SRC is not valid bash."

declare -A NEED=(
    ["--wait"]="the --wait flag callers pass to poll for green CI"
    ["gate_pending"]="the gate re-evaluation contract --wait depends on"
    ["pr_state"]="the already-merged short-circuit"
)
missing=()
for marker in "${!NEED[@]}"; do
    grep -q -- "$marker" "$SRC" || missing+=("$marker -- ${NEED[$marker]}")
done
if (( ${#missing[@]} > 0 )); then
    echo "" >&2
    echo "  REFUSING: $SRC is missing capabilities a working gate has:" >&2
    printf '    - %s\n' "${missing[@]}" >&2
    echo "" >&2
    echo "  This is what a stale source looks like. Check that you are installing" >&2
    echo "  from the branch you think you are:" >&2
    echo "    git -C \"\$(dirname \"$SRC\")\" log --oneline -1 -- \"$SRC\"" >&2
    echo "" >&2
    exit 1
fi

src_bytes="$(wc -c < "$SRC")"
cur_bytes=0
[[ -f "$TARGET" ]] && cur_bytes="$(wc -c < "$TARGET")"

if [[ -f "$TARGET" ]] && cmp -s "$SRC" "$TARGET"; then
    echo "Already installed and identical ($src_bytes bytes). Nothing to do."
    exit 0
fi

# A large shrink is the signature of both incidents. Block it by default.
if (( cur_bytes > 0 && src_bytes < cur_bytes * 8 / 10 && ALLOW_DOWNGRADE == 0 )); then
    fail "source is $src_bytes bytes, installed is $cur_bytes -- a $(( 100 - src_bytes * 100 / cur_bytes ))% shrink.
     A large shrink is what installing a stale source looks like. If this really
     is a deliberate rollback, re-run with --allow-downgrade."
fi

echo "  source:    $SRC ($src_bytes bytes)"
echo "  target:    $TARGET ($cur_bytes bytes)"
if (( DRY == 1 )); then
    echo "  --dry-run: not installing."
    exit 0
fi

if [[ $EUID -ne 0 ]]; then
    fail "needs root to write $TARGET. Re-run with sudo."
fi

if [[ -f "$TARGET" ]]; then
    backup="${TARGET}.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$TARGET" "$backup"
    echo "  backup:    $backup"
fi

install -m 755 "$SRC" "$TARGET"

# --- Post-install verification: prove it, do not assume it -----------------
cmp -s "$SRC" "$TARGET" || fail "post-install compare failed -- $TARGET does not match $SRC."
wait_hits="$(grep -c -- '--wait' "$TARGET" || true)"
echo ""
echo "  INSTALLED. $(wc -c < "$TARGET") bytes, --wait present ${wait_hits}x, matches source."
echo ""
