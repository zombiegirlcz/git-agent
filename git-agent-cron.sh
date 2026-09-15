#!/usr/bin/env bash
#
# git-agent-cron.sh — obálka pro pravidelný běh `git-agent -g` z cronu/plánovače.
#
# Cron má minimální prostředí, takže wrapper zajistí:
#   * PATH včetně ~/.local/bin a node/npm (copilot z nvm),
#   * HOME/LANG,
#   * logování do ~/.local/state/git-agent/cron.log (s rotací při 5 MB),
#   * časový limit běhu a záznam výsledku (rc),
#   * chytrou notifikaci: pošle ji jen když se něco odeslalo nebo selhalo
#     (žádný hodinový spam).
#
# Instalace (každou hodinu):
#   crontab -e   →   0 * * * * $HOME/.local/bin/git-agent-cron
#   nebo automaticky:  ./setup.sh --cron
#
# Proměnné prostředí:
#   GIT_AGENT_CRON_ARGS      argumenty pro git-agent (default: "-g")
#   GIT_AGENT_CRON_TIMEOUT   limit běhu v sekundách (default: 3600)
#   GIT_AGENT_CRON_NOTIFY    changes (default) | always | never

set -uo pipefail

export HOME="${HOME:-/root}"
export LANG="${LANG:-C.UTF-8}"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/git-agent"
LOG="$STATE_DIR/cron.log"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# PATH jako v přihlášeném shellu (cron má jen /usr/bin:/bin)
for d in "$HOME"/.nvm/versions/node/*/bin "$HOME/.local/bin"; do
  [[ -d $d ]] && PATH="$d:$PATH"
done
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

AGENT="$HOME/.local/bin/git-agent"
[[ -x $AGENT ]] || AGENT=$(command -v git-agent 2>/dev/null || true)
if [[ -z ${AGENT:-} ]]; then
  printf '%s CHYBA: git-agent nenalezen (spusť setup.sh)\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
  exit 127
fi

read -r -a ARGS <<< "${GIT_AGENT_CRON_ARGS:--g}"
TIMEOUT="${GIT_AGENT_CRON_TIMEOUT:-3600}"
NOTIFY_MODE="${GIT_AGENT_CRON_NOTIFY:-changes}"

# rotace logu
if [[ -f $LOG ]] && (( $(stat -Lc %s "$LOG" 2>/dev/null || echo 0) > 5242880 )); then
  mv -f "$LOG" "$LOG.1" 2>/dev/null || true
fi

nh_notify() {
  [[ $NOTIFY_MODE == never ]] && return 0
  command -v nh >/dev/null 2>&1 || return 0
  timeout 10 nh system notification -t "$1" -c "$2" >/dev/null 2>&1 || true
}

# v režimu changes/never si notifikace řídíme sami → agentovi je vypneme
AGENT_ENV=()
case $NOTIFY_MODE in
  changes|never) AGENT_ENV+=(GIT_NOTIFI=0) ;;
esac

tmp=$(mktemp)
printf '\n===== %s | git-agent %s =====\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${ARGS[*]}" >> "$LOG"

env ${AGENT_ENV[@]+"${AGENT_ENV[@]}"} timeout "$TIMEOUT" "$AGENT" "${ARGS[@]}" > "$tmp" 2>&1
rc=$?
cat "$tmp" >> "$LOG"

summary=$(grep -E 'repozitářů:.*commitů:' "$tmp" | tail -n 1)

if (( rc != 0 )) || grep -q 'SELHALO' "$tmp"; then
  nh_notify "git-agent: chyba ✗" "${summary:-rc=$rc (viz $LOG)}"
  printf '===== %s | rc=%d | CHYBA =====\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$rc" >> "$LOG"
elif [[ $NOTIFY_MODE == changes ]]; then
  # kolik se toho reálně udělalo (commity + pully + pushy)
  nums=$(printf '%s\n' "$summary" | sed -n 's/.*commitů: \([0-9]*\) | pullů: \([0-9]*\) | pushů: \([0-9]*\).*/\1 \2 \3/p')
  total=0
  for n in $nums; do total=$((total + n)); done
  (( total > 0 )) && nh_notify "git-agent: odesláno ✓" "${summary:-změny}"
  printf '===== %s | rc=%d | změn: %d =====\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$rc" "$total" >> "$LOG"
else
  printf '===== %s | rc=%d =====\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$rc" >> "$LOG"
fi

rm -f "$tmp"
exit "$rc"
