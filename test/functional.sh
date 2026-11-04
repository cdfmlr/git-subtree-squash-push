#!/usr/bin/env bash
# Functional tests for git-subtree-squash-push.
#
# Usage: ./test/functional.sh          (uses ../git-subtree-squash-push)
#        TOOL=/path/to/script ./test/functional.sh
#        CASE_FILTER='test_squash_mode test_branch_validation' ./test/functional.sh
#
# Every test builds a throwaway repository and a local bare "remote" under a
# temporary directory, so nothing outside the sandbox is touched.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
: "${TOOL:=$HERE/../git-subtree-squash-push}"
export TOOL
# shellcheck source=test/lib.sh
source "$HERE/lib.sh"

TEST_TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gssp-functional.XXXXXX")
export TEST_TMP_ROOT
trap 'rm -rf "$TEST_TMP_ROOT"' EXIT

# --- normal mode ------------------------------------------------------------

test_normal_mode_root() {
  local w repo remote
  w=$(new_tmp normal-root); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"

  printf 'a\n' >"$repo/a.txt"; commit_all "$repo" one
  printf 'b\n' >"$repo/b.txt"; commit_all "$repo" two

  tool_ok 'normal root push' "$repo" --prefix=. "$remote" main
  assert_eq 'remote branch is HEAD' \
    "$(git -C "$repo" rev-parse HEAD)" "$(remote_rev "$remote" main)"
  assert_eq 'full history is published' '2' \
    "$(git --git-dir="$remote" rev-list --count main)"
}

test_normal_mode_subtree() {
  local w repo remote tip
  w=$(new_tmp normal-subtree); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"

  mkdir -p "$repo/pkg"
  printf 'a\n' >"$repo/pkg/a.txt"
  printf 'outside\n' >"$repo/outside.txt"
  commit_all "$repo" one
  printf 'b\n' >>"$repo/pkg/a.txt"
  commit_all "$repo" two

  tool_ok 'normal subtree push' "$repo" --prefix=pkg "$remote" main
  tip=$(remote_rev "$remote" main)
  assert_eq 'tip publishes the subtree tree' \
    "$(git -C "$repo" rev-parse 'HEAD:pkg')" \
    "$(git --git-dir="$remote" rev-parse "$tip^{tree}")"
  assert_eq 'files outside the subtree are not published' '' \
    "$(git --git-dir="$remote" ls-tree --name-only "$tip" -- outside.txt)"
}

# --- --squash ---------------------------------------------------------------

test_squash_mode() {
  local w repo remote first
  w=$(new_tmp squash); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"

  mkdir -p "$repo/pkg"
  printf 'a\n' >"$repo/pkg/a.txt"
  printf 'outside\n' >"$repo/outside.txt"
  commit_all "$repo" one

  tool_ok 'first squashed publish' "$repo" --prefix=pkg --squash "$remote" main
  assert_eq 'a single snapshot commit' '1' \
    "$(git --git-dir="$remote" rev-list --count main)"
  first=$(remote_rev "$remote" main)
  assert_eq 'snapshot tree is the prefix tree' \
    "$(git -C "$repo" rev-parse 'HEAD:pkg')" \
    "$(git --git-dir="$remote" rev-parse "$first^{tree}")"

  tool_ok 'repeat without changes' "$repo" --prefix=pkg --squash "$remote" main
  assert_contains 'unchanged tree is a no-op' "$TOOL_OUTPUT" 'nothing to push'
  assert_eq 'remote tip is unchanged' "$first" "$(remote_rev "$remote" main)"

  printf 'b\n' >>"$repo/pkg/a.txt"
  commit_all "$repo" two
  tool_ok 'incremental squashed publish' "$repo" --prefix=pkg --squash "$remote" main
  assert_eq 'one commit is appended' '2' \
    "$(git --git-dir="$remote" rev-list --count main)"
  assert_eq 'appended commit builds on the previous tip' "$first" \
    "$(git --git-dir="$remote" rev-parse main^)"
  assert_eq 'appended commit has the new tree' \
    "$(git -C "$repo" rev-parse 'HEAD:pkg')" \
    "$(git --git-dir="$remote" rev-parse 'main^{tree}')"

  tool_ok 'forced rebuild' "$repo" --prefix=pkg --squash -f "$remote" main
  assert_eq 'forced rebuild collapses to one commit' '1' \
    "$(git --git-dir="$remote" rev-list --count main)"
}

