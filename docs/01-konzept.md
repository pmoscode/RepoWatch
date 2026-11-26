# Konzept: Native macOS-Menüleisten-App für GitHub-Repositories

> Arbeitstitel: **RepoWatch** (Ordner/Repo darf `github-watch` bleiben – im App-Namen selbst
> sollte „GitHub“ wegen der GitHub-Markenrichtlinien besser nicht vorkommen).
> Stand: 25.11.2026 · Status: Entwurf, offene Entscheidungen geklärt (Abschnitt 12)

---

## 1. Ziel und Umfang

Eine kleine, schnelle Menüleisten-App (kein Dock-Icon), die alle Repositories, auf die mein
GitHub-Account Zugriff hat, im Blick behält. Sie zeigt auf einen Blick, wo etwas passiert und
wo ich handeln muss.

### v1 (dieses Konzept)

| Bereich | Was die App zeigt |
|---|---|
| **Issues** | Anzahl offener Issues pro Repo und gesamt · Titel, Nummer, Labels, Alter · Klick öffnet das Issue im Browser |
| **Pull Requests** | Offene PRs pro Repo · **wer sie erstellt hat**, eingeteilt in *Renovate*, *Dependabot*, *andere Bots*, *ich*, *Mensch* · Entwurfs-Status · CI-Status (✓/✗/läuft) · Link |
| **Aktivität** | Aktivitätsstufe pro Repo (ruhend → hoch) · Commits der letzten 7/30 Tage · letzter Push · neue/geschlossene Issues und PRs · Ereignis-Feed in der Detailansicht |
| **GitHub Actions** | Status des Standard-Branches pro Repo (✓/✗/läuft) · erfolgreiche und fehlgeschlagene Workflow-Runs mit Workflow, Branch, Auslöser, Dauer und Link · „rot seit …“ pro Workflow · laufende Runs |

### Ausdrücklich nicht in v1 (aber im Design vorgesehen)

Benachrichtigungen (z. B. „Workflow fehlgeschlagen“), Review-Status, Review-Anfragen, Runs neu starten, Desktop-Widgets, globaler Hotkey,
mehrere Accounts / GitHub Enterprise, Aktionen wie Mergen oder Schließen.
→ Diese kommen später als **Module** dazu (siehe Abschnitt 9), ohne dass der Kern umgebaut werden muss.

---

## 2. Leitprinzipien

1. **Ein Blick genügt.** Das Popover beantwortet in unter 2 Sekunden: *Wo ist etwas Neues? Was wartet auf mich?*
2. **Sofort da.** Beim Öffnen werden die zuletzt geladenen Daten angezeigt; die Aktualisierung läuft im Hintergrund.
3. **Sparsam mit der API.** Wenige gebündelte GraphQL-Abfragen statt Hunderter REST-Aufrufe; Repos ohne Bewegung werden seltener abgefragt.
4. **Erweiterbar durch Module.** Issues, PRs, Aktivität und Actions sind die ersten vier Module eines Plug-in-Systems. Jede neue Funktion ist ein weiteres Modul.
5. **Nativ und unaufdringlich.** SwiftUI, Systemschriften, SF Symbols, Liquid Glass, Dark Mode, Tastaturbedienung, VoiceOver.
6. **Nur Lesezugriff, sicher gespeichert.** Das Token liegt im Schlüsselbund, die App ist sandboxed und hat keinen eigenen Server.

---

## 3. Bedienung

### 3.1 Menüleiste

- Eigenes Symbol (SF Symbol oder Template-Bild), optional mit Zähler.
- Einstellbar, was angezeigt wird: *nichts* · *Punkt bei Neuem* (Standard) · *offene PRs von Menschen* · *Summe offener Issues und PRs*.
- Unabhängig davon (abschaltbar): Das Symbol bekommt einen **roten Punkt**, wenn ein Workflow auf dem Standard-Branch oder in einem PR von einem Menschen bzw. von mir fehlgeschlagen ist (E7). Fehlschläge in Bot-PRs lösen keinen Alarm aus.
- **Technik (E6):** eigenes `NSStatusItem`; ein Klick öffnet ein `NSPanel` direkt unter dem Symbol, das per `NSHostingView` den SwiftUI-Inhalt zeigt. Das Panel schließt bei Klick daneben oder mit Esc und lässt sich per Code öffnen (später für einen globalen Hotkey).
- Bei einem Fehler (offline, Token abgelaufen) wird das Symbol dezent ausgegraut, mit Hinweis im Popover.

