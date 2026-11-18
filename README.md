# Runner – spouštění aplikací na macOS

Nativní aplikace pro macOS (Swift + SwiftUI), která v jednoduchém UI spouští a zastavuje
lokální aplikace pomocí jejich `run.sh`. Žije v horní liště a má i hlavní okno.

## Prvotní zadání

### Co spouštím?

```
/Users/petrsvoboda/GitLab/soukrome/ai-robot-watchlist
/Users/petrsvoboda/GitLab/soukrome/ai-robot-watchlist-forex
/Users/petrsvoboda/GitLab/soukrome/TickView
/Users/petrsvoboda/GitLab/soukrome/TWS-opce
/Users/petrsvoboda/GitLab/soukrome/TWS-opce-rucne
```

A v těchto aplikacích spustím `run.sh`.

### Co chci naprogramovat

Aplikaci, která umožňuje v grafickém jednoduchém UI na macOS spouštět a zastavovat tyto
aplikace. Seznam aplikací je konfigurovatelný a lze přidávat další.

## Sestavení a instalace

Požadavky: macOS 14+, Swift 5.10+ (Xcode nebo Command Line Tools).

```bash
./run.sh              # sestaví, nainstaluje do /Applications, načte spouštěč a spustí Runner
./run.sh --no-install # jen sestaví build/Runner.app
```

Testy: `swift test`.

## Ovládání

### Horní lišta
Ikona ▶︎ (s počtem běžících aplikací). Menu obsahuje podmenu pro každou aplikaci
(Spustit / Zastavit / Restartovat / Otevřít v prohlížeči), dále Spustit vše, Zastavit vše,
otevření hlavního okna, nastavení a ukončení Runneru.

### Hlavní okno
- Seznam aplikací se stavem, portem, PID a dobou běhu.
- Tlačítka v řádku: ▶︎/■ spustit/zastavit, ↻ restart, otevřít webové rozhraní, ✎ upravit.
- Nástrojová lišta: Spustit vše, Zastavit vše, **+ Přidat aplikaci**, Nastavení.
- Pořadí aplikací lze měnit tažením, kontextové menu nabízí úpravu, zobrazení složky,
  otevření logu v Konzoli a odstranění (jen u neběžící aplikace).
- Dolní panel ukazuje log vybrané aplikace (konec souboru, obnovuje se každou sekundu).
- Při otevřeném okně je Runner v Docku; po zavření okna zůstane jen v horní liště.
- Kliknutí na ikonu Runneru v Docku (nebo jeho nové spuštění z Finderu či Launchpadu)
  otevře hlavní okno a přenese ho do popředí.

### Stavy aplikací
| Stav | Význam |
|---|---|
| ⚪️ Zastaveno | neběží |
| 🟡 Spouští se… | proces běží, port webového rozhraní ještě neodpovídá (např. instalace závislostí) |
| 🟢 Běží | proces běží a port odpovídá (bez zadaného portu hned po spuštění) |
| 🟡 Zastavuje se… | odeslán SIGTERM, čeká se na konec |
| 🔵 Běží mimo Runner | port odpovídá, ale aplikaci nespustil Runner (např. ručně z Terminálu); lze ji i tak zastavit |
| 🔴 Chyba | spuštění selhalo nebo aplikace skončila s nenulovým kódem – popis je v řádku a v logu |

## Konfigurace aplikací

Aplikace se přidávají a upravují v UI (tlačítko + nebo ✎). Pro každou aplikaci lze zadat:

| Pole | Význam |
|---|---|
| Název | zobrazovaný název |
| Složka | složka projektu, ve které se skript spouští |
| Spouštěcí skript | výchozí `run.sh`; relativně ke složce nebo absolutní cesta; musí být spustitelný |
| Parametry | předají se skriptu jako v Terminálu, např. `--port 9000` |
| Port webového rozhraní | nepovinný; slouží k detekci běhu a tlačítku „Otevřít v prohlížeči“ |
| Spustit automaticky | aplikace se spustí se startem Runneru |

