# merge-governance

A set of shell tools that put one honest gate in front of `gh pr merge`, and let
one person drain a queue of ready pull requests without becoming the bottleneck.

They exist because of a gap that is easy to miss: on a private repository on
GitHub's free plan, branch protection is not enforced — the REST protection
endpoint answers `403 Upgrade to GitHub Pro` — so there is no such thing as a
required check, and nothing on the platform side refuses a merge over red CI.
On plans where protection *is* available, it still cannot see the two failures
these tools were written for: a suite that has not finished, and a base branch
that moved after CI ran.

Nothing here merges on its own. The gate merges only the PR a human names on the
command line; every other tool either refuses, or prints the command a human runs.
The one way past a failing check is `--force`, which is explicit, per-invocation,
and writes a log line before it acts — an override you can audit, not a bypass.

## What is in the box

| file | what it does |
|---|---|
| `bin/merge-approved.sh` | the gate. Merges ONE PR after five checks pass, and refuses with a specific exit code otherwise |
| `bin/merge-batch.sh` | merges a list of PRs in order, green-or-STOP; reuses the gate rather than re-implementing it |
| `bin/merge-queue.sh` | a cross-session merge queue per repo, plus a named lease so two sessions cannot start the same round of work |
| `bin/pr-ready.sh` | read-only dashboard: what is ready, ordered so the least entangled PRs merge first |
| `bin/pr-verdict.jq` | the single shared definition of "ready" that the dashboard and the queue both use |
| `bin/merge-org.sh` | optional convenience: merge by PR number inside one fixed org |
| `bin/install-merge-approved.sh` | installs the gate, refusing a source that is stale or truncated |
| `policy/contract.v1.json` | the machine-readable policy contract `merge-approved.sh` enforces |
| `tests/test-merge-batch.sh` | offline harness — 139 assertions over the batch tool, the gate, and the policy contract, no network and no real `gh` |

## The five gates

`merge-approved.sh` runs all of them from one function, so `--wait` can re-run
the whole set from scratch rather than merging on a verdict it computed an hour
earlier.

1. **Identity resolution.** Repo and head SHA must resolve. A transient API
   error used to skip the two gates that need them; it now refuses instead.
2. **Red CI.** Both rollup shapes — check runs and legacy commit statuses.
   `CANCELLED`, `ACTION_REQUIRED` and `STALE` count as red: a cancelled suite
   reports `status=COMPLETED`, so a conclusion-only test reads it as green.
3. **Unfinished CI**, at two levels. A pending *check* is obvious. The harder
   case is a job that does not exist yet: a matrix job gated behind `needs:` is
   not registered as a check until its dependency finishes, so for a moment the
   rollup reads fully complete while the suite has barely started. The workflow
   *run* status closes that window. Zero Actions runs for the head commit is
   also a refusal, not a pass — a PR that breaks the workflow file looks exactly
   like this.
4. **No checks at all.** Silence is not success.
5. **Stale base with file overlap.** Green CI proves the PR worked against the
   base it was *tested* on, not the base it will *land* on. A blanket "refuse if
   behind" fires on nearly every PR and only trains people to pass `--force`, so
   this refuses on the narrow case with real signal: the base branch changed a
   file this PR also changes. Behind but disjoint is reported and allowed. A
   failed compare call, or a base that moved 300+ files (where the compare API
   truncates), counts as *overlap unknown* and refuses.

Exit codes: `1` usage or abort, `2` CI red, `3` CI pending or `--wait` deadline
expired, `4` no CI runs or checks, `5` stale base with overlap, `6` gates
unevaluable — including a PR whose base branch cannot be read. `--force` overrides
any gate except the base-branch lookup, and writes a log line first.

## Policy contract

`merge-approved.sh` enforces **policy contract v1** (`MERGE_POLICY_VERSION=1` in
the script). The same contract is stated machine-readably in
[`policy/contract.v1.json`](policy/contract.v1.json), and the test harness fails
if the script, that file and the exit-code line above disagree.

