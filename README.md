# git-agent

Chytrý skript, který najde všechny git repozitáře, nepushnuté změny automaticky
commitne a pushne. Na každém commitu nechá vygenerovat zprávu přes **GitHub
Copilot CLI** a při konfliktu na pushu mu předá opravu.

## Instalace

```bash
./setup.sh          # curl, gh, git, git-lfs, jq, nvm+node, copilot, ~/.local/bin/git-agent
```

Po skončení spusť nový shell (aby se načetla PATH) nebo `source ~/.bashrc`.

## Použití

```bash
git-agent                  # lokálně: projde aktuální složku rekurzivně
git-agent -g               # globálně: prohledá celý $HOME
git-agent -g --global      # totéž
git-agent --add-lfs f.bin  # zaradí soubor do Git LFS a commitne
git-agent --no-commit-message|-im
                           # použije klasickou "$(date) git-agent" zprávu místo AI
```

## Co dělá v každém repozitáři

1. **Špinavý pracovní strom** → `git add -A` (s filtrhem >100 MB) + commit
2. **Zpráva commitu**: defaultně ji vygeneruje **Copilot CLI** z diffu; přepínač
   `--no-commit-message` / `-im` vráti klasickou `$(date) git-agent`.
3. **Nepushnuté commity** → `git push`; když je zamítnut (konflikt,
   non-fast-forward…), zavolá `copilot -p --allow-all-tools --no-ask-user
   --silent` s plným kontextem (cesta, branch, remote, status, přesné znění
   chyby) a poté **ověří**, že push skutečně prošel.
4. Na konci vytiskne shrnutí; exit kód = počet selhavších repozitářů (max 125).

Repozitáře bez remotes se jen commitnou lokálně. Bare repozitáře a detached
HEAD se bezpečně přeskočí. Proti dvojímu běhu chrání flock.

## Proměnné prostředí

| proměnná | výchozí | význam |
|---|---|---|
| `GIT_AGENT_MAX_BYTES` | `104857600` | limit velikosti souboru (100 MB) |
| `GIT_AGENT_COPILOT_BIN` | `copilot` | binárka GitHub Copilot CLI |
| `GIT_AGENT_COPILOT_TIMEOUT` | `60` | timeout pro generování zprávy [s] |
| `GIT_AGENT_GLOBAL_ROOT` | `$HOME` | kořen globálního hledání (např. `/`) |
| `GIT_AGENT_LOG` | – | soubor pro kompletní log průběhu |
| `GIT_NOTIFI` | `1` | notifikace přes `nh system notification` (NetHunter CLI); `0` vypne |
| `GIT_AGENT_NH_BIN` | `nh` | binárka pro notifikace |
| `GIT_AGENT_KILL_GRACE` | `0.5` | čekání [s] mezi SIGTERM a SIGKILL při dočišťování copilot |
| `GIT_AGENT_DRY_RUN=1` | – | nic neměnit, jen vypsat akce |
| `GIT_AGENT_NO_COLOR=1` | – | výstup bez barev |

## Zprávy commitů

Po stage se agent automaticky zeptá **GitHub Copilot CLI** na shrnutí změn
a použije ho jako zprávu commitu. Pro klasickou zprávu `$(date) git-agent`
přidej `--no-commit-message` (nebo zkráceně `-im`).

## Notifikace

Agent posílá systémové notifikace přes NetHunter CLI (`nh system notification -t … -c …`) —
defaultně **zapnuté** (`GIT_NOTIFI=1`). Přijdou při: konfliktu řešeném copilotem,
výsledku opravy a v závěrečném shrnutí. Když `nh` není nainstalované, agent to
tiše ignoruje. Vypnutí: `GIT_NOTIFI=0 git-agent -g`.

### Procesní hygiena

Copilot CLI se spouští ve **vlastní procesní skupině** (`setsid`). Po skončení
(nebo Ctrl+C/timeoutu) agent celou skupinu dočistí (SIGTERM → SIGKILL), takže po
agentovi nezůstávají žádné zombie/qmd-server/node procesy.

## Publikování / první push

```bash
gh repo create git-agent --public --source=. --remote=origin --push
```

## Testy

```bash
tests/run-tests.sh    # offline; používá stub copilot a stub git-lfs
```

## Struktura

```
git-agent.sh        # samotný agent (instaluje se jako ~/.local/bin/git-agent)
setup.sh            # idempotentní instalace závislostí + agenta
tests/run-tests.sh  # end-to-end testy (čisté repo, konflikt→copilot, 100MB limit, LFS, CLI)
```
