# settings.json pro git-agent — návrh

Datum: 2026-10-07 · Stav: schváleno konverzačně, čeká na review spec souboru

## Cíl

Řídit chování agenta podle repozitáře z jednoho globálního souboru: repo ignorovat,
určit které větve pushovat, automaticky mergovat `from` → `to` přes PR (`gh`) a
doplnit vlastní prompt pro copilota při konfliktu. Při hledání repozitářů agent
nová repa sám zapíše do souboru s výchozím nastavením. Bez souboru / bez položky
se chová jako dnes.

## Soubor

- Umístění: `~/.config/git-agent/settings.json` (přepsání: `GIT_AGENT_SETTINGS=<cesta>`).
- Jen globální soubor (žádné per-repo `.git-agent.json`).

```json
{
  "defaults": { "ignore": false, "push": "current" },
  "repos": {
    "/root/git-agent": { "ignore": false, "push": "current" },
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

## Pravidla

**Vyhodnocení nastavení repa:** přesná cesta (absolutní, po `readlink -f`) má
přednost před globem; globy se berou v pořadí souboru, první shoda vyhrává (`~`
se expanduje). Klíče z repa přepíšou `defaults`, chybějící se doplní z `defaults`.

**`ignore: true`** — repo se přeskočí v commitu, pushi, pullu i merge.

**`push`:**
- `"current"` (výchozí) — dnešní chování, jen aktuální větev,
- `"all"` — všechny lokální větve s upstreamem,
- seznam názvů větví (jedna větev = seznam o jednom prvku).
Pushují se nepushnuté commity ve zvolených větvích bez přepínání větve
(`git push <remote> <branch>`).

**`merge`** (`from`, `to`, `strategy` = `merge`|`squash`|`rebase`, výchozí `merge`),
provede se po úspěšném pushi větve `from`:
1. pokud `from` není před `to`, nic se neděje,
2. pokud PR `from→to` neexistuje, `gh pr create`; poté rovnou `gh pr merge`,
3. při konfliktu agent v lokálním repu zmerguje `to` do `from`, konflikt předá
   copilotovi, pushne a merge zopakuje (jednou),
4. bez `gh` auth, bez GitHub remote nebo bez větve `from` se merge přeskočí
   s varováním (nejde o chybu repozitáře).

**`conflict_prompt`** — text připojený k promptu pro copilota při konfliktu v
pullu, pushi i merge. Nenahrazuje základní prompt s kontextem ani ověření
výsledku (čistý strom, `ahead=0`).

## Automatická registrace repozitářů

- Po `find_repos` (a deduplikaci přes `SEEN`) se každé nalezené repo bez přesného
  klíče v `repos` a bez shody globu zapíše s `{ "ignore": false, "push": "current" }`.
- Platí v lokálním i globálním režimu, před zpracováním repa.
- Existující položky se nikdy nemění ani nemažou; smazaná repa agent nečistí.
- Zápis atomicky (`jq` → dočasný soubor → `mv`) pod stávajícím `flock`.
- Poškozený JSON: nezapisuje, varuje a použije defaulty (nepřepíše úpravy uživatele).
- `GIT_AGENT_DRY_RUN=1`: nezapisuje, jen vypíše, co by přidal.
- Souhrn na konci rozšířit o `nových repozitářů: N`.

## Implementace

- `jq` (už instaluje `setup.sh`).
- `git-agent.sh`: `load_settings` (jednou), `register_repos` (po hledání),
  `load_repo_settings <repo>` (nastaví `REPO_IGNORE`, `REPO_PUSH`, `REPO_MERGE_*`,
  `REPO_CONFLICT_PROMPT`; volá `process_repo` a `pull_repo`), rozšíření
  `push_if_needed` o větve, nová `merge_via_pr`, předání `conflict_prompt` do
  `copilot_resolve_and_push`; copilot se dál volá jen přes `spawn_agent`.
- Chybné JSON / neznámý klíč: varování, pro dotčené repo defaulty.
- Pozor: `git-agent-cron.sh` parsuje řádek souhrnu (`commitů: N | pullů: N | pushů: N`);
  nový údaj přidat tak, aby regex dál fungoval.
- Aktualizovat README a hlavičku `git-agent.sh` (nová proměnná `GIT_AGENT_SETTINGS`),
  zvednout `VERSION`.

## Testy (`tests/run-tests.sh`)

Ignore; push `all` a seznam větví; pořadí shod (přesná cesta vs glob); automatická
registrace (nové repo, existující se nepřepíše, dry-run nezapisuje); poškozený JSON;
`conflict_prompt` v logu promptů stubu copilota; merge přes stub `gh` (vytvoření
PR, merge, konflikt → copilot, chybějící `gh`).

## Mimo rozsah

Per-repo konfigurační soubory, čištění zmizelých repozitářů, jiné hostingy než GitHub.
