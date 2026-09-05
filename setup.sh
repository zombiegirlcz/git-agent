#!/usr/bin/env bash
#
# setup.sh — instalace všeho, co git-agent potřebuje.
# Idempotentní: bezpečně lze spustit opakovaně.
#
# Instaluje:
#   1) systémové balíčky: curl gh git git-lfs jq ca-certificates
#   2) nvm (v0.40.1) + aktuální Node.js
#   3) pi (https://pi.dev)  — AI agent pro řešení konfliktů
#   4) git-lfs hooky pro uživatele (git lfs install)
#   5) samotný git-agent → ~/.local/bin/git-agent (+ PATH v .bashrc/.zshrc)

set -euo pipefail

say() { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[setup] CHYBA:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "spusť jako root, nebo nainstaluj sudo"
fi

command -v curl >/dev/null 2>&1 || {  apt-get update -y &&  apt-get install -y curl; }

# ---------------------------------------------------------------- 1) apt ----
if command -v apt-get >/dev/null 2>&1; then
  say "apt-get: curl gh git git-lfs jq ca-certificates bash-completion util-linux …"
   apt-get update -y
   DEBIAN_FRONTEND=noninteractive apt-get install -y \
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

# --------------------------------------------------------------- 4) pi ------
if ! command -v pi >/dev/null 2>&1; then
  say "instaluji pi …"
  curl -fsSL https://pi.dev/install.sh | bash
else
  say "pi již je instalované: $(command -v pi)"
fi

# ------------------------------------------------------- 5) git-agent -------
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
[[ -f "$SCRIPT_DIR/git-agent.sh" ]] || die "vedle setup.sh chybí git-agent.sh"

mkdir -p "$HOME/.local/bin"
install -m 0755 "$SCRIPT_DIR/git-agent.sh" "$HOME/.local/bin/git-agent"
say "instalováno: $HOME/.local/bin/git-agent"

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

# ------------------------------------------------------------ 6) tipy -------
git config --global user.email >/dev/null 2>&1 || say "TIP: git config --global user.email 'ty@example.cz'"
git config --global user.name  >/dev/null 2>&1 || say "TIP: git config --global user.name 'Tvé jméno'"
if command -v gh >/dev/null 2>&1 && ! gh auth status >/dev/null 2>&1; then
  say "TIP: spusť 'gh auth login' — gh jako credential helper zajistí push i do privátních repozitářů"
fi

say "Hotovo ✅  Zkus:  git-agent --help   |   git-agent          (lokálně)"
say "                git-agent -g         (globálně celý \$HOME)"
say "                git-agent --add-lfs velky-soubor.bin"
