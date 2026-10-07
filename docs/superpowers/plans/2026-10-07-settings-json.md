# settings.json Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Řídit `git-agent` z globálního `~/.config/git-agent/settings.json` (ignore repa, výběr větví k pushi, merge `from`→`to` přes PR, vlastní prompt pro copilota) a nalezená repa do něj automaticky zapisovat s výchozím nastavením.

**Architecture:** Nová sekce „settings" v `git-agent.sh`: `load_settings` (jednou), `settings_match_key` + `load_repo_settings` (per repo, přes `jq`), `register_repos` (po hledání repozitářů). `process_repo`/`pull_repo` se po commitu napojí na `push_branches` (nahrazuje přímé volání `push_if_needed`) a `merge_via_pr`. Copilot se dál volá výhradně přes `spawn_agent`.

**Tech Stack:** bash, `jq`, `gh`, git; testy `tests/run-tests.sh` (offline, stuby `copilot`, `git-lfs`, nově `gh`).

**Spec:** `docs/superpowers/specs/2026-10-07-settings-json-design.md`

## Global Constraints

- Jen bash + `jq` (už instaluje `setup.sh`); žádné nové závislosti. Bez `jq` agent funguje jako dnes (settings se nepoužijí, jen varování, pokud soubor existuje).
- Soubor: `~/.config/git-agent/settings.json`, přepis přes `GIT_AGENT_SETTINGS=<cesta>`; jen globální soubor, žádné per-repo `.git-agent.json`.
- Zprávy, komentáře a README česky; commity ve formátu `feat: …` + trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Copilot se volá jen přes `spawn_agent` (neinteraktivně). Jediná výjimka: `git-agent setting -co` spouští interaktivního copilota (`copilot -i <prompt>`) v popředí na terminálu; nikdy `--force`, nikdy zápis do `.gitignore`.
- Existující položky v `settings.json` se nikdy nemění ani nemažou, zápis je atomický (`jq` → tmp → `mv`), poškozený JSON se nepřepisuje.
- Nastavení chybí / je neplatné → chování jako dnes (`ignore:false`, `push:"current"`, bez merge, bez `conflict_prompt`).
- Řádek souhrnu: nová pole jen **přidávat na konec**, `git-agent-cron.sh` parsuje `…commitů: N | pullů: N | pushů: N` (regex zůstává funkční).
- Testy jsou offline, nikdy nesahají na skutečné `~/.config` ani skutečné `gh`; `GIT_AGENT_SETTINGS` v testech míří do sandboxu.
- Baseline: před začátkem `tests/run-tests.sh` hlásí `72 ok, 2 FAIL` (jedno z nich `J5: pullů v souhrnu`). Žádný task nesmí zvýšit počet FAIL nad baseline.

## Review Focus

Vstupy, které spec implicitně předpokládá a žádný „šťastný" test je nepokrývá (každý má test u vlastnícího tasku):

1. Cesta repa s mezerou a `[` (`my repo [1]`) — musí se zapsat jako přesný klíč a při druhém běhu se nezapsat znovu (task 2, R1/R2).
2. Prázdný (0 B) `settings.json` — chová se jako chybějící soubor, ne jako „poškozený" (task 2, R5).
3. Neplatné hodnoty (`push: 5`, `merge.from == merge.to`, neznámý klíč) — varování a výchozí hodnota pro daný klíč, běh nekončí chybou (task 1, K3).
4. `conflict_prompt` s `$(…)`, zpětnými apostrofy a uvozovkami — do promptu se dostane doslova, nic se nespustí (task 4, C1).
5. `push` seznam obsahující neexistující větev — varování, ne selhání repa (task 3, P4).
6. `git-agent setting` nesmí držet zámek, přesměrovat výstup do logu ani nic zapisovat do settings.json (jen `-co` pustí copilota); neznámá volba končí kódem 2 (task 6, S1–S5).

---

### Task 1: Načtení settings a ignore

**Files:**
- Modify: `git-agent.sh` (nastavení, nová sekce settings před `find_repos`, `process_repo`, `pull_repo`, `summary`, `main`)
- Test: `tests/run-tests.sh`

**Interfaces:**
- Consumes: `warn`, `info`, `hdr` (existující).
- Produces:
  - globály `SETTINGS_FILE`, `SETTINGS_STATE` (`off|missing|valid|invalid`), `IGNORED`;
  - `load_settings` (bez argumentů, nastaví `SETTINGS_STATE`);
  - `settings_match_key <abs-path>` → vypíše klíč z `.repos` (rc 0) nebo rc 1;
  - `load_repo_settings <repo>` → nastaví `REPO_IGNORE` (0/1), `REPO_PUSH` (JSON: `"current"`, `"all"` nebo `["a","b"]`), `REPO_MERGE_FROM`, `REPO_MERGE_TO`, `REPO_MERGE_STRATEGY`, `REPO_CONFLICT_PROMPT`.

- [ ] **Step 1: Zapsat baseline a napsat padající testy**

```bash
cd /root/git-agent && tests/run-tests.sh 2>&1 | grep -a FAIL | tee /tmp/claude-0/-root-git-agent/18fbeffb-1e83-4439-980c-9905c8f821ca/scratchpad/baseline-fails.txt
```
Expected: 2 řádky FAIL (baseline).

V `tests/run-tests.sh` přidej k ostatním exportům (hned za `export PATH="$STUB:$PATH"`):

```bash
export GIT_AGENT_SETTINGS="$SB/settings.json"
rp() { readlink -f -- "$1"; }
```
Do lint sekce za `chk "bash -n setup.sh" …`:

```bash
chk "jq dostupné (nutné pro settings)" command -v jq
```
Před blok `# --- konec ---` přidej:

```bash
# ------------------------------------------------------------ K: settings ----
printf '\n== K: settings.json (ignore, priorita, neplatné hodnoty) ==\n'
K="$SB/k"; mkrepo "$K/r1"; mkrepo "$K/r2"
echo x > "$K/r1/n.txt"; echo x > "$K/r2/n.txt"
cat > "$GIT_AGENT_SETTINGS" <<EOF
{ "repos": { "$(rp "$K")/*": { "ignore": true }, "$(rp "$K/r1")": { "ignore": false } } }
EOF
out=$(GIT_AGENT_NO_COMMIT_MESSAGE=1 run_agent "$K"); rc=$?; saveout "$out" "$SB/k1.out"
chk     "K1: exit kód 0"                       test "$rc" -eq 0
chk     "K1: r1 (přesná cesta) commitnuto"     test "$(git -C "$K/r1" rev-list --count HEAD)" -eq 2
chk     "K1: r2 (glob ignore) necommitnuto"    test "$(git -C "$K/r2" rev-list --count HEAD)" -eq 1
chk_out "K1: hlášení ignorováno"               "ignorováno" "$SB/k1.out"

echo '{oops' > "$GIT_AGENT_SETTINGS"; echo y > "$K/r1/m.txt"
out=$(GIT_AGENT_NO_COMMIT_MESSAGE=1 run_agent "$K"); rc=$?; saveout "$out" "$SB/k2.out"
chk     "K2: exit kód 0"                       test "$rc" -eq 0
chk     "K2: r1 se normálně commitlo"          test "$(git -C "$K/r1" rev-list --count HEAD)" -eq 3
chk_out "K2: varování o poškozeném souboru"    "poškozen" "$SB/k2.out"
chk     "K2: soubor nezměněn"                  test "$(cat "$GIT_AGENT_SETTINGS")" = '{oops'

cat > "$GIT_AGENT_SETTINGS" <<EOF
{ "repos": { "$(rp "$K/r1")": { "push": 5, "merge": {"from":"a","to":"a"}, "bogus": 1 } } }
EOF
echo z > "$K/r1/q.txt"
out=$(GIT_AGENT_NO_COMMIT_MESSAGE=1 run_agent "$K"); rc=$?; saveout "$out" "$SB/k3.out"
chk     "K3: exit kód 0"                       test "$rc" -eq 0
chk_out "K3: neplatné push"                    "neplatn.*push" "$SB/k3.out"
chk_out "K3: neplatné merge"                   "neplatn.*merge" "$SB/k3.out"
chk_out "K3: neznámý klíč"                     "neznámý klíč" "$SB/k3.out"
chk     "K3: r1 se commitlo i tak"             test "$(git -C "$K/r1" rev-list --count HEAD)" -eq 4
```

- [ ] **Step 2: Spustit a ověřit selhání**

Run: `tests/run-tests.sh 2>&1 | grep -a 'K[123]:'`
Expected: K1 „r2 necommitnuto" FAIL, K1 „ignorováno" FAIL, K2 „poškozen" FAIL, K3 „neplatn…" FAIL.

- [ ] **Step 3: Implementace v `git-agent.sh`**

3a. V sekci „nastavení" za řádek s `NOTIFI_TIMEOUT=` přidej:

