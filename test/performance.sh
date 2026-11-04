#!/usr/bin/env bash
# Performance and allocation regressions for git-subtree-squash-push.
#
# Usage: ./test/performance.sh
#        PERF_COMMITS=800 PERF_TAG_EVERY=20 ./test/performance.sh
#
# The suite builds a synthetic history, publishes every tag in it, and asserts
#
#   * wall-clock budgets for a full publish and for a no-op rerun,
#   * that snapshotting does not call `git subtree split`,
#   * that tag discovery does not run one `git tag` process per commit,
#   * that the number of git invocations stays proportional to the tag count
#     rather than to the commit count.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
: "${TOOL:=$HERE/../git-subtree-squash-push}"
export TOOL
# shellcheck source=test/lib.sh
source "$HERE/lib.sh"

COMMITS=${PERF_COMMITS:-300}
TAG_EVERY=${PERF_TAG_EVERY:-10}
BUILD_BUDGET=${PERF_BUILD_BUDGET:-60}
RERUN_BUDGET=${PERF_RERUN_BUDGET:-30}
# ~7 git calls per tag are expected (rev-parse/cat-file/show/commit-tree);
# the budget leaves ample headroom while still catching O(commits) behaviour.
CALL_BUDGET_PER_TAG=${PERF_CALL_BUDGET_PER_TAG:-10}
CALL_BUDGET_BASE=${PERF_CALL_BUDGET_BASE:-50}

TEST_TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gssp-perf.XXXXXX")
export TEST_TMP_ROOT
trap 'rm -rf "$TEST_TMP_ROOT"' EXIT

w=$(new_tmp perf)
repo=$w/repo
remote=$w/remote.git
init_repo "$repo"
init_remote "$remote"
mkdir -p "$repo/pkg"

info "building synthetic history: $COMMITS commits, a tag every $TAG_EVERY commits"
i=0
while (( i < COMMITS )); do
  i=$((i + 1))
  printf 'line %s\n' "$i" >>"$repo/pkg/data.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "commit $i"
  if (( i % TAG_EVERY == 0 )); then
    git -C "$repo" tag "v$i"
  fi
done
tags=$(git -C "$repo" tag | wc -l | tr -d ' ')
[[ $tags -gt 0 ]] || fail "no tags were created (PERF_COMMITS=$COMMITS, PERF_TAG_EVERY=$TAG_EVERY)"

info "full publish of $tags tags"
SECONDS=0
if ! (cd "$repo" && PATH="$HERE/bin:$PATH" REAL_GIT="$REAL_GIT" \
    GIT_CALL_LOG="$w/build.calls" "$TOOL" --prefix=pkg --squash-tags "$remote" main) \
    >"$w/build.log" 2>&1; then
  fail "publishing failed: $(tail -n 5 "$w/build.log")"
fi
build_elapsed=$SECONDS
printf '   %-34s %4ss (budget %ss)\n' 'full --squash-tags publish' "$build_elapsed" "$BUILD_BUDGET"
[[ $build_elapsed -lt $BUILD_BUDGET ]] ||
  fail "full publish took ${build_elapsed}s for $COMMITS commits / $tags tags (budget ${BUILD_BUDGET}s)"

assert_eq 'one commit per tag' "$tags" \
  "$(git --git-dir="$remote" rev-list --count main)"

info 'no-op rerun'
SECONDS=0
if ! (cd "$repo" && PATH="$HERE/bin:$PATH" REAL_GIT="$REAL_GIT" \
    GIT_CALL_LOG="$w/rerun.calls" "$TOOL" --prefix=pkg --squash-tags "$remote" main) \
    >"$w/rerun.log" 2>&1; then
  fail "no-op rerun failed: $(tail -n 5 "$w/rerun.log")"
fi
rerun_elapsed=$SECONDS
printf '   %-34s %4ss (budget %ss)\n' '--squash-tags no-op rerun' "$rerun_elapsed" "$RERUN_BUDGET"
[[ $rerun_elapsed -lt $RERUN_BUDGET ]] ||
  fail "no-op rerun took ${rerun_elapsed}s (budget ${RERUN_BUDGET}s)"
assert_contains 'rerun is a no-op' "$(cat "$w/rerun.log")" 'already up to date'

subtree_calls=$(grep -c '^subtree ' "$w/build.calls" || true)
points_at_calls=$(grep -c -- '--points-at' "$w/build.calls" || true)
total_calls=$(wc -l <"$w/build.calls" | tr -d ' ')
call_budget=$((tags * CALL_BUDGET_PER_TAG + CALL_BUDGET_BASE))

printf '   %-34s %4s\n' 'git invocations during publish' "$total_calls"
printf '   %-34s %4s\n' 'git-subtree invocations' "$subtree_calls"
printf '   %-34s %4s\n' 'per-commit git tag --points-at calls' "$points_at_calls"

[[ $subtree_calls -eq 0 ]] ||
  fail "publish invoked git subtree $subtree_calls time(s); snapshots must not need a history rewrite"
[[ $points_at_calls -eq 0 ]] ||
  fail "tag discovery ran $points_at_calls 'git tag --points-at' processes; expect a single ref listing"
[[ $total_calls -le $call_budget ]] ||
  fail "$total_calls git invocations for $COMMITS commits / $tags tags (budget $call_budget); expected O(tags), not O(commits)"

printf '\nperformance: PASS\n'
