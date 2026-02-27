#!/bin/bash
# tests/test_helper.bash - Common setup for all bats tests

# Project root (two levels up from tests/unit/)
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT

# Disable strict mode side effects in test runner
# (individual source files set their own strict mode)
set +euo pipefail 2>/dev/null || true