```bash
SETTINGS_FILE="${GIT_AGENT_SETTINGS:-${XDG_CONFIG_HOME:-$HOME/.config}/git-agent/settings.json}"
SETTINGS_STATE=off     # off (bez jq) | missing | valid | invalid
SETTINGS_DEFAULTS='{"ignore":false,"push":"current"}'
```
3b. Do řádku stavů přidej `IGNORED=0 NEW_REPOS=0 MERGED=0`:

```bash
SCANNED=0 DIRTY=0 COMMITTED=0 PUSHED=0 COPILOT_CALLED=0 PULLED=0 IGNORED=0 NEW_REPOS=0 MERGED=0
```
3c. Nová sekce těsně před `# --- hledání ---` (`find_repos`):

```bash
# ------------------------------------------------------------- settings ------
# ~/.config/git-agent/settings.json — viz README. Chybí / neplatné → defaulty.
load_settings() {
  if ! command -v jq >/dev/null 2>&1; then
    [[ -s $SETTINGS_FILE ]] && warn "jq chybí — settings.json se nepoužije (spusť setup.sh)"
    SETTINGS_STATE=off; return 0
  fi
  if [[ ! -s $SETTINGS_FILE ]]; then SETTINGS_STATE=missing; return 0; fi
  if jq -e 'type == "object" and ((.repos // {}) | type == "object") and ((.defaults // {}) | type == "object")' \
       "$SETTINGS_FILE" >/dev/null 2>&1; then
    SETTINGS_STATE=valid
  else
    warn "settings.json je poškozený nebo má špatný tvar ($SETTINGS_FILE) — používám výchozí nastavení a nezapisuji"
    SETTINGS_STATE=invalid
  fi
}

# Klíč z .repos pro absolutní cestu: přesná shoda má přednost, pak globy v pořadí
# souboru (první shoda vyhrává; ~ se expanduje). Vypíše klíč, rc 1 = žádná shoda.
settings_match_key() {
  [[ $SETTINGS_STATE == valid ]] || return 1
  local repo=$1 k pat
  if jq -e --arg p "$repo" '(.repos // {}) | has($p)' "$SETTINGS_FILE" >/dev/null 2>&1; then
    printf '%s' "$repo"; return 0
  fi
  while IFS= read -r k; do
    pat=${k/#\~/$HOME}
    # shellcheck disable=SC2053
    if [[ $repo == $pat ]]; then printf '%s' "$k"; return 0; fi
  done < <(jq -r '(.repos // {}) | keys_unsorted[]' "$SETTINGS_FILE" 2>/dev/null)
  return 1
}

# Nastaví REPO_* pro dané repo (defaults ← .defaults ← .repos[klíč]).
load_repo_settings() {
  local repo key json unk v mf mt ms
  repo=$(readlink -f -- "$1" 2>/dev/null || printf '%s' "$1")
  REPO_IGNORE=0 REPO_PUSH='"current"'
  REPO_MERGE_FROM="" REPO_MERGE_TO="" REPO_MERGE_STRATEGY=merge REPO_CONFLICT_PROMPT=""
  [[ $SETTINGS_STATE == valid ]] || return 0
  key=$(settings_match_key "$repo") || key=""
  json=$(jq -c --arg k "$key" --argjson d "$SETTINGS_DEFAULTS" \
    '$d + (.defaults // {}) + (if $k != "" then (.repos[$k] | if type == "object" then . else {} end) else {} end)' \
    "$SETTINGS_FILE" 2>/dev/null) || json=""
  [[ -n $json ]] || return 0

  unk=$(jq -r 'keys - ["ignore","push","merge","conflict_prompt"] | join(", ")' <<<"$json")
  [[ -z $unk ]] || warn "settings.json: neznámý klíč ($unk) u $repo — ignoruji"

  [[ $(jq -r '.ignore' <<<"$json") == true ]] && REPO_IGNORE=1

  if jq -e '.push == "current" or .push == "all" or (.push | (type == "array") and (length > 0) and all(.[]; type == "string"))' \
       <<<"$json" >/dev/null 2>&1; then
    REPO_PUSH=$(jq -c '.push' <<<"$json")
  else
    warn "settings.json: neplatná hodnota 'push' u $repo — použito 'current'"
  fi

  if jq -e 'has("merge")' <<<"$json" >/dev/null 2>&1; then
    mf=$(jq -r '.merge | objects | .from // ""' <<<"$json" 2>/dev/null)
    mt=$(jq -r '.merge | objects | .to // ""' <<<"$json" 2>/dev/null)
    ms=$(jq -r '.merge | objects | .strategy // "merge"' <<<"$json" 2>/dev/null)
    if [[ -z $mf || -z $mt || $mf == "$mt" ]]; then
      warn "settings.json: neplatné 'merge' u $repo (nutné různé 'from' a 'to') — merge přeskočen"
    else
      case $ms in
        merge|squash|rebase) ;;
        *) warn "settings.json: neplatná 'strategy' ($ms) u $repo — použito 'merge'"; ms=merge ;;
      esac
      REPO_MERGE_FROM=$mf REPO_MERGE_TO=$mt REPO_MERGE_STRATEGY=$ms
    fi
  fi

  v=$(jq -r '.conflict_prompt | strings' <<<"$json" 2>/dev/null) || v=""
  REPO_CONFLICT_PROMPT=$v
}
```
3d. `process_repo` — nahraď úvod (`(( SCANNED++ ))` + `hdr`) takto:

```bash
process_repo() {
  local repo=$1
  hdr "▶ $repo"
  load_repo_settings "$repo"
  if (( REPO_IGNORE )); then
    info "ignorováno (settings.json)"; (( IGNORED++ )); return 0
  fi
  (( SCANNED++ ))
```
Stejný úvod do `pull_repo` (hlavička tam je `hdr "▶ $repo (pull: $PULL_MODE)"` — zachovej ji místo `hdr "▶ $repo"`).

3e. `summary()` — rozšiř řádek (nová pole na konec):

```bash
  printf '  repozitářů: %d | se změnami: %d | commitů: %d | pullů: %d | pushů: %d | volání copilot: %d | nových repozitářů: %d | ignorováno: %d | mergů: %d\n' \
    "$SCANNED" "$DIRTY" "$COMMITTED" "$PULLED" "$PUSHED" "$COPILOT_CALLED" "$NEW_REPOS" "$IGNORED" "$MERGED"
```
3f. `main` — těsně za výpis `režim: …` (před `declare -A SEEN`) přidej `load_settings`.

- [ ] **Step 4: Spustit testy**

Run: `tests/run-tests.sh 2>&1 | grep -a 'K[123]:\|výsledek'`
Expected: všechny K1–K3 `ok`; `výsledek:` nehorší než baseline (2 FAIL).

- [ ] **Step 5: Commit**

```bash
git add git-agent.sh tests/run-tests.sh
git commit -m "feat: settings.json — načtení, ignore repozitářů, validace hodnot

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Automatická registrace repozitářů

**Files:**
- Modify: `git-agent.sh` (nová `register_repos`, hlavní smyčka v `main`)
- Test: `tests/run-tests.sh`

**Interfaces:**
- Consumes: `load_settings`, `settings_match_key`, `SETTINGS_STATE`, `NEW_REPOS` (task 1).
- Produces: `register_repos <repo>...` (zapíše chybějící repa; nastaví `NEW_REPOS` a po zápisu `SETTINGS_STATE=valid`).

- [ ] **Step 1: Napsat padající testy** (před `# --- konec ---`)

