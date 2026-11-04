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
  local w repo remote msg
  w=$(new_tmp describe); repo=$w/repo; remote=$w/remote.git
  init_repo "$repo"; init_remote "$remote"

  mkdir -p "$repo/pkg"
  printf 'one\n' >"$repo/pkg/data.txt"; commit_all "$repo" c1

  tool_ok 'untagged snapshot' "$repo" --prefix=pkg --squash "$remote" main
  msg=$(git -C "$repo" describe --tags --always --long HEAD)
  assert_eq 'untagged snapshot falls back to --always' "$msg" \
    "$(git --git-dir="$remote" log -1 --format=%s main)"
  assert_eq 'fallback is the abbreviated commit id' \
    "$(git -C "$repo" rev-parse --short HEAD)" "$msg"

  git -C "$repo" tag v1
  printf 'two\n' >>"$repo/pkg/data.txt"; commit_all "$repo" c2
  tool_ok 'tagged snapshot' "$repo" --prefix=pkg --squash "$remote" main
  msg=$(git -C "$repo" describe --tags --always --long HEAD)
  assert_eq 'tagged snapshot is named with describe' "$msg" \
    "$(git --git-dir="$remote" log -1 --format=%s main)"
  assert_eq 'describe counts commits since the tag' 'v1-1-g' "${msg:0:6}"
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
  printf 'three\n' >>"$repo/pkg/data.txt"; commit_all "$repo" c3; git -C "$repo" tag v3
  d1=$(git -C "$repo" describe --tags --always --long v1)
  d2=$(git -C "$repo" describe --tags --always --long v2)
  d3=$(git -C "$repo" describe --tags --always --long v3)

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
  d4=$(git -C "$repo" describe --tags --always --long v4)
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
  d1=$(git -C "$repo" describe --tags --always --long v1)
  d2=$(git -C "$repo" describe --tags --always --long v2)

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
  printf 'three\n' >>"$repo/pkg/data.txt"; commit_all "$repo" c3; git -C "$repo" tag v3

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
