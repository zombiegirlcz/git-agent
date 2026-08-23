#!/usr/bin/env bash
#
# git-agent — automatický commit & push všech nalezených git repozitářů.
# Pri konfliktu na pushi deleguje opravu na pi (https://pi.dev) v neinteraktivním
# režimu a následně OVĚŘÍ, že push skutečně prošel.
#
# Použití:
#   git-agent                  Lokální režim: projde aktuální složku (rekurzivně)
#   git-agent -g | --global    Globální režim: prohledá celý $HOME
#                              (kořen lze změnit: GIT_AGENT_GLOBAL_ROOT=/ git-agent -g)
#   git-agent -pi "úkol"      Spustí PI OKAMŽITĚ v aktuálním repozitři — dostane
#                             plný kontext repa + tvůj úkol (a při konfliktu
#                             během automatického pushu ho dostane také)
#   git-agent --add-lfs SOUBOR Přidá soubor do Git LFS ve svém repozáři a commitne
#   git-agent -h | --help      Nápověda
#   git-agent -V | --version   Verze
#
# Vlajky lze kombinovat, např.:  git-agent -g -pi "nedívej se do adresáře data/"
#
# Pravidla:
#   * Binárky větší než 100 MB se NIKDY necommitují — vynechají se a vypíše se
#     varování (řešením je `git-agent --add-lfs <soubor>`). Agent nikdy neřeší
#     problém zápisem do .gitignore.
#
# Proměnné prostředí:
#   GIT_AGENT_MAX_BYTES    limit velikosti souboru v bajtech (default: 104857600 = 100 MB)
#   GIT_AGENT_PI_BIN       binárka pi (default: pi)
#   GIT_AGENT_PI_TIMEOUT   timeout pro běh pi v sekundách (default: 1800)
#   GIT_AGENT_GLOBAL_ROOT  kořen globálního hledání (default: $HOME)
#   GIT_AGENT_LOG          soubor, kam se kompletní výstup přikládá (default: žádný)
#   GIT_AGENT_NO_COLOR=1   vypne barvy
#   GIT_AGENT_DRY_RUN=1    nic nemění, jen vypíše, co by udělal
#
# Notifikace (Android/NetHunter):
#   Průběh a výsledky chodí jako systémové notifikace přes `nh system
#   notification`. Defaultně ZAPNUTO — vypneš přes GIT_NOTIFI=0.

set -uo pipefail

VERSION="1.2.2"
PROG="git-agent"

# ---------------------------------------------------------------- nastavení --
MAX_BYTES="${GIT_AGENT_MAX_BYTES:-104857600}"          # 100 MB
PI_BIN="${GIT_AGENT_PI_BIN:-pi}"
PI_TIMEOUT="${GIT_AGENT_PI_TIMEOUT:-1800}"
GLOBAL_ROOT="${GIT_AGENT_GLOBAL_ROOT:-$HOME}"
COMMIT_TAG="git-agent"
LOG_FILE="${GIT_AGENT_LOG:-}"
GIT_NOTIFI="${GIT_NOTIFI:-1}"                     # notifikace přes nh: 1=zapnuto (výchozí)
NH_BIN="${GIT_AGENT_NH_BIN:-nh}"                  # binárka NetHunter CLI
NOTIFI_TIMEOUT="${GIT_AGENT_NOTIFY_TIMEOUT:-10}"  # timeout jedné notifikace [s]

# Adresáře, do kterých se při hledání repozitářů nikdy nevstupuje.
# (POZOR: .git sem nepatří — .git se řeší vlastním -prune -print krokem,
#  jinak by find nikdy žádný repozitář nenašel.)
PRUNE_NAMES=(
  node_modules bower_components vendor
  .venv venv __pycache__ .tox .mypy_cache .pytest_cache .ruff_cache
  .cache .npm .nvm .cargo .rustup .gradle .m2 .dotnet
  dist build target out coverage .terraform .terragrunt-cache
  .local/lib .cache/yarn .pnpm-store snap .Trash-1000 lost+found
  proc sys dev run
)

if [[ -n ${GIT_AGENT_NO_COLOR:-} || ! -t 1 ]]; then
  C_RED="" C_GREEN="" C_YEL="" C_CYAN="" C_BOLD="" C_DIM="" C_OFF=""
else
  C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YEL=$'\e[33m' C_CYAN=$'\e[36m'
  C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_OFF=$'\e[0m'
