#!/bin/bash
# Sourced by ci-wait.sh: the one place that defines what an infrastructure (not code) CI failure looks like.
# Edit the patterns here. Extended regexes, matched against `gh run view <id> --log-failed` with ANSI colors stripped.
# A failed run counts as an infra outage only if its failed-step log matches ORCH_INFRA_PATTERN and shows no real
# test failure (ORCH_REAL_FAIL_PATTERN); any real failure counts as a normal CI failure.
ORCH_INFRA_PATTERN=${ORCH_INFRA_PATTERN:-'Unexpected HTTP response: 5[0-9][0-9]|returned error: 5[0-9][0-9]|HTTP/[0-9.]+ 5[0-9][0-9]|50[234] (Bad Gateway|Service Unavailable|Gateway Time-?out)|(Failed|Unable|Error) (to )?download|download[^[:cntrl:]]*(failed|error)|Could not resolve host|TLS handshake timeout|ETIMEDOUT|ECONNRESET|[Cc]onnection (reset by peer|timed out)|Could not connect to|Unable to connect to|Failed to fetch https?://'}
ORCH_REAL_FAIL_PATTERN=${ORCH_REAL_FAIL_PATTERN:-'(^|[^A-Za-z])FAIL( |:)|AssertionError|Test Files +[0-9]+ failed|Tests +[0-9]+ failed|[0-9]+ tests? failed'}
# infra_only <log-file>: 0 when the log shows an infrastructure error and no real test failure.
infra_only() {
  local c; c=$(LC_ALL=C sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g' "$1")
  grep -Eq -- "$ORCH_INFRA_PATTERN" <<<"$c" && ! grep -Eq -- "$ORCH_REAL_FAIL_PATTERN" <<<"$c"
}