```bash
# --------------------------------------------------- R: auto-registrace ------
printf '\n== R: automatická registrace repozitářů ==\n'
R="$SB/r"; mkrepo "$R/r1"; mkrepo "$R/my repo [1]"
rm -f "$GIT_AGENT_SETTINGS"
out=$(run_agent "$R"); rc=$?; saveout "$out" "$SB/r1.out"
chk     "R1: exit kód 0"                       test "$rc" -eq 0
chk     "R1: soubor vznikl a je validní JSON"  jq -e . "$GIT_AGENT_SETTINGS"
chk     "R1: oba repozitáře zapsány"           test "$(jq '.repos | length' "$GIT_AGENT_SETTINGS")" -eq 2
chk     "R1: výchozí hodnoty u položky"        jq -e --arg k "$(rp "$R/r1")" '.repos[$k] == {"ignore":false,"push":"current"} and .defaults.push == "current"' "$GIT_AGENT_SETTINGS"
chk     "R1: cesta s mezerou a [ je klíč"      jq -e --arg k "$(rp "$R/my repo [1]")" '.repos | has($k)' "$GIT_AGENT_SETTINGS"
chk_out "R1: souhrn nových repozitářů"         'nových repozitářů:\s*2' "$SB/r1.out"
# regex cron wrapperu (git-agent-cron.sh) musí dál fungovat
line=$(grep -a -E 'repozitářů:.*commitů:' "$SB/r1.out" | tail -n 1)
nums=$(printf '%s\n' "$line" | sed -n 's/.*commitů: \([0-9]*\) | pullů: \([0-9]*\) | pushů: \([0-9]*\).*/\1 \2 \3/p')
chk     "R1: regex cron wrapperu na souhrn"    test -n "$nums"

sum1=$(cksum < "$GIT_AGENT_SETTINGS")
out=$(run_agent "$R"); saveout "$out" "$SB/r2.out"
chk     "R2: druhý běh soubor nezměnil"        test "$(cksum < "$GIT_AGENT_SETTINGS")" = "$sum1"
chk_out "R2: souhrn nových = 0"                'nových repozitářů:\s*0' "$SB/r2.out"

jq --arg k "$(rp "$R/r1")" '.repos[$k] = {"ignore":false,"push":["main"],"conflict_prompt":"x"}' "$GIT_AGENT_SETTINGS" > "$SB/tmp.json" && mv "$SB/tmp.json" "$GIT_AGENT_SETTINGS"
mkrepo "$R/r3"
out=$(run_agent "$R")
chk     "R3: upravená položka zůstala"         jq -e --arg k "$(rp "$R/r1")" '.repos[$k].push == ["main"] and .repos[$k].conflict_prompt == "x"' "$GIT_AGENT_SETTINGS"
chk     "R3: nové repo r3 přidáno"             jq -e --arg k "$(rp "$R/r3")" '.repos | has($k)' "$GIT_AGENT_SETTINGS"

rm -f "$GIT_AGENT_SETTINGS"
out=$(GIT_AGENT_DRY_RUN=1 run_agent "$R"); saveout "$out" "$SB/r4.out"
chk     "R4: dry-run soubor nevytvořil"        test ! -e "$GIT_AGENT_SETTINGS"
chk_out "R4: dry-run hlásí zápis"              "DRY-RUN.*settings" "$SB/r4.out"

: > "$GIT_AGENT_SETTINGS"
out=$(run_agent "$R")
chk     "R5: prázdný soubor = jako chybějící"  test "$(jq '.repos | length' "$GIT_AGENT_SETTINGS")" -eq 3

echo '{oops' > "$GIT_AGENT_SETTINGS"
out=$(run_agent "$R")
chk     "R6: poškozený soubor se nepřepíše"    test "$(cat "$GIT_AGENT_SETTINGS")" = '{oops'

mkdir -p "$R/glob"; mkrepo "$R/glob/g1"
cat > "$GIT_AGENT_SETTINGS" <<EOF
{ "repos": { "$(rp "$R/glob")/*": { "ignore": true } } }
EOF
out=$(run_agent "$R/glob")
chk     "R7: repo pokryté globem se nezapisuje" test "$(jq '.repos | length' "$GIT_AGENT_SETTINGS")" -eq 1
```

- [ ] **Step 2: Ověřit selhání**

Run: `tests/run-tests.sh 2>&1 | grep -a 'R[1-7]:'`
Expected: R1–R5, R7 FAIL (soubor se nevytváří / `nových repozitářů` chybí hodnoty); R6 může náhodou projít.

- [ ] **Step 3: Implementace**

3a. Do sekce settings za `load_repo_settings` přidej:

```bash
# Zapíše nalezená repa, která nemají ani přesný klíč, ani shodu globu, s defaulty.
# Existující položky se nemění; zápis je atomický; poškozený soubor se nepřepisuje.
register_repos() {
  NEW_REPOS=0
  [[ $SETTINGS_STATE == off || $SETTINGS_STATE == invalid ]] && return 0
  local -a new=()
  local r key
  for r in "$@"; do
    key=$(readlink -f -- "$r" 2>/dev/null || printf '%s' "$r")
    settings_match_key "$key" >/dev/null || new+=("$key")
  done
  ((${#new[@]})) || return 0
  NEW_REPOS=${#new[@]}
  if [[ -n ${GIT_AGENT_DRY_RUN:-} ]]; then
    info "DRY-RUN: do settings.json by se zapsalo $NEW_REPOS repozitářů"
    return 0
  fi
  local keys tmp input
  keys=$(printf '%s\n' "${new[@]}" | jq -R . | jq -s .)
  if [[ $SETTINGS_STATE == valid ]]; then
    input=$(cat -- "$SETTINGS_FILE")
  else
    input='{"defaults":{"ignore":false,"push":"current"},"repos":{}}'
  fi
  mkdir -p -- "$(dirname -- "$SETTINGS_FILE")" 2>/dev/null \
    && tmp=$(mktemp "$SETTINGS_FILE.XXXXXX" 2>/dev/null) \
    || { warn "settings.json: nelze zapisovat do $(dirname -- "$SETTINGS_FILE")"; NEW_REPOS=0; return 0; }
  if printf '%s' "$input" | jq --argjson keys "$keys" \
       '.repos = ((.repos // {}) + ($keys | map({key: ., value: {ignore: false, push: "current"}}) | from_entries))' \
       > "$tmp" 2>/dev/null && mv -f -- "$tmp" "$SETTINGS_FILE"; then
    SETTINGS_STATE=valid
    ok "settings.json: zapsáno $NEW_REPOS nových repozitářů"
  else
    rm -f -- "$tmp"
    warn "settings.json: zápis selhal — soubor zůstal beze změny"
    NEW_REPOS=0
  fi
}
```
3b. V `main` nahraď smyčku `for gp in "${gitpaths[@]}"; do … done` dvěma průchody:

```bash
declare -A SEEN=()
repos=()
for gp in "${gitpaths[@]}"; do
  dir=$(dirname -- "$gp")
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || continue
  key=$(readlink -f -- "$top" 2>/dev/null || printf '%s' "$top")
  [[ -n ${SEEN[$key]+x} ]] && continue
  SEEN["$key"]=1
  repos+=("$top")
done

register_repos ${repos[@]+"${repos[@]}"}

for top in ${repos[@]+"${repos[@]}"}; do
  if [[ $ACTION == pull ]]; then
    pull_repo "$top" || true
  else
    process_repo "$top" || true
  fi
done
```
(původní `declare -A SEEN=()` a `gitpaths` sběr nad tím zůstává; odstraň jen duplicitní `declare`.)

- [ ] **Step 4: Spustit testy**

Run: `tests/run-tests.sh 2>&1 | grep -a 'K[123]:\|R[1-7]:\|výsledek'`
Expected: vše `ok`; celkově nehorší než baseline.

- [ ] **Step 5: Commit**

```bash
git add git-agent.sh tests/run-tests.sh
git commit -m "feat: automatická registrace nalezených repozitářů do settings.json

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Výběr větví k pushi

**Files:**
- Modify: `git-agent.sh` (nové `push_targets`, `push_other_branch`, `push_branches`; volání v `process_repo` a `pull_repo`)
- Test: `tests/run-tests.sh`

**Interfaces:**
- Consumes: `REPO_PUSH`, `push_if_needed <repo> <branch> <committed>` (existující), `FAILED`, `PUSHED`, `notify`.
- Produces: `push_branches <repo> <branch> <committed>` → rc 0 = vše pushnuto/nic k pushi, rc 1 = selhání. Tuto funkci volají task 5 (přes `finish_repo`) i oba toky.

- [ ] **Step 1: Napsat padající testy**

```bash
# ------------------------------------------------------- P: push větví -------
printf '\n== P: push větví (current / all / seznam) ==\n'
mkpush_fixture() {
  local base=$1 b
  mkdir -p "$base"
  git init -q --bare -b main "$base/origin.git" 2>/dev/null || git init -q --bare "$base/origin.git"
  mkrepo "$base/work"
  printf 'base\n' > "$base/work/c.txt"; git -C "$base/work" add -A; git -C "$base/work" commit -qm base
  git -C "$base/work" remote add origin "$base/origin.git"
  git -C "$base/work" push -q -u origin main
  for b in dev other; do git -C "$base/work" branch "$b"; git -C "$base/work" push -q -u origin "$b"; done
}
commit_on() {   # repo branch file content  (po commitu se vrací na main)
  git -C "$1" checkout -q "$2"; printf '%s\n' "$4" > "$1/$3"
  git -C "$1" add -A; git -C "$1" commit -qm "$2: $3"; git -C "$1" checkout -q main
}
remote_head() { git -C "$1/origin.git" rev-parse "$2"; }
local_head()  { git -C "$1/work" rev-parse "$2"; }
p_prep() {      # base  — fixture + lokální commity na dev/other + špinavý main
  mkpush_fixture "$1"; commit_on "$1/work" dev d.txt d; commit_on "$1/work" other o.txt o
  echo dirty > "$1/work/m.txt"
}

P1="$SB/p1"; p_prep "$P1"
cat > "$GIT_AGENT_SETTINGS" <<EOF
{ "repos": { "$(rp "$P1/work")": { "push": "all" } } }
EOF
out=$(GIT_AGENT_NO_COMMIT_MESSAGE=1 run_agent_args "$P1/work"); rc=$?
chk "P1: exit kód 0"            test "$rc" -eq 0
chk "P1: main pushnuto"         test "$(remote_head "$P1" main)"  = "$(local_head "$P1" main)"
chk "P1: dev pushnuto"          test "$(remote_head "$P1" dev)"   = "$(local_head "$P1" dev)"
chk "P1: other pushnuto"        test "$(remote_head "$P1" other)" = "$(local_head "$P1" other)"