Konfigurace je uložena v `~/Library/Application Support/Runner/apps.json` a lze ji upravit
i ručně (v nastavení pak „Znovu načíst konfiguraci“). Poškozený soubor se při načtení
zálohuje jako `apps.json.broken-<čas>`. Při prvním spuštění se soubor předvyplní pěti
aplikacemi ze zadání (porty 8092, 8094, 8095, 8090, 8091).

## Převzetí aplikací po restartu Runneru

Při spuštění aplikace si Runner uloží její PID a čas startu procesu do
`~/Library/Application Support/Runner/state.json`. Když Runner skončí a aplikace běží dál
(volba „Nechat běžet“, pád Runneru), po dalším spuštění ji Runner **převezme**: znovu ukazuje
PID, dobu běhu i log a zastavuje celou skupinu procesů jako u vlastního spuštění.

Převezme se jen proces, který stále běží, má stejný čas startu (ochrana proti znovupoužitému
PID) a je vedoucím své skupiny procesů. Neplatné záznamy (např. po restartu Macu) se zahodí.
Návratový kód převzaté aplikace se zjistí od launchd stejně jako u běžného spuštění.

## Nastavení

- **Spouštět Runner po přihlášení** – při prvním spuštění sestavené `Runner.app` se zapne
  automaticky. Po spuštění při přihlášení se neotevírá okno, jen ikona v horní liště.
- **Při ukončení Runneru** – zeptat se / zastavit aplikace / nechat aplikace běžet.
- **Čekat na ukončení aplikace** – po kolika sekundách od SIGTERM přijde SIGKILL (výchozí 5 s).

## Jak to funguje

- Skript se spouští přes login shell `/bin/zsh -l -c 'cd … && exec ./run.sh …'`, aby měl
  stejný `PATH` jako v Terminálu (Python z Homebrew). `PATH` se navíc doplní
  o `/opt/homebrew/bin` a `/usr/local/bin`; nastaví se `PYTHONUNBUFFERED=1`.
- Každá aplikace běží jako samostatná **launchd úloha** v doméně `gui/<uid>`
  (plist v `~/Library/Application Support/Runner/jobs/`, bez KeepAlive, při přihlášení se
  nenačítá). Rodičem aplikace je launchd, ne Runner, a má vlastní „coalition“.
- Úlohy do launchd nenačítá Runner, ale **spouštěč** – viz kapitola níže.
- launchd spouští úlohu jako vedoucího nové skupiny procesů (PGID = PID). Zastavení posílá
  SIGTERM celé skupině, takže skončí i podřízené procesy; po skončení se úloha z launchd odebere.
- Výstup (stdout i stderr) jde přímo do `~/Library/Logs/Runner/<název>_<id>.log` (launchd připisuje).
  Aplikace tak může běžet dál i po ukončení Runneru. Log se při velikosti nad 5 MB
  při dalším startu odsune do `.log.1`.
- Porty se kontrolují každé 2 s připojením na `127.0.0.1:<port>`. Aplikace „mimo Runner“
  se zastavují podle PID z `lsof`.
- Konec procesů hlídá kqueue (`DispatchSource.makeProcessSource`); návratový kód nebo signál
  se zjistí z `launchctl print` (funguje i pro aplikace převzaté po restartu Runneru).

## Spouštěč a „práce na pozadí“ v Docku

Když se ukončí aplikace s ikonou v Docku a zůstanou po ní procesy, macOS ji v Docku nechá
jako „běžící na pozadí“. Jakmile ji tam uživatel ukončí, systém zastaví vše, co aplikaci
připisuje:

- procesy v její „coalition“ (všichni potomci, i s vlastní skupinou procesů),
- launchd úlohy, které do launchd načetla – a to i nepřímo přes pomocnou úlohu.

Aby aplikace spuštěné Runnerem opravdu běžely nezávisle, načítá jejich úlohy do launchd
**spouštěč**: malý trvalý launchd agent `local.runner.launcher`.

