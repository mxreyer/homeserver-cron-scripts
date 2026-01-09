#!/bin/bash
# ==============================================================================
# Script Name: ping.sh
# Description: Provides functions to ping healthchecks
# ==============================================================================

ping_success() {
  echo "🛜 Ping success."
  [ -z "$HEALTHCHECK_URL" ] || curl -fsS --max-time 10 "$HEALTHCHECK_URL" >/dev/null || (echo "⚠️ Healthcheck ping failed."; return 1)
}
ping_fail() {
  echo "🛜 Ping failure."
  [ -z "$HEALTHCHECK_URL" ] || curl -fsS --max-time 10 "${HEALTHCHECK_URL}/fail" >/dev/null || (echo "⚠️ Healthcheck ping failed."; return 1)
}
