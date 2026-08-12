#!/bin/bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
rc=0
for suite in test-backend.sh; do
  bash "$here/$suite" || rc=1
done
exit "$rc"