### 3.2 Popover (ca. 400 × 600 pt)

```
┌──────────────────────────────────────────────────┐
│ ◉ pmoscode               🔍 Suchen…     ⟳    ⚙︎   │
│ [Übersicht│Issues 23│PRs 9│Actions ✗2│Aktivität]  │
├──────────────────────────────────────────────────┤
│ ★ FAVORITEN                                       │
│ github-watch             ✓ main    ●●●  vor 2 Std │
│   ◎ 4   ⇄ 2  (👤 1 · 🤖 1)          12 Commits/7T │
│ homelab                  ✗ main    ●●○  vor 1 Tag │
│   ◎ 1   ⇄ 5  (🤖 5)    ✗ seit 2 Tg   3 Commits/7T │
│                                                   │
│ ALLE REPOSITORIES (42)        Sortieren: Aktivität▾│
│ dotfiles                 – kein CI ●○○  vor 9 Tg  │
│   ◎ 0   ⇄ 1  (🤖 1)                               │
│ …                                                 │
├──────────────────────────────────────────────────┤
│ Aktualisiert vor 1 Min · API 4.812 / 5.000        │
└──────────────────────────────────────────────────┘
```

- **Übersicht:** Repo-Liste mit Favoriten oben. Pro Zeile: Name, CI-Status des Standard-Branches, Aktivitätsstufe, letzter Push, Anzahl Issues, Anzahl PRs nach Autor-Art. Neue Einträge seit dem letzten Öffnen sind markiert.
- **Issues:** alle offenen Issues über alle Repos, sortiert nach letzter Änderung, filterbar nach Repo und Label.
- **PRs:** gruppiert nach *Von Menschen* (zuerst, weil hier meist eine Review nötig ist), *Von mir*, *Renovate*, *Dependabot*, *Andere Bots*. Bot-Gruppen sind standardmäßig eingeklappt („Renovate: 14 PRs in 6 Repos“).
- **Actions:** drei Gruppen: *Fehlgeschlagen* (zuerst; pro Workflow und Branch nur der neueste Run, solange kein späterer Erfolg folgt) · *Läuft gerade* · *Zuletzt erfolgreich* (eingeklappt). Filter: nur Standard-Branch / alle Branches, Auslöser (push, pull_request, schedule, …), Runs von Bot-PRs ausblenden (nutzt die Autor-Einteilung aus Abschnitt 6).
- **Aktivität:** chronologischer Feed (Pushes, PR geöffnet/gemergt, Issue geöffnet/geschlossen, Releases) für die aktiven Repos.
- **Detailansicht** (Klick auf ein Repo, Navigation innerhalb des Popovers): Kopfbereich mit Beschreibung, Sichtbarkeit, Link; darunter ein Abschnitt pro Modul (Issue-Liste, PR-Liste, letzte Workflow-Runs mit Erfolgsquote pro Workflow, Wochen-Sparkline der Commits, Ereignis-Feed).
- **Interaktion:** Klick → im Browser öffnen · Kontextmenü: *Link kopieren*, *Als gesehen markieren*, *Zu Favoriten* · Tastatur: ⌘F Suche, ⌘R Aktualisieren, ⌘, Einstellungen, Pfeiltasten + ↩.

### 3.3 Einstellungsfenster

| Reiter | Inhalt |
|---|---|
| Konto | Anmelden/Abmelden, angemeldeter Benutzer, Token-Art, API-Kontingent |
| Repositories | Archivierte/Forks ausblenden, Organisationen ein-/ausschließen, Muster zum Ausschließen, Favoriten |
| Pull Requests | Regeln zur Autor-Einteilung (z. B. eigene Renovate-Instanz `my-renovate-bot`) |
| Actions | Welche Branches im Reiter erscheinen (Standard-Branch / alle), Auslöser ausblenden (z. B. `schedule`), roter Punkt in der Menüleiste an/aus und wofür (Standard: Standard-Branch + Menschen-PRs) |
| Aktualisierung | Intervall für aktive bzw. ruhende Repos, nur im Netzteilbetrieb usw. |
| Module | Module an/aus, Reihenfolge der Reiter und Abschnitte |
| Allgemein | Bei Anmeldung starten, Anzeige in der Menüleiste, Sprache folgt dem System |

