# pr-verdict.jq — ONE definition of "is this PR ready to merge", shared by
# merge-queue.sh (drain) and pr-ready.sh (dashboard).
#
# Two definitions that agree today are the same defect with the clock reset: the
# dashboard proposes the merge list and the drain re-verifies it, so if they ever
# disagree the drain silently drops a PR the dashboard promised, or worse the
# other way. Callers concatenate this file with an entry expression, e.g.
#   jq -r "$(cat pr-verdict.jq) pr_verdict"        # one PR object
#   jq -r "$(cat pr-verdict.jq) .[] | pr_verdict"  # a list from `gh pr list`
#
# Input: a PR object carrying at least .state, .mergeable, .statusCheckRollup.
# Output: one line — READY | PENDING <checks> | BLOCK <reason> | SKIP <state>.
#
# status and conclusion are read SEPARATELY on purpose. `gh pr checks` is
# known to lie in both directions: a job gated by a failed
# predecessor prints `skipping`, which reads as still-queued, and a cancelled run
# prints `fail`, which reads as a code failure. The rollup's own pair avoids that
# display entirely — and an IN_PROGRESS job has an EMPTY conclusion, which is
# indistinguishable from "no checks" unless status is read alongside it.

def _nm: (.name // .context // "?");

def _pending: [ (.statusCheckRollup // [])[]
                | select(((.status // "COMPLETED") | ascii_upcase) != "COMPLETED")
                | _nm ];

def _bad: [ (.statusCheckRollup // [])[]
            | select(((.status // "COMPLETED") | ascii_upcase) == "COMPLETED")
            | select(((.conclusion // "") | ascii_upcase)
                     | . != "SUCCESS" and . != "SKIPPED" and . != "NEUTRAL")
            | _nm + "=" + ((.conclusion // "?") | tostring) ];

def pr_verdict:
  if (.state // "OPEN") != "OPEN" then "SKIP already " + (.state | ascii_downcase)
  elif .mergeable == "CONFLICTING" then "BLOCK conflicting"
  elif (.mergeable != null and .mergeable != "MERGEABLE")
    then "BLOCK mergeable=" + (.mergeable | tostring)
  else
    (_bad) as $bad | (_pending) as $pending
    | if ($bad | length) > 0 then "BLOCK " + ($bad[0:3] | join(", "))
      elif ($pending | length) > 0 then "PENDING " + ($pending[0:3] | join(", "))
      else "READY" end
  end;