What v1 enforces, for one PR that a human names:

- The PR's base branch is **read from the PR**, never defaulted. If the lookup
  fails, or the PR reports an empty or null base, the gate exits `6` with a
  read-only diagnostic and merges nothing. `--force` does not apply: it skips a
  failed gate, it cannot supply the branch the gates are defined against.
  `master`, `main`, `staging` or any other real base follows the same checks.
- The five gates above, with the exit codes above.

What v1 does **not** provide. This snapshot does not enforce any of these, and
nothing here should be read as claiming it does:

- branch protection or required status checks (a host feature; see the top of
  this file);
- an allowlist of permitted base branches;
- staging-branch proofs or release promotion;
- any private workspace's own merge policy or review authority. A workspace that
  needs those controls has to supply them around this tool.

A change to what a gate or exit code means bumps the version and adds a new
`policy/contract.v<N>.json`; v1 is never edited to describe different behavior.

## `--wait`

Every gate above refuses a pending suite, so a command pasted the moment a PR is
pushed *cannot* succeed yet, and the operator ends up as the polling loop.
`--wait` defers only outcomes that are **not yet decided** — checks pending,
runs in flight, no run registered yet. A decided bad outcome still stops
immediately. When the wait ends, every gate re-runs against a freshly resolved
head SHA, and the merge is pinned to that SHA with `--match-head-commit`. A
force-push mid-wait moves the head and kills the run being watched, so the wait
notices and restarts against the new head.

`merge-batch.sh` shares ONE deadline across the whole drain — a per-PR budget
would multiply the wall time by the number of pending PRs — and forwards what is
left of it to the gate.

## Ordering: why disjoint-first

Because gate 5 is file-overlap-scoped, a PR that is behind but touches nothing
the base touched merges with no rebase. Two PRs that touch one shared file mean
whichever lands second is refused. So `pr-ready.sh` sorts PRs that overlap
nobody first — they land free — and the entangled ones last, where at most one
rebase round follows them instead of preceding everything.

When *every* ready PR overlaps every other, a batch line would merge exactly one
PR and stop. `merge-queue.sh drain` detects that up front and prints a single-PR
line with an explanation, rather than letting you discover it at the terminal.

## The queue and the lease

Concurrent sessions do not see each other. Two of them reaching "these PRs are
ready" produce two merge blocks for the same PRs, and two post-merge rebase
rounds. `merge-queue.sh` gives them one queue file per repo and one named lease.

The lease is deliberately generic — it takes any name, not just a repo drain —
because the same problem shows up for a set of worktrees. Any hand-off
convention records intent to *start* work; a session already mid-run has nothing
to move and therefore looks idle. Claim a name before you touch shared state:

```bash
merge-queue.sh lease acquire my-worktree-set 1800 "what I am doing"   # exit 3 = held
```

Two details it gets right because getting them wrong fails closed: the lease is
an atomically created *directory*, never an `flock` held across turns (an
`flock` dies with the shell that took it, which is exactly when the lease still
needs to hold), and the state directory is setgid group-writable and *not*
sticky, so a lease taken by one user can be released by another sharing the
group.

## Requirements