---

## 4. Daten von GitHub

### 4.1 Strategie: GraphQL für den Überblick, REST nur gezielt

**GraphQL (`POST /graphql`)** ist die Hauptquelle, weil sich Repos inklusive Issues, PRs und
Commit-Zahlen mit wenigen Abfragen holen lassen.

**Zwei Abfrage-Stufen:**

1. **Bestand** (seitenweise, 100 Repos pro Seite): alle erreichbaren Repos mit Metadaten und Zählern.
   ```graphql
   query Inventory($cursor: String) {
     viewer {
       login
       repositories(first: 100, after: $cursor,
                    affiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER],
                    ownerAffiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER],
                    orderBy: {field: PUSHED_AT, direction: DESC}) {
         pageInfo { hasNextPage endCursor }
         nodes {
           id nameWithOwner url isPrivate isFork isArchived pushedAt updatedAt
           issues(states: OPEN) { totalCount }
           pullRequests(states: OPEN) { totalCount }
         }
       }
     }
     rateLimit { cost remaining resetAt }
   }
   ```
2. **Details** für ausgewählte Repos, gebündelt über `nodes(ids: [...])` in Paketen à 10 Repos (Zeitlimit, siehe 4.3). Die Felder bringen die
   Module selbst mit (siehe 9.2), z. B.:
   ```graphql
   ... on Repository {
     m_issues: issues(states: OPEN, first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) {
       totalCount
       nodes { number title url createdAt updatedAt author { login }
               labels(first: 5) { nodes { name color } } }
     }
     m_prs: pullRequests(states: OPEN, first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) {
       totalCount
       nodes { number title url isDraft createdAt headRefName
               author { __typename login }
               commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } }
     }
     m_activity_commits7: defaultBranchRef { target { ... on Commit {
       history(since: $since7d) { totalCount } } } }
     m_actions_head: defaultBranchRef { name target { ... on Commit {
       statusCheckRollup { state }
       checkSuites(first: 10) { nodes { status conclusion app { slug }
         workflowRun { runNumber url createdAt event workflow { name } } } } } } }
     m_actions_workflows: object(expression: "HEAD:.github/workflows") {
       ... on Tree { entries { name } } }
   }
   ```

**REST** nur dort, wo GraphQL nichts liefert – und immer mit `ETag`/`If-None-Match`, weil
Antworten mit `304 Not Modified` nicht auf das Kontingent angerechnet werden:
- `GET /repos/{owner}/{repo}/events` → Ereignis-Feed (nur aktive Repos, nur Detailansicht/Aktivitätsreiter)
- `GET /repos/{owner}/{repo}/stats/participation` → Commits pro Woche für die Sparkline (kann beim ersten Aufruf `202` liefern → später erneut versuchen)
- `GET /repos/{owner}/{repo}/actions/runs?per_page=30` → Workflow-Runs aller Branches (nur Repos, die Workflows haben und aktiv sind; siehe Abschnitt 8)

**Hinweis:** Über GraphQL zählt `issues.totalCount` nur echte Issues. Das REST-Feld
`open_issues_count` enthält dagegen auch PRs – dieser Fallstrick entfällt also.

### 4.2 Aktualisierungs-Takt

| Stufe | Welche Repos | Standard-Intervall |
|---|---|---|
| **Aktiv** | Favoriten + Repos mit Push/Änderung in den letzten 7 Tagen | 5 Min. |
| **Ruhend** | alle übrigen | 30–60 Min. |
| **Bestand** | Liste aller Repos (neue/gelöschte erkennen) | 30 Min. |
| **Kurztakt** | Repos mit gerade laufendem Workflow-Run, bis der Run fertig ist | 1 Min. |

Zusätzliche Auslöser: Popover öffnen (wenn die Daten älter als 1 Min. sind), Aufwachen aus dem
Ruhezustand, Netzwerk wieder verfügbar, ⌘R. Bei Rate-Limit-Fehlern oder `Retry-After` wird
exponentiell gewartet; es laufen höchstens 2–3 Anfragen parallel, um die sekundären Limits
von GitHub nicht auszulösen.

