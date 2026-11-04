# git-subtree-squash-push

Publish the root of a repository, or one directory inside it, to a standalone
Git repository — as a single squashed snapshot (the default), one snapshot
commit per tag, or with the original history.

The tool is a single dependency-free bash script. It is aimed at the case where
`git subtree push` is too blunt: you want a curated history, deterministic
commit ids, and a safe update path instead of a raw force push.

## Requirements

- `bash` 3.2 or newer (stock `/bin/bash` on macOS works).
- `git` (tested with 2.50).
- `git subtree` is only needed by `--no-squash` when `--prefix` points at a
  subdirectory; the squashed modes never invoke it.

## Install

```sh
install -m 755 git-subtree-squash-push ~/bin/git-subtree-squash-push
```

## Usage

```
git-subtree-squash-push --prefix=PATH [--squash | --squash-tags | --no-squash] [-f] REMOTE BRANCH
```

`REMOTE` is a remote name or a repository URL, and `BRANCH` is the destination
branch. `BRANCH` must be a short name (`main`, `release/v1`); a full ref such as
`refs/heads/main` is rejected. `--prefix` is always relative to the repository
root, even when the script is run from a subdirectory; use `.` for the root.

| Mode | What is published |
| --- | --- |
| *(default)* / `--squash` | One snapshot commit for the current committed state. |
| `--squash-tags` | One snapshot commit per tag on HEAD's first-parent history, in that order. Later runs append only the tags that are not published yet. |
| `--no-squash` | The root or subtree history, unchanged. |

| Option | Meaning |
| --- | --- |
| `--prefix=PATH` | Path relative to the repository root, or `.` for the root. |
| `--squash` | Publish the current snapshot as one commit (default). |
| `--squash-tags` | Publish one snapshot commit per reachable tag. |
| `--no-squash` | Publish the root/subtree history unchanged. |
| `--identity=SPEC` | Set author **and** committer identity. |
| `--author=SPEC`, `--committer=SPEC` | Set one side only. |
| `--dates=SPEC` | Set author **and** committer date. |
| `--author-date=SPEC`, `--committer-date=SPEC` | Set one side only. |
| `-f`, `--force` | Rebuild squashed history from scratch and force-update the branch. With `--no-squash`, force-update with the current history. |
| `-h`, `--help` | Show usage. |

## Identity and dates

Generated commits copy the source commit's author, committer and dates by
default (`keep`). The overrides only work with `--squash` and `--squash-tags`;
using one without them is an error.

Identity specs:

| Value | Result |
| --- | --- |
| `keep` *(default)* | The source commit's author/committer. |
| `current` | `git config user.name` / `user.email`. |
| `NAME <EMAIL>` | The given identity; a `fixed,` prefix is optional. |

Date specs:

| Value | Result |
| --- | --- |
| `keep` *(default)* | The source commit's author/committer date. |
| `current` | The current time, captured once per run. |
| `ISO8601` | A fixed timestamp; a `fixed,` prefix is optional. |
| `START,END` | Dates spread evenly over the generated commits, endpoints included; a single commit uses `START`. An `evenly,` prefix is optional. |

`ISO8601` needs seconds and an explicit timezone:
`YYYY-MM-DD[T ]HH:MM:SS(+|-)HH:MM` or `...Z`. Fixed values are handed to git,
which has the final say on edge cases such as `2026-02-30`. `START,END` is
converted by the script, so it only checks the obvious ranges.

All six `GIT_AUTHOR_*` / `GIT_COMMITTER_*` variables are set explicitly for
every generated commit, so values exported in your shell cannot leak in.

`--identity` cannot be combined with `--author`/`--committer`, and `--dates`
cannot be combined with `--author-date`/`--committer-date`; both are rejected in
either order.

## Examples

Publish the full history of `packages/core` to a separate repository:

```sh
git-subtree-squash-push --prefix=packages/core --no-squash ../core.git main
```

Publish the current state as a single snapshot, then update it later:

```sh
git-subtree-squash-push --prefix=packages/core --squash ../core.git main
```

Build a release branch with one commit per tag:

```sh
git-subtree-squash-push --prefix=packages/core --squash-tags ../core.git main
```

Publish under a bot identity with dates spread over a release window:

```sh
git-subtree-squash-push --prefix=packages/core --squash-tags \
  --identity='Release Bot <release@example.com>' \
  --dates='2026-01-01T00:00:00+08:00,2026-12-31T00:00:00+08:00' \
  ../core.git main
```

Rebuild and replace what was published before:

```sh
git-subtree-squash-push --prefix=packages/core --squash-tags -f ../core.git main
```

## How it works

- Publishing is based on committed content only. The script refuses to run when
  the working tree is dirty (staged, unstaged or untracked files).
- `--no-squash` exports the subtree with `git subtree split` (or `HEAD` for the
  repository root) and pushes that commit.
- `--squash` compares the current snapshot tree with the remote tip. If they
  match it does nothing (unless `-f` is given); otherwise it commits the
  snapshot on top of the remote tip, so ordinary updates are fast-forwards.
- `--squash-tags` rebuilds the whole chain implied by the current tags on every
  run and looks for the remote tip inside it. If the tip is not part of that
  chain (tags were added, moved or deleted, or a non-deterministic date mode was
  used), the run fails instead of rewriting history; `-f` is required.
- With `-f`, pushes use `--force-with-lease` with the exact OID fetched moments
  earlier, so a concurrent publisher is not overwritten — even when `REMOTE` is
  a plain URL rather than a named remote.
- Generated commits are named with
  `git describe --tags --always --long --abbrev=7` of their source commit.
  Identity, dates and that name are stable inputs, so the same repository state
  produces the same commit ids on different machines.

## Notes

- Running without a mode option publishes one squashed snapshot. Pass
  `--no-squash` to publish the history itself.
- `--squash-tags` requires at least one tag on the current HEAD's first-parent
  history; tags on merged side branches are ignored.
- `keep` is the default for identity and dates, so `--squash` is reproducible
  too. A `--squash-tags` branch published by an older version of the tool (or
  with different options) will report a chain mismatch; rebuild it once with
  `-f`.
- `--dates=current` produces new commit ids on every run, and an evenly spread
  range changes whenever the set of tags changes. Both therefore need `-f`
  whenever the chain is rebuilt; the error message says which mode caused it.
- `--abbrev=7` keeps descriptions stable across clones. Git still lengthens the
  abbreviation if seven characters would be ambiguous inside a given
  repository.

## Tests

```sh
./test/run.sh                 # functional + performance
./test/run.sh functional      # behaviour only
PERF_COMMITS=800 ./test/run.sh performance
```

See [test/README.md](test/README.md) for what is covered and how the git proxy
in `test/bin/git` simulates concurrent publishers.
