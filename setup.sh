#!/usr/bin/env bash
#
# setup.sh — instalace všeho, co git-agent potřebuje.
# Idempotentní: bezpečně lze spustit opakovaně.
#
# Instaluje:
#   1) systémové balíčky: curl gh git git-lfs jq ca-certificates
#   2) nvm (v0.40.1) + aktuální Node.js
#   3) GitHub Copilot CLI (@github/copilot) — generuje zprávy commitů a řeší konflikty
#   4) git-lfs hooky pro uživatele (git lfs install)
#   5) samotný git-agent → ~/.local/bin/git-agent (+ PATH v .bashrc/.zshrc)

set -euo pipefail

say() { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[setup] CHYBA:\033[0m %s\n' "$*" >&2; exit 1; }

SUDO=()
if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "spusť jako root, nebo nainstaluj sudo"
  SUDO=(sudo)
fi
sudo_maybe() { if ((${#SUDO[@]})); then "${SUDO[@]}" "$@"; else "$@"; fi; }

# argumenty: --cron = rovnou nainstaluj i hodinový cron job
CRON_INSTALL=0
for _a in "$@"; do
  case $_a in
    --cron) CRON_INSTALL=1 ;;
    -h|--help)
      printf 'Použití: %s [--cron]\n  --cron  nainstaluje i cron job (každou hodinu git-agent -g)\n' "$0"
      exit 0 ;;
    *) die "neznámý argument: $_a (podporuji --cron)" ;;
  esac
done

command -v curl >/dev/null 2>&1 || { sudo_maybe apt-get update -y && sudo_maybe apt-get install -y curl; }

# ---------------------------------------------------------------- 1) apt ----
if command -v apt-get >/dev/null 2>&1; then
  say "apt-get: curl gh git git-lfs jq ca-certificates bash-completion util-linux …"
  sudo_maybe apt-get update -y
  DEBIAN_FRONTEND=noninteractive sudo_maybe apt-get install -y \
    curl gh git git-lfs jq ca-certificates bash-completion util-linux
else
  say "apt-get nenalezen (nejde o Debian/Ubuntu) — předpokládám ručně nainstalované nástroje."
fi

for c in curl git gh git-lfs jq flock timeout; do
  command -v "$c" >/dev/null 2>&1 || die "chybí binárka '$c' — doinstaluj ji ručně a spusť setup znovu"
done

# -------------------------------------------------------------- 2) lfs ------
git lfs install >/dev/null 2>&1 && say "git-lfs hooky aktivní ($(git lfs version 2>/dev/null | awk '{print $3}'))"

# ---------------------------------------------------------- 3) nvm+node -----
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
  say "instaluji nvm v0.40.1 …"
  curl -fsSL -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi
set +e
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"
set -e
command -v nvm >/dev/null 2>&1 || die "nvm se nepodařilo načíst z $NVM_DIR/nvm.sh"

say "instaluji Node.js (aktuální verze) …"
nvm install node
nvm alias default node >/dev/null
say "Node.js: $(node -v) | npm: $(npm -v)"

# 3b) GitHub Copilot CLI
if ! command -v copilot >/dev/null 2>&1; then
  say "instaluji GitHub Copilot CLI (@github/copilot)…"
  npm install -g @github/copilot
else
  say "Copilot CLI již je: $(copilot --version 2>/dev/null || echo '?')"
fi

# ------------------------------------------------------- 5) git-agent -------
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
[[ -f "$SCRIPT_DIR/git-agent.sh" ]] || die "vedle setup.sh chybí git-agent.sh"

mkdir -p "$HOME/.local/bin"
install -m 0755 "$SCRIPT_DIR/git-agent.sh" "$HOME/.local/bin/git-agent"
install -m 0755 "$SCRIPT_DIR/git-agent-cron.sh" "$HOME/.local/bin/git-agent-cron"
say "instalováno: $HOME/.local/bin/git-agent (+ git-agent-cron)"

add_path_line() {
  local rc=$1
  [[ -f $rc ]] || : > "$rc"
  grep -qs 'HOME/\.local/bin' "$rc" || \
    printf '\n# added by git-agent setup\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
}
add_path_line "$HOME/.bashrc"
[[ -f "$HOME/.zshrc" ]] && add_path_line "$HOME/.zshrc"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

# ------------------------------------------------------------ 6) cron -------
if (( CRON_INSTALL )); then
  say "nastavuji cron: každou hodinu 'git-agent -g'"
  # crontab nástroj: vixie (crontab) nebo busybox (proot/Termux)
  CRON_SPOOL="/var/spool/cron/crontabs"
  cron_running() { pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1 \
                   || pgrep -f 'busybox crond' >/dev/null 2>&1; }
  CT=()
  if command -v crontab >/dev/null 2>&1; then
    CT=(crontab)
  elif command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx crontab; then
    mkdir -p "$CRON_SPOOL" 2>/dev/null || true
    CT=(busybox crontab -c "$CRON_SPOOL")
    say "vixie crontab není — používám busybox crontab/crond"
  else
    command -v apt-get >/dev/null 2>&1 && { DEBIAN_FRONTEND=noninteractive sudo_maybe apt-get install -y cron || true; }
    if command -v crontab >/dev/null 2>&1; then
      CT=(crontab)
    elif command -v busybox >/dev/null 2>&1; then
      mkdir -p "$CRON_SPOOL" 2>/dev/null || true
      CT=(busybox crontab -c "$CRON_SPOOL")
    else
      die "chybí crontab i busybox — nainstaluj cron ručně"
    fi
  fi
  _ctmp=$(mktemp)
  "${CT[@]}" -l 2>/dev/null | grep -v 'git-agent-cron' | grep -v '# git-agent: globální commit+push' > "$_ctmp" || true
  {
    printf '# git-agent: globální commit+push každou hodinu (smazáním řádku vypneš)\n'
    printf '0 * * * * %s/.local/bin/git-agent-cron\n' "$HOME"
  } >> "$_ctmp"
  "${CT[@]}" "$_ctmp" || die "nepodařilo se zapsat crontab"
  rm -f "$_ctmp"
  say "crontab: $("${CT[@]}" -l 2>/dev/null | grep 'git-agent-cron' | tail -n 1)"

  # když vixie crontab není, vytvoř tenký shim, aby fungovalo 'crontab -l/-e'
  if ! command -v crontab >/dev/null 2>&1 && command -v busybox >/dev/null 2>&1; then
    _shim=$(mktemp)
    printf '#!/bin/sh\nexec busybox crontab -c %s "$@"\n' "$CRON_SPOOL" > "$_shim"
    if sudo_maybe install -m 0755 "$_shim" /usr/local/bin/crontab 2>/dev/null; then
      say "vytvořen shim /usr/local/bin/crontab → busybox"
    else
      say "POZOR: crontab shim nevznikl — používej 'busybox crontab -c $CRON_SPOOL'"
    fi
    rm -f "$_shim"
  fi

  # daemon: service → cron → busybox crond (v prootu init neběží)
  if ! cron_running; then
    sudo_maybe service cron start >/dev/null 2>&1 \
      || sudo_maybe service crond start >/dev/null 2>&1 \
      || sudo_maybe /usr/sbin/cron >/dev/null 2>&1 \
      || sudo_maybe busybox crond -b -l 8 -c "$CRON_SPOOL" >/dev/null 2>&1 \
      || true
  fi
  if cron_running; then
    say "cron daemon běží ✓"
  else
    say "POZOR: cron daemon neběží — nastartuj ručně: sudo service cron start"
  fi

  # autostart při přihlášení shellu (proot/kontejner nemá init, cron po rebootu zmizí)
  ensure_cron_line() {
    local rc=$1
    [[ -f $rc ]] || : > "$rc"
    grep -qs 'git-agent: cron autostart' "$rc" && return 1
    {
      printf '\n# git-agent: cron autostart (proot/kontejner nemá init)\n'
      printf 'if command -v busybox >/dev/null 2>&1; then pgrep -f "busybox crond" >/dev/null 2>&1 || busybox crond -b -l 8 -c %s 2>/dev/null; fi\n' "$CRON_SPOOL"
    } >> "$rc"
    return 0
  }
  if ensure_cron_line "$HOME/.bashrc"; then
    say "autostart cronu přidán do ~/.bashrc (spustí se při přihlášení)"
  else
    say "autostart cronu už v ~/.bashrc je ✓"
  fi
  [[ -f "$HOME/.zshrc" ]] && ensure_cron_line "$HOME/.zshrc" || true
fi

# ------------------------------------------------------------ 7) tipy -------
git config --global user.email >/dev/null 2>&1 || say "TIP: git config --global user.email 'ty@example.cz'"
git config --global user.name  >/dev/null 2>&1 || say "TIP: git config --global user.name 'Tvé jméno'"
if command -v gh >/dev/null 2>&1 && ! gh auth status >/dev/null 2>&1; then
  say "TIP: spusť 'gh auth login' — gh jako credential helper zajistí push i do privátních repozitářů"
fi

say "Hotovo ✅  Zkus:  git-agent --help   |   git-agent          (lokálně)"
say "                git-agent -g         (globálně celý \$HOME)"
say "                git-agent pull       (fetch + pull, konflikty řeší copilot)"
say "                git-agent --add-lfs velky-soubor.bin"
(( CRON_INSTALL )) || say "                ./setup.sh --cron    (hodinový globální push)"
