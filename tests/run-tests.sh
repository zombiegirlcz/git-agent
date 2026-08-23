#!/usr/bin/env bash
#
# Testy pro git-agent.sh — spouštěj:  tests/run-tests.sh
#
# Strategie: běží plně offline se stubem `pi` (a stubem `git-lfs`).
# Scénář „push rejected → pi“ používá remote ukazující na neexistující cestu,
# takže reálné `git push` selže DETERMINISTICKY na jakémkoli stroji a spustí
# cestu konflikt→pi. (Transport samotný je doména gitu — netestujeme ho.)
# Stub pi v režimu "fix" simuluje úspěšnou synchronizaci update-refem, takže
# agent projde celým tokem včetně verifikace ahead==0.

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
AGENT="$HERE/../git-agent.sh"
[[ -f $AGENT ]] || { echo "chybí $AGENT" >&2; exit 2; }

PASS=0 FAILN=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { FAILN=$((FAILN+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

chk()     { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; fi; }
chk_out() { local d=$1 pat=$2 file=$3
            if grep -qiE -- "$pat" "$file" 2>/dev/null; then ok "$d"; else fail "$d"; fi; }
chk_not_out() { local d=$1 pat=$2 file=$3
            if grep -qiE -- "$pat" "$file" 2>/dev/null; then fail "$d"; else ok "$d"; fi; }

SB=$(mktemp -d "${TMPDIR:-/tmp}/git-agent-tests-XXXXXX")
trap 'rm -rf "$SB"' EXIT
STUB="$SB/bin"; mkdir -p "$STUB"

# ------------------------------------------------------------------ stuby ---
cat > "$STUB/pi" <<'EOF'
#!/usr/bin/env bash
echo "CALL: $*" >> "$PI_CALL_LOG"
cat >> "$PI_PROMPT_LOG"; echo >> "$PI_PROMPT_LOG"
if [[ ${PI_STUB_MODE:-fix} == fix ]]; then
  # simuluj úspěšnou opravu: posuň remote-tracking ref na HEAD (= „vše pushnuto“)
  # POZOR: jen plným jménem (refs/remotes/…) — zkrácený tvar update-ref mlčky nezapíše
  up=$(git rev-parse --symbolic-full-name '@{upstream}' 2>/dev/null || true)
  [[ $up == refs/* ]] && git update-ref "$up" HEAD
else
  exit 1
fi
EOF

cat > "$STUB/git-lfs" <<'EOF'
#!/usr/bin/env bash
echo "lfs $*" >> "$LFS_LOG"
cmd=${1:-}; shift || true
[[ ${1:-} == "--" ]] && shift
case $cmd in
  version) echo "git-lfs/3.7.0 (stub)" ;;
  install) exit 0 ;;
  track)   printf '"%s" filter=lfs diff=lfs merge=lfs -text\n' "$*" >> .gitattributes ;;
  *)       exit 0 ;;
esac
EOF
# stub nh — notifikace jen zaznamenává (a nikdy nesmí spadnout, když log není nastaven)
cat > "$STUB/nh" <<'EOF'
#!/usr/bin/env bash
[[ -n ${NH_LOG:-} ]] || exit 0
if [[ ${1:-} == system && ${2:-} == notification ]]; then
  echo "notification -t ${4:-} -c ${6:-}" >> "$NH_LOG"
fi
exit 0
EOF
chmod +x "$STUB/pi" "$STUB/git-lfs" "$STUB/nh"

export GIT_AGENT_NO_COLOR=1 GIT_AGENT_PI_BIN=pi
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export PATH="$STUB:$PATH"

mkrepo() {
  local d=$1
  mkdir -p "$d"
  git -C "$d" init -q -b main "$d" 2>/dev/null || git -C "$d" init -q "$d"
  git -C "$d" config user.email t@t
  git -C "$d" config user.name t
  echo seed > "$d/seed.txt"
  git -C "$d" add -A && git -C "$d" commit -qm seed
}

branch_of() { git -C "$1" symbolic-ref --short HEAD; }

# Repozitář s upstreamem na nedosažitelném remote → push vždy zamítnut.
make_rejected() {
  local base=$1 br
  mkdir -p "$base"
  mkrepo "$base/work"
  br=$(branch_of "$base/work")
  git -C "$base/work" remote add origin "/nonexistent-git-agent-e2e/origin.git"
  # nastav tracking bez skutečného pushnutí (stav „v synchronizaci“ v čase T0)
  git -C "$base/work" update-ref "refs/remotes/origin/$br" HEAD
  git -C "$base/work" config "branch.$br.remote" origin
  git -C "$base/work" config "branch.$br.merge" "refs/heads/$br"
  echo local-change > "$base/work/local.txt"
}

run_agent() { ( cd "$1" && bash "$AGENT" ) 2>&1; }   # stdout+stderr dohromady
saveout()   { echo "$1" > "$2"; }

# ------------------------------------------------------------------ 0) lint --
printf '\n== lint ==\n'
chk "bash -n git-agent.sh" bash -n "$AGENT"
chk "bash -n setup.sh"     bash -n "$HERE/../setup.sh"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "$AGENT" "$HERE/../setup.sh" && ok "shellcheck bez nálezu" || fail "shellcheck našel problémy"
else
  printf '  (shellcheck není k dispozici — přeskakuji)\n'
fi

# ------------------------------------------------------- 1) čisté repozitáře --
printf '\n== A: čisté repozitáře ==\n'
export PI_CALL_LOG="$SB/pi.log" PI_PROMPT_LOG="$SB/prompt.log" LFS_LOG="$SB/lfs.log" NH_LOG="$SB/nh.log"
A="$SB/a"; mkrepo "$A/r1"; mkrepo "$A/r2"
: > "$PI_CALL_LOG"
out=$(run_agent "$A"); rc=$?; saveout "$out" "$SB/a.out"
chk     "A: exit kód 0"              test "$rc" -eq 0
chk_out "A: nalezeny 2 repozitáře"   'repozitářů:\s*2' "$SB/a.out"
chk     "A: žádný nový commit (r1)"  test "$(git -C "$A/r1" rev-list --count HEAD)" -eq 1
chk     "A: pi nezavoláno"           test ! -s "$PI_CALL_LOG"

# --------------------------------------------- 2) konflikt na pushi → pi ------
printf '\n== B: push rejected → pi opraví ==\n'
B="$SB/b"; make_rejected "$B"
: > "$PI_CALL_LOG"; : > "$PI_PROMPT_LOG"
out=$(run_agent "$B"); rc=$?; saveout "$out" "$SB/b.out"
chk     "B: exit kód 0"                       test "$rc" -eq 0
chk     "B: pi zavoláno"                      test -s "$PI_CALL_LOG"
chk_out "B: prompt obsahuje cestu repa"       "b/work"                "$PI_PROMPT_LOG"
chk_out "B: prompt obsahuje chybu push"       "fatal:|rejected|behind|not appear" "$PI_PROMPT_LOG"
chk     "B: po pi je ahead=0"                 test "$(git -C "$B/work" rev-list --count '@{upstream}..HEAD')" -eq 0
chk     "B: pracovní strom je čistý"          test -z "$(git -C "$B/work" status --porcelain)"
chk_not_out "B: žádné SELHALO v shrnutí"      "SELHALO"               "$SB/b.out"

# --------------------------------------------------- 3) velká binárka >100 MB --
printf '\n== C: binárka >100 MB se necommitne ==\n'
C="$SB/c"; mkrepo "$C/repo"
echo changed > "$C/repo/seed.txt"
truncate -s 110M "$C/repo/big.bin"
: > "$PI_CALL_LOG"
out=$(run_agent "$C"); rc=$?; saveout "$out" "$SB/c.out"
chk  "C: exit kód 0"                          test "$rc" -eq 0
chk  "C: malá změna committnuta"              grep -q "seed.txt" <(git -C "$C/repo" show --name-only --format= HEAD)
chk  "C: big.bin NENÍ v gitu"                 test -z "$(git -C "$C/repo" ls-files | grep -x 'big.bin')"
chk  "C: big.bin zůstává untracked"           grep -q '^?? big\.bin' <(git -C "$C/repo" status --porcelain)
chk_out "C: varování VYNECHÁNO"               "VYNECHÁNO" "$SB/c.out"
chk_out "C: tip na --add-lfs"                 "add-lfs"   "$SB/c.out"
chk_not_out "C: žádná změna .gitignore"       "\.gitignore" <(git -C "$C/repo" status --porcelain)
chk  "C: pi nezavoláno"                       test ! -s "$PI_CALL_LOG"

# ------------------------------------------------------------ 4) --add-lfs ----
printf '\n== D: --add-lfs ==\n'
D="$SB/d"; mkrepo "$D/repo"
head -c 1048576 /dev/zero > "$D/repo/model.bin"
: > "$LFS_LOG"
out=$(cd / && bash "$AGENT" --add-lfs "$D/repo/model.bin"); rc=$?; saveout "$out" "$SB/d.out"
chk     "D: exit kód 0"                    test "$rc" -eq 0
chk_out "D: lfs install zavoláno"          "install"   "$LFS_LOG"
chk_out "D: lfs track zavoláno"            "track"     "$LFS_LOG"
chk_out "D: .gitattributes má pattern"     "model\.bin.*filter=lfs" "$D/repo/.gitattributes"
chk     "D: model.bin sledován gitem"      grep -qx "model.bin" <(git -C "$D/repo" ls-files)
chk_out "D: commit s LFS zprávou"          "git-agent-lfs" <(git -C "$D/repo" log -1 --format=%s)

# --------------------------------------------------------- 5) pi selže --------
printf '\n== E: pi selže → repo hlášeno jako selhané ==\n'
E="$SB/e"; make_rejected "$E"
export PI_STUB_MODE=fail
out=$(run_agent "$E"); rc=$?; saveout "$out" "$SB/e.out"
unset PI_STUB_MODE
chk     "E: nenulový exit kód"         test "$rc" -ne 0
chk_out "E: výstup obsahuje SELHALO"   "SELHALO" "$SB/e.out"

# --------------------------------------------------------- 6) notifikace -----
printf '\n== G: notifikace přes nh ==\n'
G="$SB/g"; mkrepo "$G/repo"
echo change > "$G/repo/seed.txt"
: > "$NH_LOG"
out=$(run_agent "$G"); rc=$?
saveout "$out" "$SB/g.out"
chk     "G: exit kód 0"                       test "$rc" -eq 0
chk     "G: notifikace odeslána"              grep -q 'notification -t' "$NH_LOG"
chk_out "G: shrnutí v notifikaci"             "hotovo:.*commitů" "$NH_LOG"
chk_out "G: titulek obsahuje git-agent"       "-t .*git-agent"   "$NH_LOG"
: > "$NH_LOG"
export GIT_NOTIFI=0
out=$(run_agent "$G"); rc=$?
unset GIT_NOTIFI
[[ -s "$NH_LOG" ]] && { echo "-- obsah po zakázaném běhu:"; cat "$NH_LOG"; }
chk "G: GIT_NOTIFI=0 → žádná notifikace"     test ! -s "$NH_LOG"

# --------------------------------------------------------------- 7) CLI -------
printf '\n== F: CLI ==\n'
bash "$AGENT" --help > "$SB/help.out" 2>&1
chk "F: --help zmiňuje --add-lfs"        grep -q -- "--add-lfs" "$SB/help.out"
chk "F: --help zmiňuje -g/--global"      grep -qiE '\-\-global|\-g\b' "$SB/help.out"
bash "$AGENT" --version > "$SB/ver.out" 2>&1
chk "F: --version"                       grep -q "git-agent" "$SB/ver.out"
bash "$AGENT" --rozhodne-neexistujici-flag >/dev/null 2>&1
chk "F: neznámá vlajka → rc 2"           test "$?" -eq 2

# ------------------------------------------------------------------ konec -----
printf '\n════════════════════════════\n'
printf 'výsledek: %d ok, %d FAIL\n' "$PASS" "$FAILN"
exit "$FAILN"
