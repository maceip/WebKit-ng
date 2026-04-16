#!/usr/bin/env bash
# Fire an alert: bell on stderr, optional Slack-compatible webhook, optional hook command.
# Env: NG_ALERT_WEBHOOK_URL (POST JSON {"text":"..."}), NG_ALERT_CMD (bash -c with $1 = full message)
set -euo pipefail
MSG="$*"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Terminal bell + impossible-to-miss line on stderr
printf '\a[ALERT %s] %s\n' "$TS" "$MSG" >&2
if [[ -n "${NG_ALERT_WEBHOOK_URL:-}" ]] && command -v curl >/dev/null 2>&1; then
  payload="$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' "$MSG")" || payload="{\"text\":\"$MSG\"}"
  curl -fsS -m 20 -X POST -H 'Content-Type: application/json' -d "$payload" "${NG_ALERT_WEBHOOK_URL}" >&2 || true
fi
if [[ -n "${NG_ALERT_CMD:-}" ]]; then
  export NG_ALERT_MESSAGE="$MSG"
  bash -c "$NG_ALERT_CMD" >&2 || true
fi
