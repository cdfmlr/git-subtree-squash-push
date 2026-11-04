# Tests

Reproducible functional and performance tests for `git-subtree-squash-push`.
Everything runs against throwaway repositories and local bare remotes created in
a temporary directory, so no network access or global git configuration is
involved.

```sh
./test/run.sh                 # functional + performance
./test/run.sh functional      # behaviour only (fast)
./test/run.sh performance     # synthetic history + budgets
```

## functional.sh

Covers `--no-squash` (root and subtree), `--squash` (snapshot, `git describe` naming, no-op rerun,
incremental append, `-f` rebuild), `--squash-tags` (one commit per tag, tag
ordering, annotated/default tags on the same commit, incremental append,
detached/inserted tags, empty snapshots before the prefix exists, deterministic
commit ids across remotes and clones), argument validation, refusal to publish
a dirty working tree, and `--force-with-lease` protection against a concurrent
publisher.

Identity options (`--identity` / `--author` / `--committer`) are covered for
`keep`, `current` and `fixed` values, shorthand conflicts and environment
isolation. Date options (`--dates` / `--author-date` / `--committer-date`) are
covered for `keep`, `current`, `fixed` and `evenly` values, including the
"rebuilds need -f" hint for non-deterministic modes.

Run a subset while iterating:

```sh
CASE_FILTER='test_squash_mode test_branch_validation' ./test/functional.sh
```

## performance.sh

Builds a synthetic history (300 commits, a tag every 10 commits by default),
publishes it, and asserts:

* a full `--squash-tags` publish stays under 60s and a no-op rerun under 30s,
* no `git subtree` invocations (snapshots must not rewrite history),
* no `git tag --points-at` invocations (tag discovery must not spawn one
  process per commit),
* the number of git invocations is proportional to the tag count, not the
  commit count.

```sh
PERF_COMMITS=800 PERF_TAG_EVERY=20 PERF_BUILD_BUDGET=120 ./test/performance.sh
```

## test/bin/git

A proxy placed first in `PATH` by the tests. It logs every invocation
(`GIT_CALL_LOG`), can reject a subcommand (`GIT_FORBID=subtree`) and can run a
command right before the first push (`GIT_BEFORE_PUSH`) to simulate another
author updating the destination branch.