**Kosten:** Siehe die Messwerte in 4.3. Ein kompletter Durchlauf (Bestand + Details aller
aktiven Repos) kostet rund 35 Punkte, im 5-Minuten-Takt also ca. 420 von 5.000 Punkten pro
Stunde. Der gestufte Takt ist hier also Reserve für später, nicht zwingend nötig. REST hat ein
eigenes Kontingent (5.000 Anfragen pro Stunde). Bei 39 Repos mit Workflows im 5-Minuten-Takt
sind das höchstens ca. 470 `actions/runs`-Anfragen pro Stunde, und die meisten davon sind
kostenlose `304`-Antworten.

### 4.3 Messwerte aus dem Spike (26.11.2026)

Gemessen mit dem `gh`-Token (Scopes `repo`, `read:org`, also wie die geplante OAuth-App):

| Messung | Ergebnis | Folge fürs Design |
|---|---|---|
| Erreichbare Repos | **79**, davon 9 archiviert → **70 aktiv** in 6 Owner-Konten | passt in **eine** Bestandsseite (`first: 100`) |
| Bestandsabfrage | **1 Punkt**, ca. 1 s | darf ruhig oft laufen |
| Detail-Abfrage, alle Fragmente, **25 Repos** | **HTTP 502** (Zeitlimit von GitHub, ca. 10 s) | **Pakete nach Rechenzeit schneiden, nicht nach Punkten** |
| Detail-Abfrage, alle Fragmente, Pakete à 5 / 10 / 15 | max. 2,6 / 4,2 / 5,2 s pro Anfrage; gesamt 28 / 35 / 33 Punkte für 70 Repos | **Paketgröße 10** (Puffer zum Limit), 2–3 Anfragen parallel → Detail-Durchlauf in ca. 8–10 s |
| Teuerste Fragmente (Zeit) | `commits(last:1){statusCheckRollup}` an PRs, `history(since:)`, Activity-Items | Bei 502 automatisch Paket halbieren und erneut versuchen |
| Punkte je Fragment | `issues` mit Labels: bis 15 Punkte (70 Repos), alle anderen 1 | Punkte spielen bei ca. 70 Repos praktisch keine Rolle |
| Bot-Logins in GraphQL | `__typename: "Bot"`, Login **`renovate`** bzw. **`dependabot`** (ohne `[bot]`; das Suffix gibt es nur in REST) | Regel 1 in Abschnitt 6 muss beide Schreibweisen kennen |
| Offene PRs (aktive Repos) | 107, davon 98 Renovate, 6 Dependabot, **3 von Menschen** | Gruppierung nach Autor-Art lohnt sich sehr |
| CI-Status offener PRs | 57 ✓, 17 ✗, 1 läuft, 32 ohne Status; **alle 17 Fehlschläge in Bot-PRs** | E7 ist ruhig: Der Alarm wäre heute aus, der Actions-Reiter zeigt die 17 trotzdem |
| Repos mit `.github/workflows` | **39 von 70** | REST `actions/runs` nur für diese |
| `statusCheckRollup` am Standard-Branch | 20 ✓, 3 ✗, **47 ohne Status** (auch Repos mit Workflows, deren letzter Commit keine Läufe hatte) | „kein Status am letzten Commit“ (–) von „kein CI“ (keine Workflows) unterscheiden |
| `checkSuites` am HEAD | Apps: `github-actions` (160), `renovate` (28), `semgrep-…` (3), `github-pages` (1); alle `github-actions`-Suites haben `workflowRun` | Für Actions nach `app.slug == "github-actions"` filtern. `statusCheckRollup` enthält auch fremde Checks und ist deshalb „CI allgemein“ |
| REST `actions/runs` mit `If-None-Match` | **304**, `x-ratelimit-remaining` unverändert | ETag-Strategie bestätigt |
| Leere Repos | 1 Repo ohne Standard-Branch (`defaultBranchRef: null`) | Module müssen `null` vertragen |
| Repos ohne `pushedAt` | keins (das Schema erlaubt es aber, ein Test deckt den Fall ab) | – |

Noch offen, weil dafür Beobachtung über Zeit nötig ist: ob `pushedAt`/`updatedAt` als Signal
für „aktiv/ruhend“ taugen. Das klärt Phase 2 mit dem `ChangeDetector`.

---

## 5. Anmeldung