test_commit_messages_use_git_describe() {
  local w repo remote msg hash
  w=$(new_tmp describe); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"

  mkdir -p "$repo/pkg"
  printf 'one\n' >"$repo/pkg/data.txt"; commit_all "$repo" c1

  tool_ok 'untagged snapshot' "$repo" --prefix=pkg --squash "$remote" main
  msg=$(git -C "$repo" describe --tags --always --long --abbrev=7 HEAD)
  assert_eq 'untagged snapshot falls back to --always' "$msg" \
    "$(git --git-dir="$remote" log -1 --format=%s main)"
  assert_eq 'fallback is the abbreviated commit id' \
    "$(git -C "$repo" rev-parse --short=7 HEAD)" "$msg"

  git -C "$repo" tag v1
  printf 'two\n' >>"$repo/pkg/data.txt"; commit_all "$repo" c2
  tool_ok 'tagged snapshot' "$repo" --prefix=pkg --squash "$remote" main
  msg=$(git -C "$repo" describe --tags --always --long --abbrev=7 HEAD)
  assert_eq 'tagged snapshot is named with describe' "$msg" \
    "$(git --git-dir="$remote" log -1 --format=%s main)"
  assert_eq 'describe counts commits since the tag' 'v1-1-g' "${msg:0:6}"

  # Repo-level abbreviation settings must not leak into the published name.
  git -C "$repo" config core.abbrev 12
  printf 'three\n' >>"$repo/pkg/data.txt"; commit_all "$repo" c3
  tool_ok 'snapshot with a long core.abbrev' "$repo" --prefix=pkg --squash "$remote" main
  msg=$(git -C "$repo" describe --tags --always --long --abbrev=7 HEAD)
  assert_eq 'abbrev is pinned to 7' "$msg" \
    "$(git --git-dir="$remote" log -1 --format=%s main)"
  hash=${msg##*-g}
  assert_eq 'hash part is 7 characters' '7' "${#hash}"
}

test_identity_defaults_to_keep() {
  local w repo remote fields
  w=$(new_tmp identity-keep); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"
  fields='%an|%ae|%cn|%ce'

  mkdir -p "$repo/pkg"
  printf 'one\n' >"$repo/pkg/data.txt"
  git -C "$repo" add -A
  GIT_AUTHOR_NAME='A U Thor' GIT_AUTHOR_EMAIL='author@example.com' \
  GIT_COMMITTER_NAME='C O Mitter' GIT_COMMITTER_EMAIL='committer@example.com' \
    git -C "$repo" commit -qm c1
  git -C "$repo" tag v1

  printf 'two\n' >>"$repo/pkg/data.txt"
  git -C "$repo" add -A
  GIT_AUTHOR_NAME='Second Author' GIT_AUTHOR_EMAIL='second@example.com' \
  GIT_COMMITTER_NAME='Second Committer' GIT_COMMITTER_EMAIL='second-committer@example.com' \
    git -C "$repo" commit -qm c2
  git -C "$repo" tag v2

  tool_ok 'squash keeps the HEAD identity' "$repo" --prefix=pkg --squash "$remote" keep
  assert_eq 'squash keeps the HEAD identity' \
    'Second Author|second@example.com|Second Committer|second-committer@example.com' \
    "$(git --git-dir="$remote" show -s --format="$fields" keep)"

  tool_ok 'squash-tags keeps per-tag identities' \
    "$repo" --prefix=pkg --squash-tags "$remote" tags
  assert_eq 'newest tag keeps its identity' \
    'Second Author|second@example.com|Second Committer|second-committer@example.com' \
    "$(git --git-dir="$remote" show -s --format="$fields" tags)"
  assert_eq 'older tag keeps its identity' \
    'A U Thor|author@example.com|C O Mitter|committer@example.com' \
    "$(git --git-dir="$remote" show -s --format="$fields" tags^)"
}

test_identity_current_and_fixed() {
  local w repo remote fields
  w=$(new_tmp identity-current); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"
  fields='%an|%ae|%cn|%ce'

  mkdir -p "$repo/pkg"
  printf 'one\n' >"$repo/pkg/data.txt"
  commit_all "$repo" c1

  tool_ok 'current author with fixed committer' "$repo" --prefix=pkg --squash \
    --author=current --committer='Publish Bot <bot@example.com>' "$remote" main
  assert_eq 'current uses the configured git user, fixed uses the given one' \
    'Test Author|test@example.com|Publish Bot|bot@example.com' \
    "$(git --git-dir="$remote" show -s --format="$fields" main)"

  tool_ok 'fixed, prefix is optional' "$repo" --prefix=pkg --squash \
    --committer='fixed,Other Bot <other@example.com>' "$remote" prefixed
  assert_eq 'fixed, prefix is accepted' 'Other Bot' \
    "$(git --git-dir="$remote" show -s --format=%cn prefixed)"
}

test_identity_shorthand_and_conflicts() {
  local w repo remote other fields
  w=$(new_tmp identity-shorthand); repo=$w/repo
  remote=$w/remote.git; other=$w/other.git
  init_repo "$repo"; init_remote "$remote"; init_remote "$other"
  fields='%an|%ae|%cn|%ce'

  mkdir -p "$repo/pkg"
  printf 'one\n' >"$repo/pkg/data.txt"
  commit_all "$repo" c1

  tool_ok 'identity shorthand' "$repo" --prefix=pkg --squash \
    --identity='Both Bot <both@example.com>' "$remote" main
  tool_ok 'explicit author and committer' "$repo" --prefix=pkg --squash \
    --author='Both Bot <both@example.com>' \
    --committer='Both Bot <both@example.com>' "$other" main
  assert_eq 'shorthand sets both identities' \
    'Both Bot|both@example.com|Both Bot|both@example.com' \
    "$(git --git-dir="$remote" show -s --format="$fields" main)"
  assert_eq 'shorthand matches the explicit flags' \
    "$(remote_rev "$other" main)" "$(remote_rev "$remote" main)"

  tool_fails '--identity with --author' "$repo" --prefix=pkg --squash \
    --identity='X <x@example.com>' --author=keep "$remote" bad
  assert_contains 'conflict is reported' "$TOOL_OUTPUT" 'cannot be combined'
  tool_fails '--author with --identity' "$repo" --prefix=pkg --squash \
    --author=keep --identity='X <x@example.com>' "$remote" bad
  assert_contains 'conflict is reported in any order' "$TOOL_OUTPUT" 'cannot be combined'
  tool_fails '--identity with --committer' "$repo" --prefix=pkg --squash \
    --committer=keep --identity='X <x@example.com>' "$remote" bad
  assert_contains 'committer conflict is reported' "$TOOL_OUTPUT" 'cannot be combined'
  tool_fails 'duplicate --author' "$repo" --prefix=pkg --squash \
    --author=keep --author=current "$remote" bad
  assert_contains 'duplicate option is reported' "$TOOL_OUTPUT" 'more than once'
}

test_identity_validation() {
  local w repo remote
  w=$(new_tmp identity-invalid); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"

  mkdir -p "$repo/pkg"
  printf 'one\n' >"$repo/pkg/data.txt"
  commit_all "$repo" c1

  tool_fails 'identity without an email' "$repo" --prefix=pkg --squash \
    --author='No Email' "$remote" main
  assert_contains 'bad author is reported' "$TOOL_OUTPUT" 'invalid author identity'
  tool_fails 'committer with an empty name' "$repo" --prefix=pkg --squash \
    --committer=' <only@example.com>' "$remote" main
  assert_contains 'bad committer is reported' "$TOOL_OUTPUT" 'invalid committer identity'
  tool_fails 'identity option without a value' "$repo" --prefix=pkg --squash --author
  assert_contains 'missing value is reported' "$TOOL_OUTPUT" 'requires a value'
  tool_fails 'identity in normal mode' "$repo" --prefix=pkg \
    --identity='X <x@example.com>' "$remote" main
  assert_contains 'normal mode rejects identity options' "$TOOL_OUTPUT" 'only apply to --squash'
}

test_identity_ignores_environment() {
  local w repo remote fields
  w=$(new_tmp identity-env); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"
  fields='%an|%ae|%cn|%ce'

  mkdir -p "$repo/pkg"
  printf 'one\n' >"$repo/pkg/data.txt"
  git -C "$repo" add -A
  GIT_AUTHOR_NAME='A U Thor' GIT_AUTHOR_EMAIL='author@example.com' \
  GIT_COMMITTER_NAME='C O Mitter' GIT_COMMITTER_EMAIL='committer@example.com' \
    git -C "$repo" commit -qm c1

  TOOL_OUTPUT=$(cd "$repo" && GIT_AUTHOR_NAME='Env Author' \
    GIT_AUTHOR_EMAIL='env-author@example.com' \
    GIT_COMMITTER_NAME='Env Committer' \
    GIT_COMMITTER_EMAIL='env-committer@example.com' \
    "$TOOL" --prefix=pkg --squash "$remote" main 2>&1) ||
    fail "identity options must ignore GIT_*_NAME/EMAIL: $TOOL_OUTPUT"
  assert_eq 'environment identity does not leak' \
    'A U Thor|author@example.com|C O Mitter|committer@example.com' \
    "$(git --git-dir="$remote" show -s --format="$fields" main)"
}

test_dates_default_to_keep() {
  local w repo remote fields
  w=$(new_tmp dates-keep); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"
  fields='%aI|%cI'

  mkdir -p "$repo/pkg"
  printf 'one\n' >"$repo/pkg/data.txt"
  git -C "$repo" add -A
  GIT_AUTHOR_DATE='2001-02-03T04:05:06+08:00' \
  GIT_COMMITTER_DATE='2002-03-04T05:06:07+08:00' \
    git -C "$repo" commit -qm c1
  git -C "$repo" tag v1

  printf 'two\n' >>"$repo/pkg/data.txt"
  git -C "$repo" add -A
  GIT_AUTHOR_DATE='2003-04-05T06:07:08+08:00' \
  GIT_COMMITTER_DATE='2004-05-06T07:08:09+08:00' \
    git -C "$repo" commit -qm c2
  git -C "$repo" tag v2

  tool_ok 'squash keeps the HEAD dates' "$repo" --prefix=pkg --squash "$remote" keep
  assert_eq 'squash keeps author and committer dates' \
    '2003-04-05T06:07:08+08:00|2004-05-06T07:08:09+08:00' \
    "$(git --git-dir="$remote" show -s --format="$fields" keep)"

  tool_ok 'squash-tags keeps per-tag dates' \
    "$repo" --prefix=pkg --squash-tags "$remote" tags
  assert_eq 'newest tag keeps its dates' \
    '2003-04-05T06:07:08+08:00|2004-05-06T07:08:09+08:00' \
    "$(git --git-dir="$remote" show -s --format="$fields" tags)"
  assert_eq 'older tag keeps its dates' \
    '2001-02-03T04:05:06+08:00|2002-03-04T05:06:07+08:00' \
    "$(git --git-dir="$remote" show -s --format="$fields" tags^)"
}

test_dates_fixed_and_current() {
  local w repo remote before after epoch
  w=$(new_tmp dates-fixed); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"

  mkdir -p "$repo/pkg"
  printf 'one\n' >"$repo/pkg/data.txt"
  git -C "$repo" add -A
  GIT_AUTHOR_DATE='2001-02-03T04:05:06+08:00' \
  GIT_COMMITTER_DATE='2002-03-04T05:06:07+08:00' \
    git -C "$repo" commit -qm c1

  tool_ok 'fixed committer date' "$repo" --prefix=pkg --squash \
    --committer-date='2020-01-01T00:00:00+08:00' "$remote" fixed
  assert_eq 'fixed date is exact' '1577808000' \
    "$(git --git-dir="$remote" show -s --format=%ct fixed)"
  assert_eq 'fixed date keeps its offset' '2020-01-01T00:00:00+08:00' \
    "$(git --git-dir="$remote" show -s --format=%cI fixed)"
  assert_eq 'the author date is untouched' '2001-02-03T04:05:06+08:00' \
    "$(git --git-dir="$remote" show -s --format=%aI fixed)"

  before=$(date +%s)
  tool_ok 'current dates for both sides' "$repo" --prefix=pkg --squash \
    --dates=current "$remote" now
  after=$(date +%s)
  assert_eq 'author and committer share the run timestamp' \
    "$(git --git-dir="$remote" show -s --format=%at now)" \
    "$(git --git-dir="$remote" show -s --format=%ct now)"
  epoch=$(git --git-dir="$remote" show -s --format=%ct now)
  (( epoch >= before && epoch <= after )) ||
    fail "current date $epoch is outside the run window $before..$after"
}

test_dates_evenly() {
  local w repo remote expected oldest
  w=$(new_tmp dates-evenly); repo=$w/repo
  remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"; init_remote "$w/one.git"

  mkdir -p "$repo/pkg"
  local i=1
  while (( i <= 4 )); do
    printf 'line %d\n' "$i" >>"$repo/pkg/data.txt"
    commit_all "$repo" "c$i"
    git -C "$repo" tag "v$i"
    i=$((i + 1))
  done

  tool_ok 'evenly spread committer dates' "$repo" --prefix=pkg --squash-tags \
    --committer-date='evenly,2020-01-01T00:00:00+08:00,2020-01-04T00:00:00+08:00' \
    "$remote" main
  expected=$(printf '1577808000\n1577894400\n1577980800\n1578067200')
  assert_eq 'endpoints included, steps equal' "$expected" \
    "$(git --git-dir="$remote" log --reverse --format=%ct main)"
  oldest=$(git --git-dir="$remote" rev-parse main~3)
  assert_eq 'evenly keeps the START offset' '2020-01-01T00:00:00+08:00' \
    "$(git --git-dir="$remote" show -s --format=%cI "$oldest")"
  assert_eq 'evenly leaves author dates alone' \
    "$(git -C "$repo" show -s --format=%aI v1)" \
    "$(git --git-dir="$remote" show -s --format=%aI "$oldest")"

  init_remote "$w/two.git"
  tool_ok 'evenly is reproducible' "$repo" --prefix=pkg --squash-tags \
    --committer-date='evenly,2020-01-01T00:00:00+08:00,2020-01-04T00:00:00+08:00' \
    "$w/two.git" main
  assert_eq 'evenly chain is reproducible across remotes' \
    "$(remote_rev "$remote" main)" "$(remote_rev "$w/two.git" main)"

  tool_ok 'single commit uses START' "$repo" --prefix=pkg --squash \
    --dates='evenly,2020-01-01T00:00:00+08:00,2020-01-04T00:00:00+08:00' \
    "$w/one.git" main
  assert_eq 'single commit uses START for both dates' '1577808000|1577808000' \
    "$(git --git-dir="$w/one.git" show -s --format='%at|%ct' main)"
}

test_dates_shorthand_and_validation() {
  local w repo remote
  w=$(new_tmp dates-validation); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"

  mkdir -p "$repo/pkg"
  printf 'one\n' >"$repo/pkg/data.txt"
  commit_all "$repo" c1

  tool_fails '--dates with --author-date' "$repo" --prefix=pkg --squash \
    --dates=keep --author-date=keep "$remote" bad
  assert_contains 'date conflict is reported' "$TOOL_OUTPUT" 'cannot be combined'
  tool_fails '--committer-date with --dates' "$repo" --prefix=pkg --squash \
    --committer-date=keep --dates=keep "$remote" bad
  assert_contains 'date conflict is reported in any order' "$TOOL_OUTPUT" 'cannot be combined'

  tool_fails 'date without a time' "$repo" --prefix=pkg --squash \
    --committer-date='2020-01-01' "$remote" bad
  assert_contains 'short date is reported' "$TOOL_OUTPUT" 'invalid committer date'
  tool_fails 'date without a timezone' "$repo" --prefix=pkg --squash \
    --committer-date='2020-01-01T00:00:00' "$remote" bad
  assert_contains 'missing timezone is reported' "$TOOL_OUTPUT" 'invalid committer date'
  tool_fails 'relative dates are rejected' "$repo" --prefix=pkg --squash \
    --committer-date='2 weeks ago' "$remote" bad
  assert_contains 'relative date is reported' "$TOOL_OUTPUT" 'invalid committer date'
  tool_fails 'evenly without an end date' "$repo" --prefix=pkg --squash \
    --committer-date='evenly,2020-01-01T00:00:00+08:00' "$remote" bad
  assert_contains 'evenly arity is reported' "$TOOL_OUTPUT" 'invalid committer date'
  tool_fails 'evenly with three dates' "$repo" --prefix=pkg --squash \
    --committer-date='evenly,2020-01-01T00:00:00+08:00,2020-01-02T00:00:00+08:00,2020-01-03T00:00:00+08:00' \
    "$remote" bad
  assert_contains 'evenly arity is reported twice' "$TOOL_OUTPUT" 'invalid committer date'
  tool_fails 'duplicate --dates' "$repo" --prefix=pkg --squash \
    --dates=keep --dates=current "$remote" bad
  assert_contains 'duplicate date option is reported' "$TOOL_OUTPUT" 'more than once'
  tool_fails 'date option in normal mode' "$repo" --prefix=pkg \
    --dates=keep "$remote" main
  assert_contains 'normal mode rejects date options' "$TOOL_OUTPUT" 'only apply to --squash'
}

test_squash_tags_nondeterministic_dates_need_force() {
  local w repo remote
  w=$(new_tmp dates-force); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"

  mkdir -p "$repo/pkg"
  printf 'one\n' >"$repo/pkg/data.txt"
  git -C "$repo" add -A
  GIT_AUTHOR_DATE='2001-01-01T00:00:00+08:00' \
  GIT_COMMITTER_DATE='2001-01-01T00:00:00+08:00' \
    git -C "$repo" commit -qm c1
  git -C "$repo" tag v1
  printf 'two\n' >>"$repo/pkg/data.txt"
  git -C "$repo" add -A
  GIT_AUTHOR_DATE='2002-01-01T00:00:00+08:00' \
  GIT_COMMITTER_DATE='2002-01-01T00:00:00+08:00' \
    git -C "$repo" commit -qm c2
  git -C "$repo" tag v2

  tool_ok 'initial publish' "$repo" --prefix=pkg --squash-tags "$remote" main

  tool_fails 'current dates cannot match the published chain' \
    "$repo" --prefix=pkg --squash-tags --committer-date=current "$remote" main
  assert_contains 'hint mentions the current-date cause' "$TOOL_OUTPUT" 'current dates change on every run'
  assert_contains 'hint mentions -f' "$TOOL_OUTPUT" 'use -f'
  tool_ok 'force rebuild with current dates' \
    "$repo" --prefix=pkg --squash-tags --committer-date=current -f "$remote" main
  assert_eq 'force rebuild publishes every tag' '2' \
    "$(git --git-dir="$remote" rev-list --count main)"

  printf 'three\n' >>"$repo/pkg/data.txt"
  git -C "$repo" add -A
  GIT_AUTHOR_DATE='2003-01-01T00:00:00+08:00' \
  GIT_COMMITTER_DATE='2003-01-01T00:00:00+08:00' \
    git -C "$repo" commit -qm c3
  git -C "$repo" tag v3
  tool_fails 'evenly needs a rebuild when the tag set changes' \
    "$repo" --prefix=pkg --squash-tags \
    --committer-date='evenly,2020-01-01T00:00:00+08:00,2020-01-03T00:00:00+08:00' \
    "$remote" main
  assert_contains 'hint mentions evenly' "$TOOL_OUTPUT" 'evenly dates are re-spread'
}

test_dirty_worktree_is_refused() {
  local w repo remote
  w=$(new_tmp dirty); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"

  mkdir -p "$repo/pkg"
  printf 'a\n' >"$repo/pkg/a.txt"
  commit_all "$repo" one
  printf 'scratch\n' >"$repo/pkg/untracked.txt"

  tool_fails 'dirty working tree' "$repo" --prefix=pkg --squash "$remote" main
  assert_contains 'dirty tree is reported' "$TOOL_OUTPUT" 'not clean'
  assert_eq 'nothing was published' '' "$(remote_rev "$remote" main)"
}

# --- argument validation ----------------------------------------------------

test_prefix_validation() {
  local w repo remote
  w=$(new_tmp prefix); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"

  mkdir -p "$repo/pkg"
  printf 'a\n' >"$repo/pkg/a.txt"
  printf 'file\n' >"$repo/plain.txt"
  commit_all "$repo" one

  tool_fails 'missing --prefix' "$repo" "$remote" main
  assert_contains 'missing prefix is reported' "$TOOL_OUTPUT" 'required option --prefix'

  tool_fails 'absolute --prefix' "$repo" --prefix=/etc --squash "$remote" main
  assert_contains 'absolute prefix is reported' "$TOOL_OUTPUT" 'must be relative'

  tool_fails 'parent component in --prefix' "$repo" --prefix=../pkg --squash "$remote" main
  assert_contains 'parent component is reported' "$TOOL_OUTPUT" 'must not contain ..'

  tool_fails 'unknown prefix' "$repo" --prefix=nope --squash "$remote" main
  assert_contains 'unknown prefix is reported' "$TOOL_OUTPUT" 'does not exist in HEAD'

  tool_fails 'file prefix' "$repo" --prefix=plain.txt --squash "$remote" main
  assert_contains 'file prefix is reported' "$TOOL_OUTPUT" 'not a directory'

  tool_ok 'trailing slash and ./ are normalised' "$repo" --prefix=./pkg/ --squash "$remote" main
  assert_eq 'normalised prefix publishes the subtree' \
    "$(git -C "$repo" rev-parse 'HEAD:pkg')" \
    "$(git --git-dir="$remote" rev-parse 'main^{tree}')"
}

test_branch_validation() {
  local w repo remote
  w=$(new_tmp branch); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"

  printf 'a\n' >"$repo/a.txt"
  commit_all "$repo" one

  tool_fails 'full ref as BRANCH' "$repo" --prefix=. "$remote" refs/heads/main
  assert_contains 'full ref is reported' "$TOOL_OUTPUT" 'must be a branch name'
  assert_eq 'no nested branch was created' '' \
    "$(git --git-dir="$remote" for-each-ref --format='%(refname)' refs/heads)"

  tool_fails 'invalid branch name' "$repo" --prefix=. "$remote" 'bad..name'
  assert_contains 'invalid branch name is reported' "$TOOL_OUTPUT" 'invalid branch name'

  tool_ok 'slash separated branch names still work' \
    "$repo" --prefix=. "$remote" release/v1
  assert_eq 'nested-but-valid branch is created' '1' \
    "$(git --git-dir="$remote" rev-list --count release/v1)"
}

# --- --squash-tags ----------------------------------------------------------

test_squash_tags_publishes_one_commit_per_tag() {
  local w repo remote tip mid d1 d2 d3 d4
  w=$(new_tmp squash-tags); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"

  mkdir -p "$repo/pkg"
  printf 'one\n' >"$repo/pkg/data.txt"; commit_all "$repo" c1; git -C "$repo" tag v1
  printf 'two\n' >>"$repo/pkg/data.txt"; commit_all "$repo" c2; git -C "$repo" tag v2
  printf 'three\n' >>"$repo/pkg/data.txt"
  git -C "$repo" add -A
  GIT_AUTHOR_DATE='2003-01-01T00:00:00+08:00' \
  GIT_COMMITTER_DATE='2003-01-01T00:00:00+08:00' \
    git -C "$repo" commit -qm c3
  git -C "$repo" tag v3
  d1=$(git -C "$repo" describe --tags --always --long --abbrev=7 v1)
  d2=$(git -C "$repo" describe --tags --always --long --abbrev=7 v2)
  d3=$(git -C "$repo" describe --tags --always --long --abbrev=7 v3)

  tool_ok 'publish tag snapshots' "$repo" --prefix=pkg --squash-tags "$remote" main
  assert_eq 'one commit per tag' '3' \
    "$(git --git-dir="$remote" rev-list --count main)"
  assert_eq 'commit messages are describe names' "$(printf '%s\n%s\n%s' "$d3" "$d2" "$d1")" \
    "$(git --git-dir="$remote" log --format=%s main)"

  tip=$(remote_rev "$remote" main)
  mid=$(git --git-dir="$remote" rev-parse main^)
  assert_eq 'tip publishes the v3 tree' \
    "$(git -C "$repo" rev-parse 'v3:pkg')" \
    "$(git --git-dir="$remote" rev-parse "$tip^{tree}")"
  assert_eq 'middle commit publishes the v2 tree' \
    "$(git -C "$repo" rev-parse 'v2:pkg')" \
    "$(git --git-dir="$remote" rev-parse "$mid^{tree}")"

  tool_ok 'rerun without new tags' "$repo" --prefix=pkg --squash-tags "$remote" main
  assert_contains 'rerun is a no-op' "$TOOL_OUTPUT" 'already up to date'
  assert_eq 'tip is unchanged' "$tip" "$(remote_rev "$remote" main)"

  printf 'four\n' >>"$repo/pkg/data.txt"; commit_all "$repo" c4; git -C "$repo" tag v4
  d4=$(git -C "$repo" describe --tags --always --long --abbrev=7 v4)
  tool_ok 'append a new tag' "$repo" --prefix=pkg --squash-tags "$remote" main
  assert_eq 'only one commit is appended' '4' \
    "$(git --git-dir="$remote" rev-list --count main)"
  assert_eq 'new commit builds on the previous tip' "$tip" \
    "$(git --git-dir="$remote" rev-parse main^)"
  assert_eq 'new tip is named after the last tag' "$d4" \
    "$(git --git-dir="$remote" log -1 --format=%s main)"
}

test_squash_tags_handles_annotated_and_duplicate_tags() {
  local w repo remote d1 d2
  w=$(new_tmp squash-tags-annotated); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"

  mkdir -p "$repo/pkg"
  printf 'one\n' >"$repo/pkg/data.txt"; commit_all "$repo" c1; git -C "$repo" tag v1
  printf 'two\n' >>"$repo/pkg/data.txt"; commit_all "$repo" c2
  git -C "$repo" tag -a v2 -m 'annotated release two'
  git -C "$repo" tag v2-hotfix
  d1=$(git -C "$repo" describe --tags --always --long --abbrev=7 v1)
  d2=$(git -C "$repo" describe --tags --always --long --abbrev=7 v2)

  tool_ok 'publish annotated tags' "$repo" --prefix=pkg --squash-tags "$remote" main
  assert_eq 'annotated tag and lightweight alias both become commits' '3' \
    "$(git --git-dir="$remote" rev-list --count main)"
  assert_eq 'tags on one commit share the describe name' \
    "$(printf '%s\n%s\n%s' "$d2" "$d2" "$d1")" \
    "$(git --git-dir="$remote" log --format=%s main)"
  assert_eq 'annotated tag publishes its peeled commit tree' \
    "$(git -C "$repo" rev-parse 'v2^{commit}:pkg')" \
    "$(git --git-dir="$remote" rev-parse 'main^^{tree}')"
}

test_squash_tags_rejects_moved_tags() {
  local w repo remote old_tip
  w=$(new_tmp squash-tags-moved); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"

  mkdir -p "$repo/pkg"
  printf 'one\n' >"$repo/pkg/data.txt"; commit_all "$repo" c1; git -C "$repo" tag v1
  printf 'two\n' >>"$repo/pkg/data.txt"; commit_all "$repo" c2; git -C "$repo" tag v2
  printf 'three\n' >>"$repo/pkg/data.txt"
  git -C "$repo" add -A
  GIT_AUTHOR_DATE='2003-01-01T00:00:00+08:00' \
  GIT_COMMITTER_DATE='2003-01-01T00:00:00+08:00' \
    git -C "$repo" commit -qm c3
  git -C "$repo" tag v3

  tool_ok 'initial publish' "$repo" --prefix=pkg --squash-tags "$remote" main
  old_tip=$(remote_rev "$remote" main)

  # Moving a tag rewrites the implied chain, so incremental publishing must
  # refuse instead of silently replacing history.
  git -C "$repo" tag -f v3 "$(git -C "$repo" rev-parse v2^{commit})" >/dev/null
  tool_fails 'moved tag without --force' "$repo" --prefix=pkg --squash-tags "$remote" main
  assert_contains 'moved tag suggests --force' "$TOOL_OUTPUT" 'use -f'
  assert_eq 'remote is left untouched' "$old_tip" "$(remote_rev "$remote" main)"

  tool_ok 'force rebuild after a moved tag' \
    "$repo" --prefix=pkg --squash-tags -f "$remote" main
  assert_eq 'rebuilt chain keeps one commit per tag' '3' \
    "$(git --git-dir="$remote" rev-list --count main)"
  assert_eq 'rebuilt tip publishes the moved tag tree' \
    "$(git -C "$repo" rev-parse 'v3:pkg')" \
    "$(git --git-dir="$remote" rev-parse 'main^{tree}')"
}

test_squash_tags_tag_before_prefix_exists() {
  local w repo remote first
  w=$(new_tmp squash-tags-empty); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"

  printf 'no package yet\n' >"$repo/readme.txt"; commit_all "$repo" c1
  git -C "$repo" tag v1
  mkdir -p "$repo/pkg"
  printf 'one\n' >"$repo/pkg/data.txt"; commit_all "$repo" c2; git -C "$repo" tag v2

  tool_ok 'publish tags before the prefix exists' \
    "$repo" --prefix=pkg --squash-tags "$remote" main
  assert_eq 'one commit per tag' '2' \
    "$(git --git-dir="$remote" rev-list --count main)"
  first=$(git --git-dir="$remote" rev-parse main^)
  assert_eq 'earlier tag publishes an empty tree' '' \
    "$(git --git-dir="$remote" ls-tree --name-only "$first")"
}

test_squash_tags_is_deterministic() {
  local w repo a b c clone
  w=$(new_tmp deterministic); repo=$w/repo
  a=$w/a.git; b=$w/b.git; c=$w/c.git
  init_repo "$repo"; init_remote "$a"; init_remote "$b"; init_remote "$c"

  mkdir -p "$repo/pkg"
  printf 'one\n' >"$repo/pkg/data.txt"; commit_all "$repo" c1; git -C "$repo" tag v1
  printf 'two\n' >>"$repo/pkg/data.txt"; commit_all "$repo" c2; git -C "$repo" tag v2

  tool_ok 'publish to first remote' "$repo" --prefix=pkg --squash-tags "$a" main
  tool_ok 'publish to second remote' "$repo" --prefix=pkg --squash-tags "$b" main
  assert_eq 'identical input yields identical commits' \
    "$(remote_rev "$a" main)" "$(remote_rev "$b" main)"

  # A different clone with a different identity must still reproduce the chain.
  git clone -q "$repo" "$w/clone"
  git -C "$w/clone" config user.name 'Other Author'
  git -C "$w/clone" config user.email 'other@example.com'
  tool_ok 'publish from another clone' "$w/clone" --prefix=pkg --squash-tags "$c" main
  assert_eq 'clone reproduces the same chain' \
    "$(remote_rev "$a" main)" "$(remote_rev "$c" main)"
}

# --- safety -----------------------------------------------------------------

test_force_with_lease_rejects_concurrent_update() {
  local w repo remote race marker racer_tip
  w=$(new_tmp lease); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"

  mkdir -p "$repo/pkg"
  printf 'one\n' >"$repo/pkg/data.txt"; commit_all "$repo" c1

  tool_ok 'initial publish' "$repo" --prefix=pkg --squash "$remote" main

  # Simulated concurrent publisher: runs inside the git proxy right before the
  # tool pushes, so the lease is compared against a stale expectation.
  race=$w/race.sh
  cat >"$race" <<RACE
#!/usr/bin/env bash
set -e
work=\$(mktemp -d "\${TMPDIR:-/tmp}/gssp-race.XXXXXX")
"$REAL_GIT" clone -q --branch main "$remote" "\$work/other" 2>/dev/null
"$REAL_GIT" -C "\$work/other" -c user.name=Racer -c user.email=racer@example.com \
  commit -q --allow-empty -m 'concurrent publish'
"$REAL_GIT" -C "\$work/other" push -q origin main
RACE
  chmod +x "$race"
  marker=$w/race.marker

  printf 'two\n' >>"$repo/pkg/data.txt"
  commit_all "$repo" c2

  if out=$(cd "$repo" && PATH="$HERE/bin:$PATH" REAL_GIT="$REAL_GIT" \
      GIT_BEFORE_PUSH="$race" GIT_BEFORE_PUSH_MARKER="$marker" \
      "$TOOL" --prefix=pkg --squash -f "$remote" main 2>&1); then
    fail "force-with-lease must reject a concurrent update: $out"
  fi
  assert_contains 'rejection is reported' "$out" 'rejected'
  assert_eq 'concurrent commit survives' 'concurrent publish' \
    "$(git --git-dir="$remote" log -1 --format=%s main)"

  # Retrying now sees the concurrent commit and appends on top of it instead of
  # clobbering it.
  racer_tip=$(remote_rev "$remote" main)
  tool_ok 'retry after the concurrent update' "$repo" --prefix=pkg --squash "$remote" main
  assert_eq 'retry builds on the concurrent commit' "$racer_tip" \
    "$(git --git-dir="$remote" rev-parse main^)"
  assert_eq 'local snapshot is published' \
    "$(git -C "$repo" rev-parse 'HEAD:pkg')" \
    "$(git --git-dir="$remote" rev-parse 'main^{tree}')"
  assert_contains 'concurrent commit is preserved' \
    "$(git --git-dir="$remote" log --format=%s main)" 'concurrent publish'
}

test_squash_modes_do_not_need_git_subtree() {
  local w repo remote out
  w=$(new_tmp no-subtree); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"

  mkdir -p "$repo/pkg"
  printf 'one\n' >"$repo/pkg/data.txt"; commit_all "$repo" c1; git -C "$repo" tag v1
  printf 'two\n' >>"$repo/pkg/data.txt"; commit_all "$repo" c2; git -C "$repo" tag v2

  if ! out=$(cd "$repo" && PATH="$HERE/bin:$PATH" REAL_GIT="$REAL_GIT" \
      GIT_FORBID=subtree "$TOOL" --prefix=pkg --squash "$remote" main 2>&1); then
    fail "--squash must not require git-subtree: $out"
  fi

  init_remote "$w/tags.git"
  if ! out=$(cd "$repo" && PATH="$HERE/bin:$PATH" REAL_GIT="$REAL_GIT" \
      GIT_FORBID=subtree "$TOOL" --prefix=pkg --squash-tags "$w/tags.git" main 2>&1); then
    fail "--squash-tags must not require git-subtree: $out"
  fi

  # Normal mode still rewrites history, which is what git subtree provides.
  init_remote "$w/normal.git"
  if out=$(cd "$repo" && PATH="$HERE/bin:$PATH" REAL_GIT="$REAL_GIT" \
      GIT_FORBID=subtree "$TOOL" --prefix=pkg "$w/normal.git" main 2>&1); then
    fail 'normal subtree mode is expected to use git subtree'
  fi
  assert_contains 'normal mode reports the subtree failure' "$out" 'git subtree split failed'
}

test_runs_under_system_bash() {
  local w repo remote out
  [[ -x /bin/bash ]] || { info 'skipped: /bin/bash is not available'; return 0; }
  w=$(new_tmp system-bash); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"

  mkdir -p "$repo/pkg"
  printf 'a\n' >"$repo/pkg/a.txt"; commit_all "$repo" c1

  # Stock macOS ships bash 3.2 as /bin/bash. `--squash` against a fresh remote
  # expands an empty parent array, which older shells reject under `set -u`.
  if ! out=$(cd "$repo" && PATH="/bin:/usr/bin:/usr/sbin:/usr/local/bin" \
      /bin/bash "$TOOL" --prefix=pkg --squash "$remote" main 2>&1); then
    fail "tool must run under /bin/bash: $out"
  fi
  assert_eq 'system bash publishes a snapshot' '1' \
    "$(git --git-dir="$remote" rev-list --count main)"
}

info 'functional tests'
run_case test_normal_mode_root
run_case test_normal_mode_subtree
run_case test_squash_mode
run_case test_commit_messages_use_git_describe
run_case test_identity_defaults_to_keep
run_case test_identity_current_and_fixed
run_case test_identity_shorthand_and_conflicts
run_case test_identity_validation
run_case test_identity_ignores_environment
run_case test_dates_default_to_keep
run_case test_dates_fixed_and_current
run_case test_dates_evenly
run_case test_dates_shorthand_and_validation
run_case test_squash_tags_nondeterministic_dates_need_force
run_case test_dirty_worktree_is_refused
run_case test_prefix_validation
run_case test_branch_validation
run_case test_squash_tags_publishes_one_commit_per_tag
run_case test_squash_tags_handles_annotated_and_duplicate_tags
run_case test_squash_tags_rejects_moved_tags
run_case test_squash_tags_tag_before_prefix_exists
run_case test_squash_tags_is_deterministic
run_case test_force_with_lease_rejects_concurrent_update
run_case test_squash_modes_do_not_need_git_subtree
run_case test_runs_under_system_bash

summary functional
