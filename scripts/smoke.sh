#!/usr/bin/env bash
# Headless end-to-end smoke test: boot the real app under a virtual display and
# assert that its --self-test reports PASS. Exits non-zero on failure so make and
# CI can gate on it.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$here/build/zmarkdown"

if [[ ! -x "$bin" ]]; then
  echo "smoke: binary not found at $bin (run 'make build' first)" >&2
  exit 1
fi

run() {
  if [[ "$(uname -s)" == "Linux" ]] && command -v xvfb-run >/dev/null 2>&1 && [[ -z "${DISPLAY:-}" ]]; then
    # No display: use a virtual X server.
    xvfb-run -a "$bin" --self-test
  else
    "$bin" --self-test
  fi
}

echo "smoke: running self-test..."
output="$(run 2>&1)"
status=$?

echo "$output" | grep -vE 'libEGL|DRI3' || true

if [[ $status -eq 0 ]] && echo "$output" | grep -q "SELF-TEST PASS"; then
  echo "smoke: PASS"
  exit 0
fi

echo "smoke: FAIL (exit $status)" >&2
exit 1