| Variante | Vorteile | Nachteile | Rolle |
|---|---|---|---|
| **OAuth-App mit Device Flow** | Beste Bedienung (Code anzeigen → im Browser bestätigen), kein Client-Secret in der App, erreicht alle Repos | Scope `repo` umfasst auch Schreibrechte; Organisationen mit OAuth-Beschränkung müssen die App freigeben | **Standard** |
| **Fine-grained Personal Access Token** | Nur Leserechte möglich, keine App-Registrierung | Manuell anlegen, läuft ab, für Organisationen ggf. Freigabe nötig | Alternative im Einstellungsfenster |
| **Umgebungsvariable `GITHUB_TOKEN`** | Schnell für die Entwicklung | Nur in Debug-Builds | Entwicklung |

- Scopes für die OAuth-App: `repo`, `read:org` (später `notifications`). `repo` reicht auch zum Lesen der Actions-Runs privater Repos; der Scope `workflow` ist nicht nötig, weil er nur zum Ändern von Workflow-Dateien dient.
- Fine-grained PAT, nur lesend: *Metadata*, *Contents*, *Issues*, *Pull requests*, *Actions*.
- Das Token wird im **Schlüsselbund** gespeichert (`kSecClassGenericPassword`, nur dieses Gerät).
- Eine GitHub-App mit fein abgestuften Leserechten wäre am sparsamsten, müsste aber auf jedem
  Account bzw. jeder Organisation installiert werden. Deshalb später als Option denkbar, nicht für v1.

---

## 6. Wer hat den PR erstellt?

Die Einteilung läuft über eine **geordnete Regelkette**. Die erste passende Regel gewinnt. Die
Regeln sind konfigurierbar und als Protokoll umgesetzt, damit neue Regeln leicht dazukommen.

| # | Regel | Ergebnis |
|---|---|---|
| 1 | Login steht auf einer Liste (`renovate`/`renovate[bot]`, `dependabot`/`dependabot[bot]` + eigene Einträge, z. B. eine selbst betriebene Renovate-Instanz). GraphQL liefert Bot-Logins ohne `[bot]`, REST mit (4.3) | `Renovate` / `Dependabot` |
| 2 | Branch beginnt mit `renovate/` bzw. `dependabot/` | `Renovate` / `Dependabot` |
| 3 | `author.__typename == "Bot"` oder Login endet auf `[bot]` | `Andere Bots` (mit Namen, z. B. „github-actions“) |
| 4 | Login entspricht dem angemeldeten Benutzer | `Ich` |
| 5 | sonst | `Mensch` |

```swift
enum PRAuthorKind: Codable, Hashable {
    case dependencyBot(DependencyBot)   // .renovate, .dependabot
    case bot(name: String)
    case me
    case human(login: String)
}

protocol PRClassificationRule: Sendable {
    func classify(_ pr: PullRequestSummary, context: ClassificationContext) -> PRAuthorKind?
}
```

---

## 7. Aktivität

Pro Repo werden Kennzahlen aus den ohnehin geladenen Daten berechnet:

- `commits7d`, `commits30d` (Historie des Standard-Branches)
- `issuesOpened7d`, `issuesClosed7d`, `prsOpened7d`, `prsMerged7d` (aus den zuletzt geänderten Einträgen)
- `lastPush` (`pushedAt`)

**Aktivitätswert** (Startgewichtung, später einstellbar):

```
score = 3·commits7d + 2·(prsOpened7d + prsMerged7d) + 1·(issuesOpened7d + issuesClosed7d)
        + Bonus für Frische (Push < 24 h: +5, < 72 h: +2)
```

Daraus ergibt sich eine Stufe: **ruhend** (0) · **niedrig** · **mittel** · **hoch**. Die
Schwellen werden relativ zu den eigenen Repos gewählt (Quantile), damit die Einteilung
sowohl bei 10 als auch bei 300 Repos aussagekräftig bleibt.

Die Detailansicht zeigt zusätzlich die Wochen-Sparkline (REST `stats/participation`) und den
Ereignis-Feed (REST `events`). Achtung: Die Events-API von GitHub hat eine Verzögerung von
30 Sekunden bis zu einigen Stunden. Sie ist deshalb nur Ergänzung, nicht die Grundlage der Zählung.

---

## 8. GitHub Actions

### 8.1 Zwei Datenquellen

