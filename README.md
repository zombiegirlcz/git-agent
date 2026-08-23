# git-agent

Chytrý skript, který najde všechny git repozitáře, nepushnuté změny automaticky
commitne a pushne. Když push narazí na konflikt, předá opravu AI agentovi
**pi** v neinteraktivním režimu (`pi -p`) a poté **ověří**, že push skutečně
prošel.

## Instalace

```bash
./setup.sh          # curl, gh, git, git-lfs, jq, nvm+node, pi, ~/.local/bin/git-agent
```

Po skončení spusť nový shell (aby se načetla PATH) nebo `source ~/.bashrc`.

## Použití

```bash
git-agent                  # lokálně: projde aktuální složku rekurzivně
git-agent -g               # globálně: prohledá celý $HOME
git-agent -g --global      # totéž
git-agent -pi "kontext"    # doplňující pokyn pro pi při řešení konfliktů
git-agent --add-lfs f.bin  # zaradí soubor do Git LFS a commitne
```

Vlajky lze kombinovat: `git-agent -g -pi "nedívej se do data/"`

## Co dělá v každém repozitáři

1. **Špinavý pracovní strom** → `git add -A` + `git commit -m "$(date) git-agent"`
2. Soubory **větší než 100 MB se nikdy necommitují** — vynechají se, vypíše se
   varování a tip na `--add-lfs`. Skript nikdy neřeší nic přes `.gitignore`.
3. **Nepushnuté commity** → `git push`; když je zamítnut (konflikt,
   non-fast-forward…), zavolá `pi -p --no-session` s plným kontextem (cesta,
   branch, remote, status, přesné znění chyby) a tvým `-pi` kontextem.
4. Po pi ověří `rev-list @{upstream}..HEAD == 0` — neslíbí si úspěch.
5. Na konci vytiskne shrnutí; exit kód = počet selhavších repozitářů (max 125).

Repozitáře bez remotes se jen commitnou lokálně. Bare repozitáře a detached
HEAD se bezpečně přeskočí. Proti dvojímu běhu chrání flock.

## Proměnné prostředí

| proměnná | výchozí | význam |
|---|---|---|
| `GIT_AGENT_MAX_BYTES` | `104857600` | limit velikosti souboru (100 MB) |
| `GIT_AGENT_PI_BIN` | `pi` | jakou binárku volat pro opravy |
| `GIT_AGENT_PI_TIMEOUT` | `1800` | timeout pi běhu [s] |
| `GIT_AGENT_GLOBAL_ROOT` | `$HOME` | kořen globálního hledání (např. `/`) |
| `GIT_AGENT_LOG` | – | soubor pro kompletní log průběhu |
| `GIT_NOTIFI` | `1` | notifikace přes `nh system notification` (NetHunter CLI); `0` vypne |
| `GIT_AGENT_NH_BIN` | `nh` | binárka pro notifikace |
| `GIT_AGENT_DRY_RUN=1` | – | nic neměnit, jen vypsat akce |
| `GIT_AGENT_NO_COLOR=1` | – | výstup bez barev |

## Notifikace

Agent posílá systémové notifikace přes NetHunter CLI (`nh system notification -t … -c …`) —
defaultně **zapnuté** (`GIT_NOTIFI=1`). Přijdou při: startu konfliktu řešeného pi,
výsledku pi opravy a v závěrečném shrnutí. Když `nh` není nainstalované,
agent to tiše ignoruje. Vypnutí: `GIT_NOTIFI=0 git-agent -g`.

## Publikování / první push

```bash
gh repo create git-agent --public --source=. --remote=origin --push
```

## Testy

```bash
tests/run-tests.sh    # offline; používá stub pi a stub git-lfs
```

## Struktura

```
git-agent.sh        # samotný agent (instaluje se jako ~/.local/bin/git-agent)
setup.sh            # idempotentní instalace závislostí + agenta
tests/run-tests.sh  # end-to-end testy (čisté repo, konflikt→pi, 100MB limit, LFS, CLI)
```