- Plist: `~/Library/LaunchAgents/local.runner.launcher.plist` (při přihlášení ho načte sám
  launchd, takže nepatří žádné aplikaci). Skript: `~/Library/Application Support/Runner/launcher.sh`.
- Runner mu přes pojmenovanou rouru `launcher.fifo` pošle cestu k plistu úlohy; spouštěč
  přijímá jen plisty ze složky `jobs/` a volá `launchctl bootstrap`.
- Chyby spouštěče jsou v `~/Library/Logs/Runner/launcher.log`.
- Instaluje ho `./run.sh` (`Runner --install-launcher`). macOS při první instalaci ukáže
  oznámení, že se na pozadí může spouštět položka „bash“ – to je spouštěč.

**Po první instalaci se jednou odhlaste a přihlaste.** Do té doby je spouštěč připsaný
aplikaci, ze které jste spustili `./run.sh` (např. Terminálu): aplikace by zastavilo ukončení
práce na pozadí této aplikace. Po přihlášení ho načte launchd a nepatří nikomu.

Další spuštění `./run.sh` už načtený spouštěč do launchd znovu nenačítají – při změně skriptu
ho jen restartují (`launchctl kickstart -k`), což nemění, komu je připsaný. Výjimkou je změna
jeho plistu při upgradu; pak je potřeba se znovu odhlásit a přihlásit.

Pokud spouštěč neběží (instalace bez `run.sh`, ruční odebrání), načte ho Runner sám a v hlavním
okně na to upozorní: úlohy jsou pak až do příštího přihlášení připsané Runneru.

## Ikona

Ikonu `Resources/AppIcon.icns` generuje skript `scripts/make-icon.swift` (kreslí ji přes
AppKit, žádné externí soubory). Po úpravě motivu ji přegenerujte:

```bash
swift scripts/make-icon.swift   # vytvoří Resources/AppIcon.icns a náhled build/AppIcon-preview.png
```

## Struktura projektu

```
Package.swift                 Swift balíček (cíl Runner + testy)
run.sh                        sestavení Runner.app, instalace, načtení spouštěče a spuštění
scripts/make-icon.swift       generátor ikony aplikace
Resources/Info.plist          Info.plist balíčku (LSUIElement – aplikace v horní liště)
Resources/AppIcon.icns        ikona aplikace
Sources/Runner/
  RunnerApp.swift             vstupní bod, AppDelegate (autostart, ukončení, login item)
  Model/
    AppDefinition.swift       definice aplikace a její validace
    ConfigStore.swift         načítání a ukládání apps.json, výchozí aplikace
    AppSettings.swift         uživatelské nastavení (UserDefaults)
  Process/
    ProcessSpawner.swift      spuštění aplikace, sledování konce, signály skupině
    LaunchdJob.swift          launchd úlohy: spuštění, stav (launchctl print), odebrání
    Launcher.swift            spouštěč: launchd agent načítající úlohy místo Runneru
    AppRunner.swift           stav a řízení jedné aplikace
    RunnerManager.swift       správa všech aplikací, kontrola portů, převzetí, hromadné akce
    RunStateStore.swift       state.json – záznamy o spuštěných procesech pro převzetí
    ProcessInspector.swift    čas startu a skupina procesu (sysctl)
    PortProbe.swift           test portu, PID podle portu (lsof)
    LogFile.swift             logy: příprava, rotace, čtení konce, čištění ANSI
  Support/LoginItem.swift     spouštění po přihlášení (SMAppService)
  Support/JSONFile.swift      společné čtení a zápis JSON (apps.json, state.json)
  Support/Shell.swift         spouštění externích nástrojů, čekání na stav, společná chyba
  Views/                      SwiftUI pohledy (okno, řádek, log, editor, nastavení, menu)
Tests/RunnerTests/            testy jádra (konfigurace, procesy, převzetí, porty, logy)
```

## Licence

Projekt je šířen pod licencí [Apache License 2.0](LICENSE).