| Quelle | Liefert | Für | Kosten |
|---|---|---|---|
| **GraphQL** (Teil der Detail-Abfrage) | Gesamtstatus des letzten Commits auf dem Standard-Branch (`statusCheckRollup`) + die zugehörigen Workflow-Runs (`checkSuites` mit `app.slug == "github-actions"`) · ob das Repo überhaupt Workflows hat (`.github/workflows`) | ✓/✗ in der Repo-Zeile, roter Punkt in der Menüleiste | nahezu kostenlos, für **alle** Repos |
| **GraphQL** (PR-Fragment) | `statusCheckRollup` des letzten Commits jedes offenen PRs | ✓/✗ an der PR-Zeile, roter Punkt bei Menschen-PRs (E7) | nahezu kostenlos, für **alle** Repos |
| **REST** `actions/runs` mit ETag | die letzten 30 Runs über alle Branches mit `name`, `status`, `conclusion`, `head_branch`, `event`, `actor`, `run_attempt`, `run_started_at`, `updated_at`, `html_url`, `pull_requests` | Actions-Reiter, Detailansicht, „rot seit …“ | 1 Anfrage pro Repo; `304` zählt nicht. Nur für **aktive** Repos **mit** Workflows |

Repos ohne Workflow-Ordner werden für REST gar nicht erst abgefragt und als „kein CI“ angezeigt.
Hat ein Repo Workflows, aber am letzten Commit des Standard-Branches keine Läufe (im Spike
häufig), zeigt die Zeile „–“ und den Stand des letzten abgeschlossenen Runs aus REST, soweit vorhanden.

### 8.2 Status

```swift
enum RunOutcome: Codable, Hashable {
    case success
    case failure          // failure, timed_out, startup_failure
    case cancelled
    case running          // queued, in_progress, waiting, pending, requested
    case skipped          // skipped, neutral, stale
    case actionRequired   // action_required (z. B. Freigabe für Runs von Fork-PRs nötig)
}

struct WorkflowRunSummary: Codable, Hashable, Identifiable {
    let id: Int64
    let workflowName: String
    let runNumber: Int, attempt: Int
    let outcome: RunOutcome
    let branch: String, event: String, actor: String
    let startedAt: Date, updatedAt: Date
    let url: URL
    let pullRequestNumbers: [Int]
}
```

Abgeleitete Werte pro Workflow und Branch:

- **Aktueller Zustand:** Ergebnis des neuesten abgeschlossenen Runs (wiederholte Versuche desselben Runs zählen nur mit dem letzten Versuch).
- **Rot seit:** Zeitpunkt des ersten Fehlschlags nach dem letzten Erfolg, dazu die Anzahl der Fehlschläge in Folge.
- **Erfolgsquote:** Anteil erfolgreicher Runs unter den letzten 30 (nur Detailansicht).
- **Dauer:** `updatedAt − startedAt` des Runs.

### 8.3 Verhalten

- Ein Repo mit laufendem Run kommt in den **Kurztakt** (1 Min.), bis der Run abgeschlossen ist. Danach fällt es in seine normale Stufe zurück.
- Der `ChangeDetector` erzeugt zusätzlich die Änderungen `workflowFailed` und `workflowRecovered`. Darauf können später Benachrichtigungen aufsetzen („homelab: *deploy* auf main fehlgeschlagen“, „… wieder grün“).
- Runs gehören zu PRs über `pull_requests`. Damit lassen sich Runs von Renovate-/Dependabot-PRs über die Autor-Einteilung aus Abschnitt 6 ausblenden oder zusammenfassen. Dieselbe Verknüpfung entscheidet über den Alarm (E7): Ein Fehlschlag zählt, wenn er auf dem Standard-Branch liegt oder zu einem PR der Art `Mensch` bzw. `Ich` gehört.
- Die Events-Verzögerung aus Abschnitt 7 betrifft Actions nicht, weil beide Quellen direkt abgefragt werden.

---

## 9. Architektur

### 9.1 Schichten

```
┌───────────────────────────────────────────────────────────────┐
│ App (Composition Root): StatusItemController + Panel,         │
│ Settings-Szene,                                               │
│ registriert Module, verdrahtet Abhängigkeiten                 │
├───────────────────────────────────────────────────────────────┤
│ Features (SwiftUI): Popover, RepoDetail, Tabs, Settings       │
│ DesignSystem: Chip, CountBadge, RepoRow, Sparkline, …         │
├───────────────────────────────────────────────────────────────┤
│ Modules: Issues · PullRequests · Activity · Actions           │  ← hier wächst die App
│ ModuleKit: InsightModule-Protokoll, Registry, QueryBuilder    │
├───────────────────────────────────────────────────────────────┤
│ Sync: SyncEngine (actor), RefreshScheduler, ChangeDetector    │
│ Persistence: SnapshotStore, SeenStateStore                    │
├───────────────────────────────────────────────────────────────┤
│ GitHubAPI: GraphQLClient, RESTClient (ETag), RateLimitTracker │
│ Auth: DeviceFlow, TokenStore (Keychain)                       │
├───────────────────────────────────────────────────────────────┤
│ Domain: RepoRef, RepoSnapshot, IssueSummary, PR…, ChangeSet   │
└───────────────────────────────────────────────────────────────┘
```

