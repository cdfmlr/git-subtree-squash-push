#!/usr/bin/env bash
# Shared helpers for the git-subtree-squash-push test suite.
#
# Callers must export TOOL (path to the script under test) and TEST_TMP_ROOT
# (a temporary directory) before sourcing this file.

: "${TOOL:?TOOL must point at the git-subtree-squash-push script}"

# Isolate the tests from the developer's git configuration (commit signing,
# hooks, default branch names, ...) so results are reproducible.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME='Test Author'
export GIT_AUTHOR_EMAIL='test@example.com'
export GIT_COMMITTER_NAME='Test Committer'
export GIT_COMMITTER_EMAIL='test@example.com'

# Resolve the real git binary before a test prepends test/bin to PATH.
REAL_GIT=$(command -v git) || { echo 'git is required' >&2; exit 1; }
export REAL_GIT

info() { printf '== %s\n' "$*"; }

fail() {
  printf '\nFAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() { # description expected actual
  [[ "$2" == "$3" ]] || fail "$1: expected [$2], got [$3]"
}

assert_contains() { # description haystack needle
  case $2 in
    *"$3"*) return 0 ;;
  esac
  fail "$1: expected to find [$3] in: $2"
}

new_tmp() { # name
  mktemp -d "$TEST_TMP_ROOT/$1.XXXXXX"
}

init_repo() { # dir
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.name 'Test Author'
  git -C "$1" config user.email 'test@example.com'
  git -C "$1" config commit.gpgsign false
}

init_remote() { # dir
  mkdir -p "$1"
  git -C "$1" init -q --bare
}

commit_all() { # repo message
  git -C "$1" add -A
  git -C "$1" commit -qm "$2"
}

remote_rev() { # remote.git revision (empty when missing)
  git --git-dir="$1" rev-parse --verify -q "$2" 2>/dev/null || true
}

tool_ok() { # description repo args...; result in TOOL_OUTPUT
  local desc=$1 repo=$2
  shift 2
  TOOL_OUTPUT=$(cd "$repo" && "$TOOL" "$@" 2>&1) ||
    fail "$desc: tool exited non-zero: $TOOL_OUTPUT"
}

tool_fails() { # description repo args...; result in TOOL_OUTPUT
  local desc=$1 repo=$2
  shift 2
  if TOOL_OUTPUT=$(cd "$repo" && "$TOOL" "$@" 2>&1); then
    fail "$desc: tool unexpectedly succeeded: $TOOL_OUTPUT"
  fi
}

TESTS_RUN=0
TESTS_FAILED=0

# Space separated case-name allow list; empty means "run everything".
CASE_FILTER=${CASE_FILTER:-}

run_case() { # function name
  local name=$1
  if [[ -n $CASE_FILTER && " $CASE_FILTER " != *" $name "* ]]; then
    return 0
  fi
  printf '\n-- %s\n' "$name"
  # Each case runs in a subshell so one failure does not hide the others.
  if ( "$name" ); then
    printf '   ok\n'
  else
    printf '   case FAILED: %s\n' "$name" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

summary() { # suite name
  printf '\n%s: %d/%d cases passed\n' "$1" \
    "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
  (( TESTS_FAILED == 0 )) || exit 1
}
