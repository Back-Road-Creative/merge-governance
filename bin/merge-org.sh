#!/usr/bin/env bash
# merge-org.sh — merge a PR in ONE fixed GitHub org without typing the org.
# Usage: sudo merge-org <pr_number> [repo_name] [--yes] [--force] [--squash|--merge|--rebase]
#
# Configuration:
#   MERGE_ORG            the GitHub org/owner (REQUIRED — there is no default)
#   MERGE_APPROVED_BIN   the gate to delegate to (default: merge-approved, from PATH)
#   MERGE_RUN_AS         user whose git/gh credentials to use under sudo
#                        (default: $SUDO_USER)
#
# THIN WRAPPER BY DESIGN. This script does no gating of its own: it resolves the
# repo name and delegates to merge-approved, which owns the CI gates (red CI,
# pending checks, incomplete workflow runs, zero Actions runs, stale base with
# file overlap). One gate implementation, one place to fix.
#
# The convenience is also the hazard, and that is why the delegation is the
# whole body. An earlier version of this shape ran `gh pr merge … --squash
# --delete-branch` directly, with no CI check of any kind — it merged whether CI
# was red, still running, or had never started. Worse: because the repo name
# defaults to the basename of the current checkout's origin URL, running it from
# the wrong directory silently targeted a DIFFERENT repo, bypassing every gate
# on the repo those gates exist to protect. It also mishandled --yes (taking it
# as a positional repo name in some argument orders) and skipped the gate's
# post-merge resync and ownership fix. A tool that can guess the wrong repo must
# never also be the tool that decides whether to merge.
set -euo pipefail

MERGE_APPROVED_BIN="${MERGE_APPROVED_BIN:-merge-approved}"
ORG="${MERGE_ORG:-}"

if [[ -z "$ORG" ]]; then
    echo "" >&2
    echo "  ERROR: MERGE_ORG is not set." >&2
    echo "  This wrapper only exists to save typing one fixed org. Set it:" >&2
    echo "    export MERGE_ORG=your-org" >&2
    echo "  Or call the gate directly: sudo $MERGE_APPROVED_BIN <pr> --repo owner/repo" >&2
    echo "" >&2
    exit 1
fi

PR="${1:?Usage: merge-org <pr_number> [repo_name] [--yes] [--force]}"
shift

# Optional positional repo name: present only when the next argument is not a flag.
REPO=""
if [[ $# -gt 0 && "$1" != -* ]]; then
    REPO="$1"
    shift
fi

# Under sudo a bare `git` runs as root, which trips git's dubious-ownership
# check on someone else's checkout. Drop back to the invoking user for the
# read-only lookup.
RUN_AS="${MERGE_RUN_AS:-${SUDO_USER:-}}"
as_user() {
    if [[ $EUID -eq 0 && -n "$RUN_AS" ]]; then
        sudo -u "$RUN_AS" "$@"
    else
        "$@"
    fi
}

# Fall back to the basename of the current checkout's origin URL.
if [[ -z "$REPO" ]]; then
    REPO=$(as_user git -C "$(pwd)" remote get-url origin 2>/dev/null \
        | sed 's|.*/||; s|\.git$||') || true
fi

if [[ -z "$REPO" ]]; then
    echo "" >&2
    echo "  ERROR: could not determine the repo name." >&2
    echo "  Pass it explicitly: sudo merge-org <pr_number> <repo_name> --yes" >&2
    echo "" >&2
    exit 1
fi

# Delegate. merge-approved re-checks EUID, sources its own token, applies every
# gate, defaults to --squash --delete-branch, and resyncs the local base branch.
exec "$MERGE_APPROVED_BIN" "$PR" --repo "${ORG}/${REPO}" "$@"