P2="$SB/p2"; p_prep "$P2"
cat > "$GIT_AGENT_SETTINGS" <<EOF
{ "repos": { "$(rp "$P2/work")": { "push": ["dev"] } } }
EOF
out=$(GIT_AGENT_NO_COMMIT_MESSAGE=1 run_agent_args "$P2/work"); rc=$?
chk "P2: exit kód 0"            test "$rc" -eq 0
chk "P2: dev pushnuto"          test "$(remote_head "$P2" dev)" = "$(local_head "$P2" dev)"
chk "P2: main NEpushnuto"       test "$(remote_head "$P2" main)" != "$(local_head "$P2" main)"
chk "P2: other NEpushnuto"      test "$(remote_head "$P2" other)" != "$(local_head "$P2" other)"
chk "P2: main se lokálně commitlo" test "$(git -C "$P2/work" rev-list --count main)" -eq 3

P3="$SB/p3"; p_prep "$P3"; rm -f "$GIT_AGENT_SETTINGS"
out=$(GIT_AGENT_NO_COMMIT_MESSAGE=1 run_agent_args "$P3/work"); rc=$?
chk "P3: current — main pushnuto" test "$(remote_head "$P3" main)" = "$(local_head "$P3" main)"
chk "P3: current — dev NEpushnuto" test "$(remote_head "$P3" dev)" != "$(local_head "$P3" dev)"

P4="$SB/p4"; p_prep "$P4"
cat > "$GIT_AGENT_SETTINGS" <<EOF
{ "repos": { "$(rp "$P4/work")": { "push": ["nope", "dev"] } } }
EOF
out=$(GIT_AGENT_NO_COMMIT_MESSAGE=1 run_agent_args "$P4/work"); rc=$?; saveout "$out" "$SB/p4.out"
chk     "P4: exit kód 0"                     test "$rc" -eq 0
chk_out "P4: varování o neexistující větvi"  "nope.*neexistuje" "$SB/p4.out"
chk_not_out "P4: žádné SELHALO"              "SELHALO" "$SB/p4.out"
chk     "P4: dev i tak pushnuto"             test "$(remote_head "$P4" dev)" = "$(local_head "$P4" dev)"
```

- [ ] **Step 2: Ověřit selhání**

Run: `tests/run-tests.sh 2>&1 | grep -a 'P[1-4]:'`
Expected: P1 (dev/other), P2 (dev pushnuto, main NEpushnuto), P4 FAIL.

- [ ] **Step 3: Implementace**

3a. Za `push_if_needed` (před sekci „repozitář") přidej:

```bash
# ----------------------------------------------------- push podle settings ----
# Větve k pushi podle REPO_PUSH (po jedné na řádek).
push_targets() {
  local repo=$1 branch=$2
  case $REPO_PUSH in
    '"current"') printf '%s\n' "$branch" ;;
    '"all"')     git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads ;;
    *)           jq -r '.[]' <<<"$REPO_PUSH" ;;
  esac
}

# Push větve, která NENÍ checkoutnutá (bez přepínání). Bez copilota — ten pracuje
# nad checkoutnutou větví; selhání se zapíše do FAILED.
push_other_branch() {
  local repo=$1 b=$2 up remote merge ahead out
  if ! git -C "$repo" rev-parse --verify -q "refs/heads/$b" >/dev/null; then
    warn "větev '$b' lokálně neexistuje — push přeskočen"; return 0
  fi
  up=$(git -C "$repo" rev-parse --symbolic-full-name "${b}@{upstream}" 2>/dev/null || true)
  if [[ -z $up ]]; then info "větev $b nemá upstream — push vynechán"; return 0; fi
  remote=$(git -C "$repo" config --get "branch.$b.remote" 2>/dev/null || true)
  [[ -n $remote ]] || remote=$(git -C "$repo" remote | head -n 1)
  merge=$(git -C "$repo" config --get "branch.$b.merge" 2>/dev/null || true)
  [[ -n $merge ]] || merge="refs/heads/$b"
  ahead=$(git -C "$repo" rev-list --count "$up..$b" 2>/dev/null || echo 0)
  (( ahead > 0 )) || { info "větev $b v synchronizaci"; return 0; }
  if [[ -n ${GIT_AGENT_DRY_RUN:-} ]]; then
    info "DRY-RUN: git push $remote refs/heads/$b:$merge"; return 0
  fi
  if out=$(git -C "$repo" push "$remote" "refs/heads/$b:$merge" 2>&1); then
    ok "push $b → $remote"; (( PUSHED++ )); return 0
  fi
  err "push větve $b selhal"
  printf '%s\n' "$out" | sed 's/^/    /' >&2
  FAILED+=("$repo (push $b)")
  notify "git-agent: push $b selhal ✗" "$repo — větev $b nelze pushnout (nutný ruční zásah)"
  return 1
}

# Nahrazuje přímé volání push_if_needed: respektuje REPO_PUSH.
push_branches() {
  local repo=$1 branch=$2 committed=$3 b rc=0 seen_current=0
  local -a targets=()
  mapfile -t targets < <(push_targets "$repo" "$branch")
  for b in "${targets[@]}"; do
    [[ -n $b ]] || continue
    if [[ $b == "$branch" ]]; then
      seen_current=1
      push_if_needed "$repo" "$branch" "$committed" || rc=1
    else
      push_other_branch "$repo" "$b" || rc=1
    fi
  done
  (( seen_current )) || info "aktuální větev $branch není v 'push' — nepushuji"
  return "$rc"
}
```
3b. V `process_repo` nahraď poslední řádek `push_if_needed "$repo" "$branch" "${_COMMITTED:-0}"` za `push_branches "$repo" "$branch" "${_COMMITTED:-0}"`. Totéž v posledním kroku `pull_repo` (`# 4) co vzniklo navíc …`).

- [ ] **Step 4: Spustit testy**

Run: `tests/run-tests.sh 2>&1 | grep -a 'P[1-4]:\|výsledek'`
Expected: P1–P4 `ok`, žádná regrese oproti baseline (test B, J2 atd. dál procházejí).

- [ ] **Step 5: Commit**

```bash
git add git-agent.sh tests/run-tests.sh
git commit -m "feat: výběr větví k pushi (current / all / seznam)

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 4: conflict_prompt

**Files:**
- Modify: `git-agent.sh` (`conflict_prompt_block`, `copilot_resolve_and_push`)
- Test: `tests/run-tests.sh`

**Interfaces:**
- Consumes: `REPO_CONFLICT_PROMPT` (task 1), `copilot_resolve_and_push`.
- Produces: `conflict_prompt_block` → vypíše na stdout blok `USER INSTRUCTIONS …` (nebo nic); task 5 ho použije v merge promptu.

- [ ] **Step 1: Napsat padající testy**

```bash
# ------------------------------------------------- C: conflict_prompt --------
printf '\n== C: conflict_prompt ==\n'
C1="$SB/c1"; make_rejected "$C1"
cat > "$GIT_AGENT_SETTINGS" <<EOF
{ "repos": { "$(rp "$C1/work")": { "conflict_prompt": "Zachovej verzi z dev. \$(touch $SB/PWNED) \`touch $SB/PWNED2\` \"uvozovky\"" } } }
EOF
: > "$COPILOT_CALL_LOG"; : > "$COPILOT_PROMPT_LOG"
out=$(run_agent "$C1"); rc=$?
chk "C1: exit kód 0"                    test "$rc" -eq 0
chk "C1: prompt obsahuje instrukci"     grep -qF 'Zachovej verzi z dev' "$COPILOT_PROMPT_LOG"
chk "C1: doslovný \$( v promptu"        grep -qF '$(touch' "$COPILOT_PROMPT_LOG"
chk "C1: nic se nespustilo"             test ! -e "$SB/PWNED" -a ! -e "$SB/PWNED2"
chk "C1: základní pravidla zůstala"     grep -q 'HARD RULES' "$COPILOT_PROMPT_LOG"

C2="$SB/c2"; make_rejected "$C2"; rm -f "$GIT_AGENT_SETTINGS"
: > "$COPILOT_CALL_LOG"; : > "$COPILOT_PROMPT_LOG"
out=$(run_agent "$C2")
chk_not_out "C2: bez nastavení žádný blok" "USER INSTRUCTIONS" "$COPILOT_PROMPT_LOG"