Abhängigkeiten zeigen nur nach unten. `Domain` ist reines Swift ohne Frameworks und dadurch
vollständig testbar.

### 9.2 Erweiterbarkeit: das Modul-System

Jede Funktion ist ein `InsightModule`. Ein Modul legt fest,

1. **welche Daten es braucht** (ein GraphQL-Fragment auf `Repository`, Feldnamen mit Präfix `m_<modul>_`),
2. **wie es sie dekodiert** (Teil der Antwort → eigener `Payload`-Typ),
3. **was es zusammenfasst** (Zähler, Badges, Beitrag zum Menüleisten-Zähler),
4. **wie es sich darstellt** (Zusatzinfo in der Repo-Zeile, Abschnitt in der Detailansicht, optional eigener Reiter).

```swift
public protocol InsightModule: Sendable {
    associatedtype Payload: Codable & Sendable

    static var id: ModuleID { get }
    var metadata: ModuleMetadata { get }              // Titel, SF Symbol, Standard-Reihenfolge

    var repositoryFragment: GraphQLFragment { get }   // Felder pro Repo
    func decode(repository json: JSONValue) throws -> Payload
    func summarize(_ payload: Payload) -> ModuleSummary

    @MainActor func rowAccessory(_ payload: Payload) -> AnyView
    @MainActor func detailSection(_ payload: Payload, repo: RepoRef) -> AnyView
    @MainActor func tab(_ store: ModuleDataStore<Payload>) -> AnyView?   // optional
}
```

Der `QueryBuilder` setzt die Fragmente aller aktiven Module zu **einer** Detail-Abfrage
zusammen. Ein neues Modul (z. B. „Releases“) ist damit eine neue Datei mit Fragment,
Payload und Views, ohne Änderungen am Sync-Kern.

Module, die zusätzlich REST brauchen (Activity, Actions), melden das über einen optionalen
Haken `func supplementaryRequests(for repo: RepoMeta, payload: Payload) -> [RESTRequest]`.
Die `SyncEngine` führt diese Anfragen gedrosselt und mit ETag aus und reicht die Antworten
an das Modul zurück. So muss der Sync-Kern auch für das Actions-Modul nicht wissen, was genau abgefragt wird.

Für Funktionen, die nicht zu einem einzelnen Repo gehören (Review-Anfragen, Benachrichtigungen),
gibt es später ein Schwester-Protokoll `GlobalInsightModule` mit eigener Abfrage.

### 9.3 Datenfluss

```
RefreshScheduler ──► SyncEngine ──► GitHubAPI ──► JSON
                         │
                         ▼
             Module dekodieren → RepoSnapshot { meta, payloads[ModuleID] }
                         │
                         ├──► SnapshotStore (auf Platte, atomar)
                         ├──► ChangeDetector → ChangeSet (neu / geschlossen / geändert)
                         ▼
               @Observable AppModel (MainActor) ──► SwiftUI-Views
```

Das `ChangeSet` ist der zentrale Erweiterungspunkt für **Benachrichtigungen**: Später hängt sich
ein `NotificationModule` daran, ohne Sync oder Module zu ändern.

### 9.4 Nebenläufigkeit

- Swift 6 mit strikter Nebenläufigkeitsprüfung.
- `GitHubAPI`, `SyncEngine` und die Stores sind `actor`s; die UI-Zustände liegen in `@MainActor @Observable`-Klassen.
- Abbrechen über `Task`-Cancellation (z. B. beim Abmelden oder bei einer neuen manuellen Aktualisierung).

### 9.5 Datenhaltung