`bash` 4+, the [`gh`](https://cli.github.com) CLI authenticated as a human,
`jq`, and `flock` (util-linux) for the queue. The gate installs as a root-owned
binary and is invoked with `sudo`; it drops back to the invoking user for every
credentialed read and every local `git` call.

## Install

```bash
sudo bash bin/install-merge-approved.sh            # → /usr/local/bin/merge-approved
sudo install -m 755 bin/merge-batch.sh /usr/local/bin/merge-batch
install -m 755 bin/merge-queue.sh bin/pr-ready.sh ~/.local/bin/
install -m 644 bin/pr-verdict.jq ~/.local/bin/
```

`merge-queue.sh` and `pr-ready.sh` both look for `pr-verdict.jq` beside
themselves and hard-fail without it — keep the three together, or point
`VERDICT_JQ` at it.

The installer is not ceremony. A merge gate is the last file you want a stale
copy of, and `cp` cannot tell: it checks that the source is valid bash and
contains the markers a working gate must have, and refuses a large shrink
without `--allow-downgrade`.

## Configuration

Nothing about anyone's directory layout is baked in. All of it is environment.

| variable | used by | meaning |
|---|---|---|
| `MERGE_APPROVED_BIN` | batch, org | the gate to invoke (default `merge-approved`) |
| `MERGE_APPROVED_CMD` / `MERGE_BATCH_CMD` | queue, dashboard | the command lines they *print* (default `sudo merge-approved` / `sudo merge-batch`) |
| `MERGE_APPROVED_TARGET` | installer | install path (or `--to`) |
| `MERGE_APPROVED_LOG` | gate | where `--force` overrides are recorded; falls back to syslog |
| `MERGE_RUN_AS` | gate, org | account whose `gh`/`git` credentials to use under sudo (default `$SUDO_USER`) |
| `MERGE_ORG` | org | the one org `merge-org.sh` prefixes; required, no default |
| `MERGE_QUEUE_DIR` | queue | state dir, reachable by every user sharing the queue (default `/var/tmp/merge-governance`) |
| `MERGE_QUEUE_LEASE_TTL` | queue | default lease ttl in seconds (default 1800) |
| `GH_MERGE_BATCH_REPO_DIR` | batch | one checkout dir for the between-merge base refetch |
| `GH_MERGE_BATCH_REPO_MAP` | batch | `owner/repo=/path` pairs, whitespace separated |
| `GH_MERGE_BATCH_REPO_MAP_FILE` | batch | file of `owner/repo /path` lines (default `$XDG_CONFIG_HOME/merge-governance/repo-map`) |
| `GH_BIN` / `GIT_BIN` | all | binaries to call; also the test harness's injection seams |
| `GH_MERGE_POLL_SECS` / `GH_MERGE_WAIT_SECS` | gate, batch | poll interval and total `--wait` budget |
| `VERDICT_JQ` | queue, dashboard | path to `pr-verdict.jq` |

There is no built-in repo map. After a successful merge the batch tool refetches
the base branch so the next PR is evaluated against the new tip, and it needs a
local checkout to do that — which cannot be guessed, because a repo's directory
need not match its slug. An unmapped slug WARNs loudly and skips the refetch; it
never merges anything less carefully.

```bash
# $XDG_CONFIG_HOME/merge-governance/repo-map
example-org/example-repo   /srv/checkouts/example-repo
example-org/service-a      /srv/checkouts/monorepo/services/a
```

Under `sudo`, `$HOME` is root's, so set `GH_MERGE_BATCH_REPO_MAP_FILE`
explicitly if the map lives in a human's home directory.

## Usage

```bash
# one PR, gated
sudo merge-approved 1147 --repo example-org/example-repo --wait --yes

# several, in order, stopping at the first that is not green
sudo merge-batch example-org/example-repo 1147 1148 1149 --wait --yes

# what is ready right now, least-entangled first
pr-ready.sh example-org/example-repo

# or pipe the dashboard straight in
pr-ready.sh example-org/example-repo --lines \
  | sudo merge-batch --from-ready example-org/example-repo --yes

# queue PRs as they become ready, drain them in one sitting
merge-queue.sh add example-org/example-repo 1147 "config split"
merge-queue.sh drain example-org/example-repo      # prints ONE line; holds a lease
merge-queue.sh done example-org/example-repo       # dequeue merged, release the lease
```

## Tests

```bash
bash tests/test-merge-batch.sh
```

Offline and hermetic: no network, no real `gh` or `git`, no `sudo`. Everything
runs through the injection seams to fakes in a temp dir. Waiting is made fast
rather than stubbed out — the poll interval drops to 0.2s and the budget to a
couple of seconds, so the real loop runs, including a scripted force-push
mid-wait. 139 assertions across 35 cases.

## Licence

MIT — see [LICENSE](LICENSE).
