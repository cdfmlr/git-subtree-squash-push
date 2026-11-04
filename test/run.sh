#!/usr/bin/env bash
# Run the whole git-subtree-squash-push test suite.
#
#   ./test/run.sh                       # functional + performance
#   ./test/run.sh functional            # only the functional tests
#   ./test/run.sh performance           # only the performance tests
#   PERF_COMMITS=800 ./test/run.sh performance
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
: "${TOOL:=$ROOT/git-subtree-squash-push}"
export TOOL

suites=${*:-functional performance}
status=0
for suite in $suites; do
  printf '\n### %s\n' "$suite"
  "$HERE/$suite.sh" || status=1
done
exit $status