C3="$SB/c3"; make_pull_fixture "$C3" cf
printf 'local\n' > "$C3/cf-work/c.txt"
git -C "$C3/cf-work" add -A && git -C "$C3/cf-work" commit -qm "local c"
remote_commit "$C3/cf-origin" c.txt "remote"
cat > "$GIT_AGENT_SETTINGS" <<EOF
{ "repos": { "$(rp "$C3/cf-work")": { "conflict_prompt": "PULL-PROMPT-XYZ" } } }
EOF
: > "$COPILOT_CALL_LOG"; : > "$COPILOT_PROMPT_LOG"
out=$(run_agent_args "$C3/cf-work" pull --rebase); rc=$?
chk "C3: pull konflikt — prompt s instrukcí" grep -qF 'PULL-PROMPT-XYZ' "$COPILOT_PROMPT_LOG"
```

- [ ] **Step 2: Ověřit selhání**

Run: `tests/run-tests.sh 2>&1 | grep -a 'C[123]:'`
Expected: C1 (instrukce, `$(`) a C3 FAIL.

- [ ] **Step 3: Implementace**

3a. Před `copilot_resolve_and_push` přidej:

```bash
# Uživatelský conflict_prompt z settings.json — vypisuje se přes printf '%s'
# (žádná expanze), takže $(...), `...` a uvozovky se do promptu dostanou doslova.
conflict_prompt_block() {
  [[ -n ${REPO_CONFLICT_PROMPT:-} ]] || return 0
  printf '\nUSER INSTRUCTIONS FOR CONFLICTS (from settings.json; follow them unless they contradict HARD RULES)\n%s\n' \
    "$REPO_CONFLICT_PROMPT"
}
```
3b. V `copilot_resolve_and_push` uvnitř bloku `{ … } > "$_PROMPT_TMP"` přidej za `cat <<EOF … EOF` řádek:

```bash
    conflict_prompt_block
```

- [ ] **Step 4: Spustit testy**

Run: `tests/run-tests.sh 2>&1 | grep -a 'C[123]:\|výsledek'`
Expected: C1–C3 `ok`, bez regrese.

- [ ] **Step 5: Commit**

```bash
git add git-agent.sh tests/run-tests.sh
git commit -m "feat: conflict_prompt ze settings.json v promptu pro copilota

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Merge přes PR (gh)

**Files:**
- Modify: `git-agent.sh` (`GH_BIN`, `merge_resolve_conflict`, `merge_via_pr`, `finish_repo`, volání v `process_repo`/`pull_repo`)
- Test: `tests/run-tests.sh` (stub `gh`, režim `mergefix` ve stubu copilot, fixture)

**Interfaces:**
- Consumes: `REPO_MERGE_FROM/TO/STRATEGY` (task 1), `push_branches` (task 3), `conflict_prompt_block`, `spawn_agent <headline> <pfile> <cwd> [out]` (výsledek v `_AGENT_RC`), `FAILED`, `MERGED`, `COPILOT_CALLED`.
- Produces: `merge_via_pr <repo>` (rc 0 i při přeskočení; rc 1 jen při skutečném selhání), `finish_repo <repo> <branch>` (= `push_branches … && merge_via_pr`).

- [ ] **Step 1: Stuby a testy**

1a. V `tests/run-tests.sh` ve stubu `copilot` přidej větev před závěrečné `else exit 1` (pořadí: `if fix … elif commitmsg … elif mergefix … else`):

```bash
elif [[ ${COPILOT_STUB_MODE:-} == mergefix ]]; then
  # simuluj vyřešení konfliktu merge: vezmi "ours" u konfliktních souborů a dokonči merge
  git diff --name-only --diff-filter=U | while IFS= read -r f; do
    git checkout --ours -- "$f"; git add -- "$f"
  done
  git commit -q --no-edit
```
1b. Za stub `nh` přidej stub `gh` (a doplň ho do `chmod +x`):

```bash
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "${1:-} ${2:-}" in
  "auth status") exit "${GH_AUTH_RC:-0}" ;;
  "pr list")     [[ -f $GH_STATE/pr ]] && echo 7; exit 0 ;;
  "pr create")   touch "$GH_STATE/pr"; echo "https://github.com/t/t/pull/7"; exit 0 ;;
  "pr merge")
    n=$(cat "$GH_STATE/merge-count" 2>/dev/null || echo 0); echo $((n + 1)) > "$GH_STATE/merge-count"
    if (( n < ${GH_MERGE_FAILS:-0} )); then echo "Pull request is not mergeable: merge conflict" >&2; exit 1; fi
    exit 0 ;;
esac
exit 0
EOF
```
`chmod +x "$STUB/copilot" "$STUB/git-lfs" "$STUB/copilot-leaky" "$STUB/nh" "$STUB/gh"`

1c. Testy před `# --- konec ---`:

```bash
# ------------------------------------------------------- G: merge přes PR ----
printf '\n== G: merge dev → main přes gh PR ==\n'
export GH_LOG="$SB/gh.log" GH_STATE="$SB/gh-state"
gh_reset() { rm -rf "$GH_STATE"; mkdir -p "$GH_STATE"; : > "$GH_LOG"; : > "$COPILOT_CALL_LOG"; : > "$COPILOT_PROMPT_LOG"; }
mkgh_fixture() {   # base — jako mkpush_fixture, ale remote.origin.url vypadá jako GitHub
  mkpush_fixture "$1"
  git -C "$1/work" config remote.origin.url "https://github.com/t/t.git"
  git -C "$1/work" config "url.$1/origin.git.insteadOf" "https://github.com/t/t.git"
  git -C "$1/work" checkout -q dev
}
merge_settings() {  # repo strategy [conflict_prompt]
  cat > "$GIT_AGENT_SETTINGS" <<EOF
{ "repos": { "$(rp "$1")": { "push": "current", "merge": { "from": "dev", "to": "main", "strategy": "$2" }, "conflict_prompt": "${3:-}" } } }
EOF
}

G1="$SB/g1"; mkgh_fixture "$G1"; echo n > "$G1/work/n.txt"; gh_reset
merge_settings "$G1/work" squash
out=$(GIT_AGENT_NO_COMMIT_MESSAGE=1 run_agent_args "$G1/work"); rc=$?; saveout "$out" "$SB/g1.out"
chk "G1: exit kód 0"                test "$rc" -eq 0
chk "G1: dev pushnuto"              test "$(remote_head "$G1" dev)" = "$(local_head "$G1" dev)"
chk "G1: PR vytvořen"               grep -q 'pr create' "$GH_LOG"
chk "G1: merge se strategií squash" grep -q 'pr merge 7 --squash' "$GH_LOG"
chk "G1: copilot nezavolán"         test ! -s "$COPILOT_CALL_LOG"
chk_out "G1: souhrn mergů"          'mergů:\s*1' "$SB/g1.out"

G2="$SB/g2"; mkgh_fixture "$G2"; echo n > "$G2/work/n.txt"; gh_reset; touch "$GH_STATE/pr"
merge_settings "$G2/work" merge
out=$(GIT_AGENT_NO_COMMIT_MESSAGE=1 run_agent_args "$G2/work")
chk         "G2: existující PR se nevytváří" bash -c '! grep -q "pr create" "$0"' "$GH_LOG"
chk         "G2: merge --merge"              grep -q 'pr merge 7 --merge' "$GH_LOG"

G3="$SB/g3"; mkgh_fixture "$G3"
git clone -q "$G3/origin.git" "$G3/clone"; git -C "$G3/clone" config user.email t@t; git -C "$G3/clone" config user.name t
printf 'main-change\n' > "$G3/clone/c.txt"; git -C "$G3/clone" commit -qam "main moves"; git -C "$G3/clone" push -q origin main
printf 'dev-change\n' > "$G3/work/c.txt"; gh_reset
merge_settings "$G3/work" merge "Zachovej dev-verzi"
out=$(COPILOT_STUB_MODE=mergefix GH_MERGE_FAILS=1 GIT_AGENT_NO_COMMIT_MESSAGE=1 run_agent_args "$G3/work"); rc=$?; saveout "$out" "$SB/g3.out"
chk "G3: exit kód 0"                      test "$rc" -eq 0
chk "G3: copilot zavolán při konfliktu"   test -s "$COPILOT_CALL_LOG"
chk "G3: prompt s conflict_prompt"        grep -qF 'Zachovej dev-verzi' "$COPILOT_PROMPT_LOG"
chk "G3: main je předek remote dev"       git -C "$G3/origin.git" merge-base --is-ancestor main dev
chk "G3: merge zopakován (2×)"            test "$(grep -c 'pr merge' "$GH_LOG")" -eq 2
chk "G3: dočasný worktree uklizen"        test -z "$(git -C "$G3/work" worktree list | sed 1d)"
chk_not_out "G3: žádné SELHALO"           "SELHALO" "$SB/g3.out"

G4="$SB/g4"; mkgh_fixture "$G4"; echo n > "$G4/work/n.txt"; gh_reset
merge_settings "$G4/work" merge
out=$(GIT_AGENT_GH_BIN=gh-neexistuje GIT_AGENT_NO_COMMIT_MESSAGE=1 run_agent_args "$G4/work"); rc=$?; saveout "$out" "$SB/g4.out"
chk     "G4: bez gh exit kód 0"           test "$rc" -eq 0
chk_out "G4: varování o gh"               "gh" "$SB/g4.out"
chk_not_out "G4: bez SELHALO"             "SELHALO" "$SB/g4.out"

G5="$SB/g5"; mkgh_fixture "$G5"; gh_reset; merge_settings "$G5/work" merge
out=$(GIT_AGENT_NO_COMMIT_MESSAGE=1 run_agent_args "$G5/work")
chk         "G5: dev není před main → bez PR" bash -c '! grep -q "pr create" "$0"' "$GH_LOG"

G6="$SB/g6"; mkpush_fixture "$G6"; git -C "$G6/work" checkout -q dev; echo n > "$G6/work/n.txt"; gh_reset
merge_settings "$G6/work" merge
out=$(GIT_AGENT_NO_COMMIT_MESSAGE=1 run_agent_args "$G6/work"); rc=$?; saveout "$out" "$SB/g6.out"
chk     "G6: ne-GitHub remote exit 0"     test "$rc" -eq 0
chk_out "G6: varování GitHub"             "GitHub" "$SB/g6.out"
chk     "G6: žádné volání PR"             bash -c '! grep -q "pr " "$0"' "$GH_LOG"
```

- [ ] **Step 2: Ověřit selhání**

Run: `tests/run-tests.sh 2>&1 | grep -a 'G[1-6]:'`
Expected: G1, G2, G3 FAIL (žádné `gh` volání), G4–G6 částečně FAIL (chybí varování).

- [ ] **Step 3: Implementace**

3a. K nastavení přidej `GH_BIN="${GIT_AGENT_GH_BIN:-gh}"` (za `NH_BIN=`).

3b. Za `push_branches` (task 3) přidej:

```bash
# ----------------------------------------------------------- merge přes PR ----
# Zmerguje remote $to do $from v dočasném worktree (detached), konflikt předá
# copilotovi a výsledek pushne na $from. rc 0 = $from na remote je aktuální.
merge_resolve_conflict() {
  local repo=$1 remote=$2 from=$3 to=$4 gh_err=$5 wt out headline
  wt=$(mktemp -d "${TMPDIR:-/tmp}/git-agent-merge-XXXXXX")
  if ! git -C "$repo" worktree add -q --detach "$wt" "refs/remotes/$remote/$from" 2>/dev/null; then
    err "nelze vytvořit dočasný worktree pro $from"
    rm -rf -- "$wt"; FAILED+=("$repo (merge $from→$to: worktree)"); return 1
  fi
  local rc=0
  if ! git -C "$wt" merge --no-edit "refs/remotes/$remote/$to" >/dev/null 2>&1; then
    (( COPILOT_CALLED++ ))
    _PROMPT_TMP=$(mktemp)
    {
      cat <<EOF
ROLE
You are the automated repair subroutine of git-agent. A pull request merge
($from -> $to) FAILED because of conflicts. In this temporary worktree HEAD is
branch "$from" and a merge of "$to" into it is IN PROGRESS with conflicts.
Resolve all conflicts and COMMIT the merge (do not push, do not switch branch).

REPOSITORY CONTEXT
- worktree: $wt
- remote:   $remote
- merge:    $to into $from
- status:   $(git -C "$wt" status --porcelain=v1 | head -n 40)

CAPTURED gh ERROR
-----BEGIN ERROR-----
$gh_err
-----END ERROR-----

HARD RULES
1. Work ONLY inside this worktree.
2. NEVER add entries to .gitignore. Files larger than 100 MB must not be committed.
3. No --force. You are DONE only when there are no unmerged files, the merge is
   committed and \`git status --porcelain\` prints nothing.
EOF
      conflict_prompt_block
    } > "$_PROMPT_TMP"
    headline="[git-agent] Merge $to → $from selhal na konfliktu — vyřeš a commitni merge."
    spawn_agent "$headline" "$_PROMPT_TMP" "$wt"
    if (( ${_AGENT_RC:-0} != 0 )); then
      err "copilot skončil s chybou (rc=$_AGENT_RC) při merge $to → $from"
      rc=1
    elif [[ -n $(git -C "$wt" diff --name-only --diff-filter=U) ]] \
      || git -C "$wt" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
      || [[ -n $(git -C "$wt" status --porcelain=v1) ]] \
      || ! git -C "$wt" merge-base --is-ancestor "refs/remotes/$remote/$to" HEAD; then
      err "copilot nevyřešil konflikt merge $to → $from"
      rc=1
    fi
  fi
  if (( rc == 0 )); then
    if out=$(git -C "$wt" push "$remote" "HEAD:refs/heads/$from" 2>&1); then
      ok "merge $to → $from pushnut na $remote"
    else
      err "push merge výsledku selhal: $out"; rc=1
    fi
  fi
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf -- "$wt"
  git -C "$repo" worktree prune >/dev/null 2>&1 || true
  (( rc == 0 )) || FAILED+=("$repo (merge $from→$to: konflikt)")
  return "$rc"
}

# Po úspěšném pushi $from: PR $from→$to (vytvořit, pokud není) a rovnou merge.
# Předpoklady chybí (gh, GitHub remote, větve…) → varování a přeskočení (rc 0).
merge_via_pr() {
  local repo=$1
  [[ -n ${REPO_MERGE_FROM:-} ]] || return 0
  local from=$REPO_MERGE_FROM to=$REPO_MERGE_TO strat=$REPO_MERGE_STRATEGY remote url pr out ahead
  local tag="merge $from → $to"
  remote=$(git -C "$repo" remote | head -n 1)
  [[ -n $remote ]] || { warn "$tag: repo nemá remote — přeskočeno"; return 0; }
  url=$(git -C "$repo" config --get "remote.$remote.url" 2>/dev/null || true)
  case $url in
    *github.com[:/]*) ;;
    *) warn "$tag: remote '$remote' není GitHub — přeskočeno"; return 0 ;;
  esac
  command -v "$GH_BIN" >/dev/null 2>&1 || { warn "$tag: gh ($GH_BIN) není nainstalované — přeskočeno"; return 0; }
  "$GH_BIN" auth status >/dev/null 2>&1 || { warn "$tag: gh není přihlášené — přeskočeno"; return 0; }
  git -C "$repo" rev-parse --verify -q "refs/heads/$from" >/dev/null \
    || { warn "$tag: lokální větev '$from' neexistuje — přeskočeno"; return 0; }
  if [[ -n ${GIT_AGENT_DRY_RUN:-} ]]; then
    info "DRY-RUN: gh pr create/merge $from → $to (--$strat)"; return 0
  fi
  git -C "$repo" fetch -q "$remote" "$from" "$to" 2>/dev/null \
    || { warn "$tag: fetch selhal — přeskočeno"; return 0; }
  local rfrom="refs/remotes/$remote/$from" rto="refs/remotes/$remote/$to"
  git -C "$repo" rev-parse --verify -q "$rto" >/dev/null \
    || { warn "$tag: větev '$to' na remote neexistuje — přeskočeno"; return 0; }
  git -C "$repo" rev-parse --verify -q "$rfrom" >/dev/null \
    || { warn "$tag: větev '$from' na remote neexistuje — přeskočeno"; return 0; }
  if (( $(git -C "$repo" rev-list --count "$rfrom..refs/heads/$from" 2>/dev/null || echo 1) > 0 )); then
    info "$tag: '$from' má nepushnuté commity — merge počká"; return 0
  fi
  ahead=$(git -C "$repo" rev-list --count "$rto..$rfrom" 2>/dev/null || echo 0)
  (( ahead > 0 )) || { info "$tag: '$from' není před '$to' — nic k mergi"; return 0; }

  pr=$(cd "$repo" && "$GH_BIN" pr list --head "$from" --base "$to" --state open --json number --jq '.[0].number // empty' 2>/dev/null)
  if [[ -z $pr ]]; then
    if ! out=$(cd "$repo" && "$GH_BIN" pr create --head "$from" --base "$to" \
                 --title "git-agent: $from → $to" --body "Automatický PR vytvořený git-agentem." 2>&1); then
      err "gh pr create selhal: $out"; FAILED+=("$repo (gh pr create)"); return 1
    fi
    pr=$(cd "$repo" && "$GH_BIN" pr list --head "$from" --base "$to" --state open --json number --jq '.[0].number // empty' 2>/dev/null)
    [[ -n $pr ]] || { err "PR byl vytvořen, ale nelze zjistit jeho číslo"; FAILED+=("$repo (gh pr)"); return 1; }
    ok "PR #$pr vytvořen ($from → $to)"
  fi

  if out=$(cd "$repo" && "$GH_BIN" pr merge "$pr" "--$strat" 2>&1); then
    ok "PR #$pr zmergován (--$strat)"; (( MERGED++ )); return 0
  fi
  warn "$tag: gh pr merge selhal — zkouším zmergovat '$to' do '$from'"
  printf '%s\n' "$out" | sed 's/^/    /' >&2
  notify "git-agent: merge konflikt ⚠" "$repo — $tag"
  merge_resolve_conflict "$repo" "$remote" "$from" "$to" "$out" || return 1
  if out=$(cd "$repo" && "$GH_BIN" pr merge "$pr" "--$strat" 2>&1); then
    ok "PR #$pr zmergován po vyřešení konfliktu"; (( MERGED++ )); return 0
  fi
  err "gh pr merge selhal i po vyřešení konfliktu: $out"
  FAILED+=("$repo (gh pr merge #$pr)")
  return 1
}

# push podle settings + (po úspěchu) merge přes PR
finish_repo() {
  local repo=$1 branch=$2
  push_branches "$repo" "$branch" "${_COMMITTED:-0}" || return 1
  merge_via_pr "$repo"
}
```
3c. V `process_repo` a v posledním kroku `pull_repo` nahraď `push_branches "$repo" "$branch" "${_COMMITTED:-0}"` za `finish_repo "$repo" "$branch"`.

3d. `shellcheck`-ovo: v `merge_resolve_conflict` je `$gh_err` použit v heredoc; proměnná `headline` už deklarovaná lokálně.

- [ ] **Step 4: Spustit testy**

Run: `tests/run-tests.sh 2>&1 | grep -a 'G[1-6]:\|výsledek'`
Expected: G1–G6 `ok`; celkově nehorší než baseline.

- [ ] **Step 5: Commit**

```bash
git add git-agent.sh tests/run-tests.sh
git commit -m "feat: merge dev→main přes gh PR včetně řešení konfliktu copilotem

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `git-agent setting --help` a `--copilot`

**Files:**
- Modify: `git-agent.sh` (nové `settings_help`, `settings_copilot`, `settings_cli` + dispatch hned za `usage()`, tj. před zámkem a přesměrováním do logu; hlavička s použitím)
- Test: `tests/run-tests.sh`

**Interfaces:**
- Consumes: `SETTINGS_FILE`, `COPILOT_BIN`, `die`, `err` (existující); `settings_help` musí popisovat přesně to, co implementují tasky 1–5.
- Produces:
  - `git-agent setting [-h|--help]` → vypíše všechny volby settings.json (exit 0; bez argumentu totéž);
  - `git-agent setting -co|--copilot` → spustí `copilot -i <prompt>` v popředí (prompt = „Pomoz mi nastavit…" + pravidla + repo, ve kterém běžím + aktuální obsah souboru + nápověda); `GIT_AGENT_DRY_RUN=1` prompt jen vypíše;
  - neznámá volba → exit 2.

- [ ] **Step 1: Napsat padající testy** (před `# --- konec ---`)

```bash
# ---------------------------------------------- S: git-agent setting ----------
printf '\n== S: git-agent setting (--help, --copilot) ==\n'
rm -f "$GIT_AGENT_SETTINGS"; : > "$COPILOT_CALL_LOG"
out=$(run_agent_args "$SB" setting --help); rc=$?; saveout "$out" "$SB/s1.out"
chk "S1: exit kód 0"                        test "$rc" -eq 0
for key in defaults repos ignore push current all merge from to strategy squash rebase conflict_prompt GIT_AGENT_SETTINGS; do
  chk_out "S1: nápověda zmiňuje '$key'"     "$key" "$SB/s1.out"
done
chk "S1: nic nezapsáno do settings"         test ! -e "$GIT_AGENT_SETTINGS"
chk "S1: copilot nezavolán"                 test ! -s "$COPILOT_CALL_LOG"
out=$(run_agent_args "$SB" setting -h)
chk "S1: -h shodné s --help"                test "$out" = "$(cat "$SB/s1.out")"
out=$(run_agent_args "$SB" setting)
chk "S1: bez volby = nápověda"              test "$out" = "$(cat "$SB/s1.out")"

S2="$SB/s2"; mkrepo "$S2"
echo '{"repos":{"/marker/repo":{"ignore":true}}}' > "$GIT_AGENT_SETTINGS"
: > "$COPILOT_CALL_LOG"
out=$(COPILOT_STUB_MODE=commitmsg run_agent_args "$S2" setting -co </dev/null); rc=$?
chk "S2: exit kód 0"                        test "$rc" -eq 0
chk "S2: copilot spuštěn interaktivně (-i)" grep -q 'CALL: -i ' "$COPILOT_CALL_LOG"
chk "S2: prompt 'Pomoz mi nastavit'"        grep -qF 'Pomoz mi nastavit' "$COPILOT_CALL_LOG"
chk "S2: prompt obsahuje nápovědu"          grep -qF 'conflict_prompt' "$COPILOT_CALL_LOG"
chk "S2: prompt obsahuje cestu souboru"     grep -qF "$GIT_AGENT_SETTINGS" "$COPILOT_CALL_LOG"
chk "S2: prompt obsahuje aktuální obsah"    grep -qF '/marker/repo' "$COPILOT_CALL_LOG"
chk "S2: prompt obsahuje aktuální repo"     grep -qF "$(rp "$S2")" "$COPILOT_CALL_LOG"
chk "S2: settings.json nezměněn"            test "$(cat "$GIT_AGENT_SETTINGS")" = '{"repos":{"/marker/repo":{"ignore":true}}}'
: > "$COPILOT_CALL_LOG"
out=$(COPILOT_STUB_MODE=commitmsg run_agent_args "$S2" setting --copilot </dev/null)
chk "S2: --copilot totéž jako -co"          grep -q 'CALL: -i ' "$COPILOT_CALL_LOG"

out=$(GIT_AGENT_COPILOT_BIN=copilot-neexistuje run_agent_args "$SB" setting -co </dev/null); rc=$?; saveout "$out" "$SB/s3.out"
chk     "S3: bez copilota exit kód 2"       test "$rc" -eq 2
chk_out "S3: hláška o copilotovi"           "není nainstalovaný" "$SB/s3.out"

out=$(run_agent_args "$SB" setting --bogus); rc=$?; saveout "$out" "$SB/s4.out"
chk     "S4: neznámá volba exit kód 2"      test "$rc" -eq 2
chk_out "S4: hláška o neznámé volbě"        "neznámá" "$SB/s4.out"

: > "$COPILOT_CALL_LOG"
out=$(GIT_AGENT_DRY_RUN=1 run_agent_args "$S2" setting -co </dev/null); rc=$?; saveout "$out" "$SB/s5.out"
chk     "S5: dry-run exit kód 0"            test "$rc" -eq 0
chk     "S5: dry-run copilot nezavolán"     test ! -s "$COPILOT_CALL_LOG"
chk_out "S5: dry-run vypíše prompt"         "Pomoz mi nastavit" "$SB/s5.out"
```

- [ ] **Step 2: Ověřit selhání**

Run: `tests/run-tests.sh 2>&1 | grep -a 'S[1-5]:'`
Expected: S1–S5 FAIL (`setting` je dnes neznámá volba → exit 2 a usage).

- [ ] **Step 3: Implementace v `git-agent.sh`**

3a. Hned za funkci `usage()` (a před sekci `# --- zámek ---`) přidej:

```bash
# ----------------------------------------------------- git-agent setting -----
# Běží PŘED zámkem a přesměrováním do logu — copilot -co je interaktivní.
settings_help() {
  printf 'Soubor: %s   (přepis: GIT_AGENT_SETTINGS=<cesta>)\n' "$SETTINGS_FILE"
  cat <<'EOF'

Použití:
  git-agent setting [-h|--help]      tato nápověda (všechny volby settings.json)
  git-agent setting -co|--copilot    spustí copilota, který ti pomůže nastavit repo

Agent při hledání repozitářů sám zapíše každé nové repo do "repos" s výchozím
nastavením. Existující položky nikdy nemění ani nemaže. Bez souboru / položky se
chová jako dřív.

Struktura:
  {
    "defaults": { ... },                  výchozí hodnoty pro všechna repa
    "repos": {
      "/abs/cesta/k/repu": { ... },       přesná cesta (má přednost)
      "/abs/cesta/*":      { ... }        glob; ~ se expanduje; první shoda vyhrává
    }
  }
  Hodnoty z repa přepíšou "defaults"; chybějící klíče se doplní z "defaults".

Klíče položky (v "defaults" i v "repos"):
  ignore           true | false (default false)
                   true = repo se přeskočí (commit, push, pull, merge).
  push             "current" (default) | "all" | ["větev1", "větev2", ...]
                   current = jen aktuální větev; all = všechny lokální větve
                   s upstreamem; seznam = jen vyjmenované větve. Větve, které
                   nejsou checkoutnuté, se pushují bez přepínání; při selhání se
                   to jen nahlásí (copilot pracuje nad aktuální větví).
  merge            { "from": "dev", "to": "main", "strategy": "merge" }
                   Po úspěšném pushi větve "from" agent přes gh vytvoří PR
                   from -> to (pokud není) a rovnou ho mergne.
                   strategy: merge (default) | squash | rebase.
                   Konflikt: zmerguje "to" do "from" v dočasném worktree,
                   předá copilotovi, pushne a merge zopakuje.
                   Bez gh / přihlášení / GitHub remote se merge přeskočí.
  conflict_prompt  libovolný text přidaný k promptu pro copilota při konfliktu
                   (pull, push i merge). Doplňuje, nenahrazuje základní prompt.

Příklad:
  {
    "defaults": { "ignore": false, "push": "current" },
    "repos": {
      "/root/old/stary": { "ignore": true },
      "/root/git/web": {
        "push": ["main", "dev"],
        "merge": { "from": "dev", "to": "main", "strategy": "merge" },
        "conflict_prompt": "U web repa vždy zachovej verzi z dev."
      },
      "/root/archiv/*": { "ignore": true }
    }
  }

Související proměnné prostředí:
  GIT_AGENT_SETTINGS   cesta k settings.json
  GIT_AGENT_GH_BIN     binárka GitHub CLI pro merge přes PR (default: gh)
  GIT_AGENT_DRY_RUN=1  nic nezapisuje ani nemění (u -co jen vypíše prompt)

Poškozený JSON agent nepřepisuje: vypíše varování a použije výchozí nastavení.
EOF
}

# Interaktivní copilot: pomůže uživateli upravit settings.json.
settings_copilot() {
  command -v "$COPILOT_BIN" >/dev/null 2>&1 \
    || die "copilot ($COPILOT_BIN) není nainstalovaný — spusť setup.sh"
  local top current prompt
  top=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -s $SETTINGS_FILE ]]; then
    current=$(cat -- "$SETTINGS_FILE")
  else
    current="(soubor zatím neexistuje — vytvoř ho včetně adresáře; základ: {\"defaults\":{\"ignore\":false,\"push\":\"current\"},\"repos\":{}})"
  fi
  prompt=$(cat <<EOF
Pomoz mi nastavit git-agent (settings.json). Komunikuj česky. Nejdřív se mě stručně zeptej, co chci nastavit (ignorovat repo, které větve pushovat, merge přes PR, vlastní conflict prompt), pak navrhni změnu a po mém souhlasu ji zapiš.

PRAVIDLA
1. Edituj POUZE soubor: $SETTINGS_FILE
2. Zachovej všechny existující položky; měň jen to, o co žádám. Nic nemaž.
3. Používej jen klíče z nápovědy níže (ignore, push, merge, conflict_prompt).
4. Klíč v "repos" je absolutní cesta k repozitáři nebo glob.
5. Výsledek musí být validní JSON — ověř ho příkazem: jq . "$SETTINGS_FILE"
6. Na konci stručně shrň, co jsi změnil.

REPOZITÁŘ, VE KTERÉM JSEM PŘÍKAZ SPUSTIL
${top:-(nejsem uvnitř git repozitáře)}

AKTUÁLNÍ OBSAH settings.json
$current

NÁPOVĚDA (git-agent setting --help)
$(settings_help)
EOF
)
  if [[ -n ${GIT_AGENT_DRY_RUN:-} ]]; then
    info "DRY-RUN: $COPILOT_BIN -i <prompt>"
    printf '%s\n' "$prompt"
    return 0
  fi
  "$COPILOT_BIN" -i "$prompt"
}

settings_cli() {
  case ${1:-} in
    ""|-h|--help)   settings_help ;;
    -co|--copilot)  settings_copilot ;;
    *) err "setting: neznámá volba: $1 (viz: $PROG setting --help)"; return 2 ;;
  esac
}

if [[ ${1:-} == setting || ${1:-} == settings ]]; then
  shift
  settings_cli "$@"
  exit $?
fi
```
3b. Do hlavičkového komentáře (blok „Použití:", před `git-agent -h | --help`) přidej:

```
#   git-agent setting [-h]     Nápověda ke všem volbám settings.json
#   git-agent setting -co      Interaktivní copilot, který pomůže nastavit settings.json
```

- [ ] **Step 4: Spustit testy**

Run: `tests/run-tests.sh 2>&1 | grep -a 'S[1-5]:\|výsledek'`
Expected: S1–S5 `ok`, bez regrese oproti baseline.

- [ ] **Step 5: Commit**

```bash
git add git-agent.sh tests/run-tests.sh
git commit -m "feat: git-agent setting --help a --copilot (průvodce nastavením)

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Dokumentace, verze, finální ověření

**Files:**
- Modify: `git-agent.sh` (hlavička, `VERSION`), `README.md`, `CLAUDE.md`, spec (stav)

**Interfaces:**
- Consumes: vše výše. Produces: nic nového.

- [ ] **Step 1: Hlavička a verze `git-agent.sh`**

`VERSION="1.5.0"`. Do bloku „Proměnné prostředí" v hlavičce přidej:

```
#   GIT_AGENT_SETTINGS         settings.json (default: ~/.config/git-agent/settings.json)
#   GIT_AGENT_GH_BIN           binárka GitHub CLI pro merge přes PR (default: gh)
```

- [ ] **Step 2: README** — do tabulky proměnných přidej `GIT_AGENT_SETTINGS` a `GIT_AGENT_GH_BIN` a před sekci „Pravidelný běh (cron)" vlož:

````markdown
## Nastavení (settings.json)

`~/.config/git-agent/settings.json` (přepis: `GIT_AGENT_SETTINGS`). Agent do něj při
hledání repozitářů **sám zapíše každé nové repo** s výchozím nastavením; existující
položky nikdy nemění. Bez souboru / položky se chová jako dříve.

```json
{
  "defaults": { "ignore": false, "push": "current" },
  "repos": {
    "/root/old/stary": { "ignore": true },
    "/root/git/web": {
      "push": ["main", "dev"],
      "merge": { "from": "dev", "to": "main", "strategy": "merge" },
      "conflict_prompt": "U web repa vždy zachovej verzi z dev."
    },
    "/root/archiv/*": { "ignore": true }
  }
}
```

- klíč v `repos` = absolutní cesta (přesná shoda má přednost) nebo glob (`~` se expanduje, první shoda vyhrává),
- `ignore: true` — repo se přeskočí (commit, push, pull, merge),
- `push`: `"current"` (default), `"all"` (všechny lokální větve s upstreamem) nebo seznam větví; jiné než aktuální větve se pushují bez přepínání a při selhání se jen nahlásí (copilot pracuje nad aktuální větví),
- `merge` (`from`, `to`, `strategy` = `merge`|`squash`|`rebase`): po úspěšném pushi `from` agent přes `gh` vytvoří PR `from → to` a rovnou ho mergne; při konfliktu zmerguje `to` do `from` v dočasném worktree, předá konflikt copilotovi, pushne a merge zopakuje. Bez `gh`/přihlášení/GitHub remote se merge přeskočí s varováním,
- `conflict_prompt`: text přidaný k promptu pro copilota při konfliktu (pull, push i merge),
- poškozený JSON se nepřepisuje (varování + výchozí nastavení); `GIT_AGENT_DRY_RUN=1` nic nezapisuje.
````
V sekci „Struktura" nic neměň.

- [ ] **Step 2b: README — příkaz `setting`** — na konec sekce „Nastavení (settings.json)" přidej:

```markdown
Přehled všech voleb vypíše `git-agent setting --help`; `git-agent setting -co`
(`--copilot`) spustí interaktivního copilota s promptem „Pomoz mi nastavit repo
setting" (dostane nápovědu, aktuální obsah souboru i repo, ve kterém jsi příkaz spustil).
```
A do příkladů „Použití" přidej řádky `git-agent setting --help` a `git-agent setting -co`.

- [ ] **Step 3: CLAUDE.md** — v „Architektura" přidej odrážku:

```
- Settings (`~/.config/git-agent/settings.json`, `GIT_AGENT_SETTINGS`): `load_settings` → `register_repos` (po `find_repos` zapíše nová repa) → `load_repo_settings` (v `process_repo`/`pull_repo` nastaví `REPO_*`) → `finish_repo` = `push_branches` + `merge_via_pr` (gh PR; konflikt řeší `merge_resolve_conflict` v dočasném worktree přes `spawn_agent`). Testy musí vždy exportovat `GIT_AGENT_SETTINGS` do sandboxu, jinak by zapisovaly do skutečného `~/.config`.
```
a v odrážce o `spawn_agent` doplň výjimku: `git-agent setting -co` (`settings_copilot`) spouští interaktivního `copilot -i` v popředí a dispatch `setting` běží před zámkem a logem. V „Poznámky" oprav řádek o `VERSION` na `1.5.0`. V odrážce o cron wrapperu připiš, že nová pole souhrnu se přidávají jen na konec řádku.

- [ ] **Step 4: Stav specu** — v `docs/superpowers/specs/2026-10-07-settings-json-design.md` změň řádek `Stav:` na `schváleno uživatelem, implementováno v 1.5.0`.

- [ ] **Step 5: Finální ověření**

Run:
```bash
bash -n git-agent.sh && tests/run-tests.sh 2>&1 | tail -4
GIT_AGENT_SETTINGS=/tmp/claude-0/-root-git-agent/18fbeffb-1e83-4439-980c-9905c8f821ca/scratchpad/s-final.json GIT_AGENT_DRY_RUN=1 GIT_AGENT_NO_COLOR=1 ./git-agent.sh | tail -5
```
Expected: syntaxe OK; `výsledek:` jen s baseline FAIL (2, žádný nový; porovnej s `baseline-fails.txt`); dry-run vypíše shrnutí s `nových repozitářů:` a nevytvoří `s-final.json`.

- [ ] **Step 6: Commit**

```bash
git add git-agent.sh README.md CLAUDE.md docs/superpowers/specs/2026-10-07-settings-json-design.md
git commit -m "docs: settings.json v README/CLAUDE.md, verze 1.5.0

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```