fi

info() { printf '%s\n' "${C_DIM}  ·${C_OFF} $*"; }
ok()   { printf '%s\n' "${C_GREEN}  ✓${C_OFF} $*"; }
warn() { printf '%s\n' "${C_YEL}  !${C_OFF} $*"; }
err()  { printf '%s\n' "${C_RED}  ✗${C_OFF} $*" >&2; }
hdr()  { printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_OFF"; }

# Systémová notifikace přes NetHunter CLI (nikdy nesmí rozbít běh agenta).
notify() {
  [[ $GIT_NOTIFI == 1 ]] || return 0
  command -v "$NH_BIN" >/dev/null 2>&1 || return 0
  local title=${1:-$PROG} body=${2:-}
  body=${body//$'\n'/ }
  timeout "$NOTIFI_TIMEOUT" "$NH_BIN" system notification -t "$title" -c "$body" >/dev/null 2>&1 || true
}
die()  { printf '%s%s: %s%s\n' "$C_RED" "$PROG" "$*" "$C_OFF" >&2; exit 2; }

usage() {
  # vytiskni celou úvodní komentářovou hlavičku (mezi shebang a prvním kódem)
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"
}

# ------------------------------------------------------------------- zámek --
# Bypass: GIT_AGENT_NO_LOCK=1 (např. v izolovaných prostředích se sdíleným /tmp,
# kde může držet neviditelný proces z jiného namespace).
if [[ ${GIT_AGENT_NO_LOCK:-0} != 1 ]] && command -v flock >/dev/null 2>&1; then
  LOCK_FILE="${GIT_AGENT_LOCKFILE:-${TMPDIR:-/tmp}/git-agent-${UID:-$(id -u)}.lock}"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "již běží jiná instance ($PROG). Vynutit: GIT_AGENT_NO_LOCK=1"
fi

if [[ -n $LOG_FILE ]]; then
  mkdir -p "$(dirname -- "$LOG_FILE")" 2>/dev/null || true
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

command -v git  >/dev/null 2>&1 || die "git není nainstalovaný (spusť setup.sh)."
command -v find >/dev/null 2>&1 || die "find není nainstalovaný."
command -v stat >/dev/null 2>&1 || die "stat není nainstalovaný."

# ------------------------------------------------------------------ stavy ----
SCANNED=0 DIRTY=0 COMMITTED=0 PUSHED=0 PI_CALLED=0
BIG_SKIPPED=() FAILED=()

cleanup() { [[ -n ${_PROMPT_TMP:-} ]] && rm -f -- "$_PROMPT_TMP"; }

# --- procesní hygiena -------------------------------------------------------
# pi po skončení nechává žít děti (qmd-server, node workery…) → spouštíme ho
# ve VLASTNÍ procesní skupině (setsid) a po běhu celou skupinu dočistíme.
PI_PID=""
stop_pi_group() {
  [[ -n ${PI_PID:-} ]] || return 0
  kill -TERM -- "-$PI_PID" 2>/dev/null || true
  sleep "${GIT_AGENT_KILL_GRACE:-0.5}" 2>/dev/null || sleep 1
  kill -KILL -- "-$PI_PID" 2>/dev/null || true
  wait "$PI_PID" 2>/dev/null || true   # reap zombíků
  PI_PID=""
}
on_exit() { stop_pi_group; cleanup; }
trap on_exit EXIT
trap 'on_exit; exit 130' INT
trap 'on_exit; exit 143' TERM

# Spustí pi (headline=$1, prompt=$2); výsledný rc uloží do _PI_RC.
# Subshell + exec setsid ⇒ PID subshellu se stane leaderem NOVÉ skupiny,
# kterou umíme spolehlivě zabít (i co timeout nedostal).
spawn_pi() {
  local headline=$1 pfile=$2 cwd=${3:-} rc
  (
    if [[ -n $cwd ]]; then cd -- "$cwd" || exit 99; fi
    exec setsid timeout "$PI_TIMEOUT" "$PI_BIN" -p --no-session "$headline" < "$pfile"
  ) &
  PI_PID=$!
  wait "$PI_PID"; rc=$?
  stop_pi_group
  _PI_RC=$rc
}

# --------------------------------------------------------------- hledání -----
find_repos() {
  local root=$1
  local args=("$root" "(")
  local first=1 p
  for p in "${PRUNE_NAMES[@]}"; do
    if (( first )); then args+=(-type d -name "$p"); first=0
    else args+=(-o -type d -name "$p"); fi
  done
  # (junk…) -prune -o ( -name .git -prune -print )
  #   → junk se přeskočí bez tisku, .git se vytiskne a nevstupuje se do něj
  args+=(")" -prune "-o" "(" -name ".git" -prune "-print" ")")
  find "${args[@]}" 2>/dev/null | sort -u
}

# ------------------------------------------------------- velké binárky -------
# Přidá všechny změny, ale soubory > MAX_BYTES okamžitě odstage (nikdy se
# necommitují). Vrací 1 pokud add selhal úplně.
stage_changes() {
  local repo=$1
  if [[ -n ${GIT_AGENT_DRY_RUN:-} ]]; then
    info "DRY-RUN: git add -A . (s filtrem souborů > $((MAX_BYTES / 1048576)) MB)"
    return 0
  fi
  if ! git -C "$repo" add -A . 2>/dev/null; then
    err "git add selhal v $repo"
    return 1
  fi
  local f sz
  while IFS= read -r -d '' f; do
    [[ -f "$repo/$f" ]] || continue           # smazané soubory přeskoč
    sz=$(stat -Lc %s "$repo/$f" 2>/dev/null) || continue
    if (( sz > MAX_BYTES )); then
      git -C "$repo" reset -q -- "$f"
      BIG_SKIPPED+=("$repo/$f")
      warn "VYNECHÁNO (binárka > $((MAX_BYTES / 1048576)) MB, necommituje se): $f"
      warn "  → řešení: $PROG --add-lfs \"$f\""
    fi
  done < <(git -C "$repo" diff --cached --name-only -z)
  return 0
}

# ------------------------------------------------------------ pi oprava ------
# Zavolá pi neinteraktivně s plným kontextem a poté ověří, že je vše pushnuté.
pi_resolve_and_push() {
  local repo=$1 branch=$2 remote=$3 push_err=$4
  (( PI_CALLED++ ))
  _PROMPT_TMP=$(mktemp)
  {
    cat <<EOF
ROLE
You are the automated repair subroutine of git-agent. An automatic "git push"
FAILED in the repository below. Your job: diagnose the exact cause from the
captured error, FIX it inside this repository (resolve conflicts, reconcile
with the remote), and finally make sure everything is COMMITTED and PUSHED.

REPOSITORY CONTEXT
- path:    $repo
- branch:  $branch
- remote:  $remote ($(git -C "$repo" remote get-url "$remote" 2>/dev/null || echo '?'))
- status:  $(git -C "$repo" status --porcelain=v1 | head -n 40)
- log:     $(git -C "$repo" log --oneline -5 2>/dev/null | tr '\n' ' ')

CAPTURED PUSH ERROR (stderr+stdout of the failed \`git push\`)
-----BEGIN ERROR-----
$push_err
-----END ERROR-----

HARD RULES
1. Work ONLY inside this repository. Do not touch other projects.
2. NEVER "solve" anything by adding entries to .gitignore — that is forbidden.
3. Files larger than 100 MB must NOT be committed; leave them untracked.
4. Prefer rebase/merge to reconcile with the remote. Do NOT use --force unless
   the error explicitly proves the remote history was replaced.
5. Commit message format: "\$(date '+%Y-%m-%d %H:%M:%S') ${COMMIT_TAG}-conflict".
6. You are DONE only when: git status is clean (large binaries may remain
   untracked) AND \`git rev-list --count @{upstream}..HEAD\` prints 0
   (everything pushed). Verify this yourself with bash before finishing.
EOF
    if [[ -n ${PI_CONTEXT} ]]; then
      printf '\nUSER-PROVIDED CONTEXT (higher priority than defaults)\n%s\n' "$PI_CONTEXT"
    fi
  } > "$_PROMPT_TMP"

  local headline="[git-agent] Push selhal v $repo (branch $branch) — diagnostikuj, oprav, pushni."
  if [[ -n ${GIT_AGENT_DRY_RUN:-} ]]; then
    info "DRY-RUN: $PI_BIN -p --no-session \"$headline\""
    _PI_RC=0
  else
    spawn_pi "$headline" "$_PROMPT_TMP" "$repo"
    rc=${_PI_RC:-0}
  fi

  if (( rc != 0 )); then
    err "pi skončilo s chybou (rc=$rc) — repo zůstává v konfliktu"
    FAILED+=("$repo (pi rc=$rc)")
    notify "git-agent: pi selhalo ✗" "$repo — pi skončilo chybou (rc=$rc), nutný ruční zásah"
    return 1
  fi

  # Ověření: opravdu je vše pushnuté a pracovní strom čistý?
  local up ahead
  # plný refname (refs/remotes/…) — zkrácené tvary mohou být při resoluci nejednoznačné
  up=$(git -C "$repo" rev-parse --symbolic-full-name '@{upstream}' 2>/dev/null || true)
  if [[ -n $up ]]; then
    ahead=$(git -C "$repo" rev-list --count "$up..HEAD" 2>/dev/null || echo 999)
  else
    ahead=999
  fi
  if (( ahead == 0 )); then
    ok "pi opravilo konflikt a push proběhl"
    (( PUSHED++ ))
    notify "git-agent: opraveno ✓" "$repo — pi vyřešilo konflikt a push proběhl"
    return 0
  fi
  err "pi nesplnilo cílový stav (ahead=$ahead) — vyžaduje ruční zásah"
  FAILED+=("$repo (po pi: ahead=$ahead)")
  notify "git-agent: nutný zásah ✗" "$repo — pi nesplnilo push (ahead=$ahead)"
  return 1
}

# ------------------------------------------------------------- pi přímé -----
# `git-agent -pi "úkol"` — spustí pi OKAMŽITĚ v aktuálním repozitři s plným
# kontextem repa + uživatelovým zadáním (bez čekání na konflikt).
run_pi_direct() {
  local task=$1
  [[ -n $task ]] || die "-pi vyžaduje úkol jako argument"
  local repo
  repo=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "-pi: nejsi uvnitř git repozitáře ($PWD)"
  command -v "$PI_BIN" >/dev/null 2>&1 \
    || die "pi nenalezeno (GIT_AGENT_PI_BIN=$PI_BIN) — spusť setup.sh"

  local branch remote ahead
  branch=$(git symbolic-ref --short -q HEAD 2>/dev/null || echo DETACHED)
  remote=$(git remote get-url "$(git remote | head -n1)" 2>/dev/null || echo '–')
  ahead=$(git rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 'n/a')

  hdr "▶ pi přímý úkol: $repo (branch $branch)"
  _PROMPT_TMP=$(mktemp)
  {
    cat <<EOF
ROLE
You are git-agent's on-demand subroutine running INSIDE the repository below.
The user gave you a task — complete it autonomously (you have full tool access).

REPOSITORY CONTEXT
- path:    $repo (cwd: $PWD)
- branch:  $branch
- remote:  $remote
- ahead:   $ahead (unpushed commits)
- status:
$(git status --porcelain=v1 | head -n 40)
- log:     $(git log --oneline -5 2>/dev/null | tr '\n' ' ')

HARD RULES
1. Work ONLY inside this repository.
2. NEVER solve anything by adding entries to .gitignore.
3. Files larger than 100 MB must NOT be committed; leave them untracked.
4. If you commit, message format: "\$(date '+%Y-%m-%d %H:%M:%S') ${COMMIT_TAG}-pi".
5. If the task involves syncing with the remote, you are DONE only when
   \`git rev-list --count @{upstream}..HEAD\` prints 0 and status is clean.
EOF
    printf '\nUSER TASK (highest priority)\n%s\n' "$task"
  } > "$_PROMPT_TMP"

  local rc=0
  if [[ -n ${GIT_AGENT_DRY_RUN:-} ]]; then
    info "DRY-RUN: $PI_BIN -p --no-session \"[git-agent] úloha…\""
    cat "$_PROMPT_TMP"
    _PI_RC=0
  else
    # pi potřebuje cwd = repozitář → cd uvnitř spawn wrapperu
    (
      exec setsid timeout "$PI_TIMEOUT" "$PI_BIN" -p --no-session \
        "[git-agent] úloha: ${task:0:120}" < "$_PROMPT_TMP"
    ) &
    PI_PID=$!
    wait "$PI_PID"; rc=$?
    stop_pi_group
  fi
  rm -f "$_PROMPT_TMP"

  if (( rc == 0 )); then
    ok "pi hotovo (rc=0) | ahead=$(git rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo n/a)"
    notify "git-agent: pi hotovo ✓" "${task:0:80}"
  else
    err "pi skončilo chybou (rc=$rc)"
    notify "git-agent: pi chyba ✗" "${task:0:80}"
  fi
  return "$rc"
}

# ----------------------------------------------------------------- push ------
push_if_needed() {
  local repo=$1 branch=$2 committed=$3
  local remote
  remote=$(git -C "$repo" remote | head -n 1 || true)
  if [[ -z $remote ]]; then
    (( committed )) && info "žádný remote — commit zůstal pouze lokálně"
    return 0
  fi

  local upstream
  upstream=$(git -C "$repo" rev-parse --symbolic-full-name '@{upstream}' 2>/dev/null || true)
  local ahead=0
  local -a push_args=(push)

  if [[ -n $upstream ]]; then
    ahead=$(git -C "$repo" rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)
  else
    # Bez upstreamu tiskneme jen když právě vznikl nový commit (nejmenší surprise).
    if (( committed )); then
      push_args=(-u "$remote" "$branch"); ahead=1
    else
      info "remote '$remote' existuje, ale větev nemá upstream — push vynechán"
      return 0
    fi
  fi

  (( ahead > 0 )) || { info "v synchronizaci s $remote"; return 0; }

  if [[ -n ${GIT_AGENT_DRY_RUN:-} ]]; then
    info "DRY-RUN: git ${push_args[*]}"
    return 0
  fi

  local out
  if out=$(git -C "$repo" "${push_args[@]}" 2>&1); then
    ok "push → $remote"
    (( PUSHED++ ))
    return 0
  fi

  warn "push zamítnut / konflikt — předávám pi…"
  printf '%s\n' "$out" | sed 's/^/    /' >&2
  notify "git-agent: konflikt ⚠" "push zamítnut v $repo (branch $branch) — řeší pi"
  pi_resolve_and_push "$repo" "$branch" "$remote" "$out"
}

# ------------------------------------------------------------ repozitář ------
process_repo() {
  local repo=$1
  (( SCANNED++ ))
  hdr "▶ $repo"

  local inside
  inside=$(git -C "$repo" rev-parse --is-inside-work-tree 2>/dev/null || echo false)
  [[ $inside == true ]] || { info "bare/plain adresář — přeskočeno"; return 0; }

  local branch
  branch=$(git -C "$repo" symbolic-ref --short -q HEAD || true)
  if [[ -z $branch ]]; then
    warn "detached HEAD — přeskočeno (vyžaduje ruční rozhodnutí)"
    return 0
  fi

  # 1) nezapomenuté lokální změny → add + commit
  local dirty committed=0
  dirty=$(git -C "$repo" status --porcelain=v1)
  if [[ -n $dirty ]]; then
    (( DIRTY++ ))
    stage_changes "$repo" || { FAILED+=("$repo (git add)"); return 1; }
    if ! git -C "$repo" diff --cached --quiet 2>/dev/null; then
      local msg
      msg="$(date '+%Y-%m-%d %H:%M:%S') $COMMIT_TAG"
      if [[ -n ${GIT_AGENT_DRY_RUN:-} ]]; then
        info "DRY-RUN: git commit -m \"$msg\""
        committed=1
      elif git -C "$repo" commit -q -m "$msg"; then
        ok "commit: $msg"
        (( COMMITTED++ )); committed=1
      else
        err "git commit selhal"
        FAILED+=("$repo (git commit)")
        return 1
      fi
    else
      info "změny pokryly jen vynechané soubory (>limit) — nic k commitu"
    fi
  fi

  # 2) nepushnuté commity → push (konflikt řeší pi)
  push_if_needed "$repo" "$branch" "$committed"
}

# -------------------------------------------------------------- --add-lfs ----
do_add_lfs() {
  local target=$1
  [[ -e $target ]] || die "--add-lfs: soubor neexistuje: $target"
  git lfs version >/dev/null 2>&1 || die "git-lfs není nainstalované (spusť setup.sh)"

  local abs dir repo base
  abs=$(readlink -f -- "$target")
  dir=$(dirname -- "$abs")
  base=$(basename -- "$abs")
  repo=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) \
    || die "--add-lfs: $abs leží mimo jakýkoli git repozitář"

  hdr "▶ LFS: $abs"
  git -C "$repo" lfs install >/dev/null || { err "git lfs install selhal"; return 1; }
  git -C "$repo" lfs track -- "$base" >/dev/null || { err "git lfs track selhal"; return 1; }
  git -C "$repo" add -- .gitattributes "$abs" || { err "git add selhal"; return 1; }

  if git -C "$repo" diff --cached --quiet 2>/dev/null; then
    info "soubor už je ve LFS — nic k commitu"
    return 0
  fi
  local msg="$(date '+%Y-%m-%d %H:%M:%S') ${COMMIT_TAG}-lfs: $base"
  git -C "$repo" commit -q -m "$msg" || { err "git commit selhal"; return 1; }
  ok "commit: $msg"

  local branch remote
  branch=$(git -C "$repo" symbolic-ref --short -q HEAD || true)
  remote=$(git -C "$repo" remote | head -n 1 || true)
  if [[ -n $remote && -n $branch ]]; then
    if git -C "$repo" push -u "$remote" "$branch" 2>&1 | sed 's/^/    /'; then
      ok "push → $remote"
    else
      err "push selhal — spusť $PROG v $repo pro automatickou opravu"
      return 1
    fi
  fi
}

# ---------------------------------------------------------------- shrnutí ----
summary() {
  hdr "══ Shrnutí ══"
  printf '  repozitářů: %d | se změnami: %d | commitů: %d | pushů: %d | volání pi: %d\n' \
    "$SCANNED" "$DIRTY" "$COMMITTED" "$PUSHED" "$PI_CALLED"
  local x
  for x in "${BIG_SKIPPED[@]:-}"; do
    [[ -n $x ]] && warn "necommitnuto (>100 MB): $x"
  done
  local fails=0
  for x in "${FAILED[@]:-}"; do
    [[ -n $x ]] && { err "SELHALO: $x"; fails=$((fails + 1)); }
  done
  if (( fails == 0 )); then
    ok "vše hotovo"
    notify "git-agent ✓" "hotovo: $SCANNED repozitářů, $COMMITTED commitů, $PUSHED pushů"
  else
    err "celkem selhání: $fails"
    notify "git-agent: selhání ($fails) ✗" "repo:$SCANNED commit:$COMMITTED push:$PUSHED pi:$PI_CALLED — zkontroluj log"
  fi
  (( fails > 125 )) && fails=125
  return "$fails"
}

# ------------------------------------------------------------------ main -----
mode_local=1
PI_CONTEXT=""
lfs_file=""
direct_pi=0

while (($#)); do
  case "$1" in
    -g|--global)   mode_local=0 ;;
    -pi|--pi|-P)
      [[ $# -ge 2 && -n ${2:-} ]] || die "$1 vyžaduje argument (úkol pro pi)"
      PI_CONTEXT=$2; direct_pi=1; shift ;;
    --add-lfs)
      [[ $# -ge 2 && -n ${2:-} ]] || die "$1 vyžaduje argument (cesta k souboru)"
      lfs_file=$2; shift ;;
    -h|--help)     usage; exit 0 ;;
    -V|--version)  echo "$PROG $VERSION"; exit 0 ;;
    *)
      err "neznámá volba: $1"
      usage >&2
      exit 2 ;;
  esac
  shift
done

hdr "══ $PROG v$VERSION ══"

if [[ -n $lfs_file ]]; then
  do_add_lfs "$lfs_file"
  exit $?
fi

if (( direct_pi )); then
  run_pi_direct "$PI_CONTEXT"
  exit $?
fi

local_root=$PWD
root=$local_root
(( mode_local )) || root=$GLOBAL_ROOT
[[ -d $root ]] || die "kořen prohledávání neexistuje: $root"

if (( mode_local )); then
  printf '%s\n' "${C_DIM}režim: lokální ($root)${C_OFF}"
else
  printf '%s\n' "${C_DIM}režim: globální ($root)${C_OFF}"
fi

# nalezení a deduplikace repozitářů (worktree ukazují na stejný toplevel)
declare -A SEEN=()
gitpaths=()
while IFS= read -r gp; do
  [[ -n $gp ]] && gitpaths+=("$gp")
done < <(find_repos "$root")

if ((${#gitpaths[@]} == 0)); then
  info "nenalezen žádný git repozitář pod $root"
  exit 0
fi

for gp in "${gitpaths[@]}"; do
  dir=$(dirname -- "$gp")
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || continue
  key=$(readlink -f -- "$top" 2>/dev/null || printf '%s' "$top")
  [[ -n ${SEEN[$key]+x} ]] && continue
  SEEN["$key"]=1
  process_repo "$top" || true
done

summary
exit $?   # exit kód = počet selhavších repozitářů (max 125)
