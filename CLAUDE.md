# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Projekt

`git-agent` je sada čistě bashových skriptů (bez build kroku, bez lintu): najde git repozitáře, nepushnuté změny commitne a pushne, zprávu commitu generuje GitHub Copilot CLI a konflikty při pullu/pushi předává copilotovi. Dokumentace, komentáře i výstup jsou v češtině — drž to.

## Příkazy

```bash
tests/run-tests.sh              # všechny testy (offline, stub copilot + stub git-lfs)
bash -n git-agent.sh            # kontrola syntaxe
GIT_AGENT_DRY_RUN=1 ./git-agent.sh        # nic nemění, jen vypíše akce
GIT_AGENT_NO_COLOR=1 ./git-agent.sh -h    # nápověda bez barev
./setup.sh [--cron]             # instalace závislostí + kopie skriptů do ~/.local/bin
```

`tests/run-tests.sh` je jeden skript bez výběru jednotlivého testu; scénáře jsou označené (např. `J5`) v názvech `ok/FAIL` řádků, takže se hledá přes `tests/run-tests.sh 2>&1 | grep J5`. Při posledním běhu selhaly 2 testy (`J5: pullů v souhrnu` a další) — jsou to existující selhání, ne regrese.

## Architektura

- `git-agent.sh` (jediný soubor ~650 řádků) – hlavní agent. Tok: parsování argumentů → `find_repos` (find s `PRUNE_NAMES`, `.git` se řeší zvlášť přes `-prune -print`) → deduplikace přes `SEEN` (`--show-toplevel`) → pro každý repozitář `process_repo` (commit + push) nebo `pull_repo` (akce `pull`) → `summary` (exit kód = počet selhavších repozitářů, max 125).
- Copilot se volá výhradně přes `spawn_agent` (stdin ze souboru, `setsid` = vlastní procesní skupina, `timeout`); `stop_agent_group` + trapy `EXIT/INT/TERM` skupinu dočišťují (SIGTERM→SIGKILL). Nové volání copilota vždy veď přes `spawn_agent`, jinak zůstanou zombie/node procesy.
- `copilot_resolve_and_push` po zásahu copilota **ověřuje** výsledek (čistý strom, `ahead=0`) — nespoléhá na rc copilota.
- Pravidlo: soubory >100 MB (`GIT_AGENT_MAX_BYTES`) se nikdy necommitují ani se neřeší přes `.gitignore`; řešení je `--add-lfs`. `pull --reset` je destruktivní a musí se zadat explicitně (samotné `--reset` končí chybou).
- `git-agent-cron.sh` – obálka pro cron: nastaví PATH (nvm/node), loguje do `~/.local/state/git-agent/cron.log`, řídí notifikace sám (agentovi vypíná `GIT_NOTIFI`) a rozhoduje podle parsování řádku souhrnu `repozitářů: … commitů: N | pullů: N | pushů: N` — při změně formátu `summary()` v agentovi je nutné upravit i regex v cron wrapperu.
- `setup.sh` – idempotentní instalace; kopíruje `git-agent.sh` → `~/.local/bin/git-agent` a `git-agent-cron.sh` → `~/.local/bin/git-agent-cron` (editace v repu se do systému projeví až po novém `setup.sh`).
- Proměnné prostředí (`GIT_AGENT_*`, `GIT_NOTIFI`) jsou popsané v hlavičce `git-agent.sh` a v README.

## Testy

Testy běží v dočasném sandboxu s izolovaným git configem. Scénář „push rejected → copilot“ používá remote na neexistující cestu (deterministické selhání pushe); stub `copilot` mění chování přes `COPILOT_STUB_MODE` (`fix` / `commitmsg` / jiné = selhání). Stub `git-lfs` nesmí číst stdin (git by se zasekl).

## Poznámky

- `VERSION` je v `git-agent.sh` (aktuálně `1.4.0`, i když commity jsou po 1.4.2) a commity mají formát `git-agent X.Y.Z: popis`.
- `tests/run-tests.sh.bak` je zálohový soubor; `.pi/` je v `.gitignore`.