- **v1:** `Codable`-Snapshot als JSON in `~/Library/Containers/<bundle-id>/Data/Library/Application Support/`, atomar geschrieben. Dazu der „Gesehen“-Zustand (Zeitpunkt des letzten Blicks pro Repo/Eintrag) und die Einstellungen (`@AppStorage` bzw. eigener Store).
- Zugriff nur über die Protokolle `SnapshotStore` und `SeenStateStore`. Wird später eine Historie gebraucht (Trends über Wochen), lässt sich SwiftData oder SQLite dahinter austauschen.

---

## 10. Technik

| Thema | Wahl | Begründung |
|---|---|---|
| Sprache / UI | Swift 6.4, SwiftUI, Observation (`@Observable`) | modern, nativ, wenig Code |
| Mindestversion | **macOS 26** | Liquid Glass, aktuelle SwiftUI-APIs; Entwicklungsrechner hat macOS 27.2 |
| Menüleiste | `NSStatusItem` + `NSPanel` (nicht aktivierend, `NSHostingView` mit SwiftUI), `LSUIElement = YES` | E6: volle Kontrolle über Öffnen/Schließen, Position und Größe; globaler Hotkey später ohne Umbau |
| Netzwerk | `URLSession` mit async/await | keine Abhängigkeit nötig |
| GraphQL | handgeschriebene Abfragen + `Codable` | Apollo wäre für ein paar Abfragen zu groß |
| Schlüsselbund | Security-Framework direkt | |
| Start bei Anmeldung | `SMAppService.mainApp` | |
| Logging | `os.Logger` mit Kategorien je Schicht | |
| Tests | Swift Testing, `URLProtocol`-Mocks, JSON-Fixtures | |
| Projekt | **XcodeGen** (`project.yml`, ist installiert) + lokales Swift Package mit allen Modulen | Projektdatei bleibt diff-freundlich; die App-Schicht bleibt dünn |
| Abhängigkeiten | **keine in v1** | später ggf. Sparkle (Updates), KeyboardShortcuts (Hotkey) |
| Lokalisierung | String Catalog, Deutsch + Englisch | |

---

## 11. Sicherheit und Datenschutz

- App Sandbox mit einzig `com.apple.security.network.client`; Hardened Runtime.
- Die App spricht ausschließlich mit `api.github.com` (bzw. später einem konfigurierten GHE-Host). Keine Telemetrie.
- Das Token wird nie geloggt und nie auf die Platte geschrieben, nur in den Schlüsselbund.
- Der lokale Cache enthält Titel privater Repos → liegt im Sandbox-Container. Beim Abmelden wird er gelöscht.

---

## 12. Entscheidungen (getroffen am 25.11.2026)

| # | Frage | Entscheidung | Folgen |
|---|---|---|---|
| E1 | Mindestversion | **macOS 26** | Liquid Glass und neueste SwiftUI-APIs ohne `#available`-Weichen |
| E2 | Anmeldung | **OAuth-App mit Device Flow, PAT als Alternative** | Einmalig eine OAuth-App im eigenen Account registrieren |
| E3 | Verteilung | **Direkt über GitHub Releases** (Developer ID + Notarisierung) | Für Phase 6 ist eine Mitgliedschaft im Apple Developer Program nötig. Später Homebrew-Cask und Sparkle |
| E4 | Repo-Landschaft | **ca. 50 Repos**, davon einige in **ca. 5 eigenen Organisationen** | Eine Bestandsseite (`first: 100`) und 1–2 Detail-Pakete pro Durchlauf reichen; der gestufte Takt ist eher Reserve. Die OAuth-App in den eigenen Organisationen selbst freigeben (Org-Einstellungen → *Third-party access*) |
| E5 | App-Name | **RepoWatch** | Bundle-ID `de.pmoscode.repowatch` |
| E6 | Menüleisten-Technik | **Gleich `NSStatusItem` + `NSPanel`** mit SwiftUI-Inhalt | Volle Kontrolle (per Code öffnen, Position, Größe, Hotkey später ohne Umbau), ca. 1–2 Tage mehr in Phase 0 |
| E7 | Wann wird das Symbol rot? | **Fehlschläge auf dem Standard-Branch und in PRs von Menschen (inkl. eigener)**. Bot-PRs (Renovate, Dependabot, …) lösen keinen Alarm aus | Der Alarm nutzt die Autor-Einteilung aus Abschnitt 6 |
| – | Renovate-Betrieb | **GitHub-App (Mend)** → Login `renovate[bot]` | Regel 1 in Abschnitt 6 greift ohne weitere Einstellungen |
