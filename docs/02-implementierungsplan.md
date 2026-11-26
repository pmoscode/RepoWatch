# Implementierungsplan: RepoWatch

> Grundlage: [01-konzept.md](01-konzept.md) · Stand: 25.11.2026
> Umfang je Phase: **S** ≈ 1–2 Tage · **M** ≈ 3–5 Tage · **L** ≈ 1–2 Wochen (Feierabend-Tempo eher ×2)

---

## Projektstruktur (Ziel)

```
github-watch/
├── project.yml                        # XcodeGen-Definition
├── App/
│   ├── RepoWatchApp.swift             # @main + NSApplicationDelegateAdaptor, Settings-Szene
│   ├── StatusItemController.swift     # NSStatusItem: Symbol, Badge, Klick
│   ├── PanelController.swift          # NSPanel unter dem Symbol, NSHostingView, Schließen bei Klick daneben/Esc
│   ├── AppComposition.swift           # Composition Root, Modul-Registry
│   ├── Info.plist                     # LSUIElement = YES
│   ├── RepoWatch.entitlements         # Sandbox + network.client
│   └── Assets.xcassets / Localizable.xcstrings
├── Packages/RepoWatchKit/
│   ├── Package.swift
│   ├── Sources/
│   │   ├── Domain/                    # reine Modelle, keine Frameworks
│   │   ├── GitHubAPI/                 # GraphQLClient, RESTClient, RateLimitTracker
│   │   ├── Auth/                      # DeviceFlow, PAT, KeychainTokenStore
│   │   ├── Persistence/               # SnapshotStore, SeenStateStore
│   │   ├── ModuleKit/                 # InsightModule, AnyInsightModule, QueryBuilder
│   │   ├── Sync/                      # SyncEngine, RefreshScheduler, ChangeDetector
│   │   ├── DesignSystem/              # Chip, CountBadge, RepoRow, Sparkline, …
│   │   ├── IssuesModule/
│   │   ├── PullRequestsModule/
│   │   ├── ActivityModule/
│   │   ├── ActionsModule/
│   │   └── Features/                  # Popover, Tabs, RepoDetail, Settings
│   └── Tests/
│       ├── Fixtures/                  # echte (anonymisierte) GraphQL-/REST-Antworten
│       ├── DomainTests/ GitHubAPITests/ SyncTests/ ModuleTests/
├── docs/
└── .github/workflows/ci.yml
```

Jeder Ordner unter `Sources/` ist ein eigenes SPM-Target. Dadurch erzwingt der Compiler die
Abhängigkeitsrichtung aus dem Konzept (9.1).

---

## Phase 0 – Grundgerüst und Spike · S

Ziel: Ungewissheiten früh klären, bevor Architektur-Code entsteht.

- [x] Git-Repo anlegen, `.gitignore` (Xcode, DerivedData, `*.xcodeproj` wird generiert)
- [x] `project.yml` + App-Target (macOS 26, `LSUIElement`, Sandbox, Bundle-ID `de.pmoscode.repowatch`)
- [x] Leeres Package `RepoWatchKit` mit den Targets aus der Struktur
- [x] `StatusItemController` (`NSStatusItem` mit Template-Symbol) + `PanelController` (`NSPanel`, nicht aktivierend, unter dem Symbol positioniert, schließt bei Klick daneben oder Esc, per Code öffnen/schließen) mit Platzhalter-Inhalt in SwiftUI
- [x] Panel-Größe und -Position geprüft (400 × 560 unter dem Symbol, per `--show-panel --snapshot` im Debug-Build)
- [x] **Von Hand geprüft (26.11.2026):** Klick auf das Symbol öffnet/schließt, Klick daneben und Esc schließen, Rechtsklick-Menü, Liquid Glass, mehrere Bildschirme, Vollbild-Apps
- [x] Spike: Token aus `GITHUB_TOKEN` (nur Debug) → Inventory-Abfrage → Anzahl Repos im Panel
- [x] **Messen und im Konzept nachtragen** (Konzept 4.3):
  - [x] Anzahl erreichbarer Repos, Kosten pro Bestand- und Detailseite → Detail-Abfrage scheitert ab 25 Repos am Zeitlimit
  - [x] `author.__typename` bei Renovate/Dependabot ist `Bot`, Logins ohne `[bot]`
  - [ ] Taugen `pushedAt`/`updatedAt` als Signal für aktiv/ruhend? → braucht Beobachtung über Zeit, verschoben nach Phase 2
  - [x] Actions: `checkSuites { workflowRun }` und `statusCheckRollup` liefern den Stand; 39/70 Repos mit Workflows; `304` bestätigt
- [x] Fixtures aus den echten Antworten speichern, anonymisiert (`Tests/SyncTests/Fixtures`)

**Fertig, wenn:** Das Symbol in der Menüleiste zeigt die Anzahl der Repos, das Panel öffnet und schließt sich sauber, und die Messwerte stehen im Konzept.

---

## Phase 1 – GitHub-Zugriff und Anmeldung · M

- [x] `HTTPTransport` (actor): gemeinsame Schicht für GraphQL und REST mit Token, höchstens 3 parallelen Anfragen, Wiederholung bei 500/503/504 und Netzwerk-Abbrüchen (exponentiell), **502 bewusst ohne Wiederholung** (Signal für zu schwere Abfrage, Konzept 4.3)
- [x] `GraphQLClient`: POST `/graphql`, Variablen, Dekodierung, **Teilfehler** (`errors` + `data` gleichzeitig), `viewerLogin()`
- [x] `RESTClient` (actor): ETag-Cache (`If-None-Match` → 304, begrenzt auf 500 Einträge), `Link`-Header (`nextPage`), `202 Accepted` → `.pending`; eigene URLSession ohne `URLCache`, damit 304 überhaupt ankommt
- [x] Rate-Limit: `x-ratelimit-*` je Ressource merken; primäres Limit → `.rateLimited(resetAt)` und keine weiteren Anfragen bis zum Reset; sekundäres Limit → `Retry-After` abwarten
- [x] Fehlertypen: `offline`, `unauthorized`, `rateLimited(resetAt)`, `server`, `http`, `decoding`, `pending`
- [x] `KeychainTokenStore`: speichern/lesen/löschen (Generic Password, nicht synchronisiert); `TokenVault` hält das Token im Speicher
- [x] **OAuth-App registrieren** (siehe Anleitung unten) und Client-ID in `project.yml` eintragen
- [x] OAuth-App in den ca. 5 eigenen Organisationen freigeben (falls dort OAuth-Beschränkungen aktiv sind) und prüfen, dass deren Repos vollständig erscheinen
- [x] `DeviceFlowAuthenticator`: Code anfordern → Code + Link anzeigen → pollen (`interval`, `slow_down`, `expired_token`, `access_denied`)
- [x] PAT-Eingabe als Alternative, Token mit `viewer { login }` prüfen
- [x] Anmelde-Ansicht (erstes Öffnen), Konto-Menü mit Abmelden (löscht Token); bei HTTP 401 automatisch abmelden mit Hinweis
- [x] Tests: `URLProtocol`-Mock (`TestSupport`), Device-Flow-Ablauf, Rate-Limit und Backoff, Drosselung, ETag, Schlüsselbund (32 Tests)
- [x] **Von Hand geprüft (26.11.2026):** Anmeldung per PAT, per Device Flow, Neustart ohne erneute Anmeldung, Abmelden

`GITHUB_TOKEN` funktioniert weiterhin, aber nur in Debug-Builds und mit Vorrang vor dem Schlüsselbund.

### Anleitung: OAuth-App registrieren

1. <https://github.com/settings/applications/new> öffnen (Settings → Developer settings → OAuth Apps → *New OAuth App*).
2. *Application name:* `RepoWatch` · *Homepage URL:* `https://github.com/pmoscode/RepoWatch` · *Authorization callback URL:* ebenfalls `https://github.com/pmoscode/RepoWatch` (wird beim Device Flow nicht benutzt, ist aber Pflicht).
3. **„Enable Device Flow“ anhaken** und registrieren.
4. Die angezeigte **Client ID** in `project.yml` bei `GITHUB_OAUTH_CLIENT_ID` eintragen. Ein Client Secret wird **nicht** gebraucht und gehört nicht ins Repo.
5. `xcodegen generate` und neu bauen. Danach ist „Mit GitHub anmelden“ aktiv.
6. Für Organisationen mit OAuth-Beschränkung: Org-Einstellungen → *Third-party access* → RepoWatch freigeben (oder beim ersten Anmelden auf der GitHub-Seite „Grant“ bzw. „Request“ wählen).

**Fertig, wenn:** Die Anmeldung per Device Flow klappt, das Token einen Neustart übersteht und alle Tests grün sind.

---

## Phase 2 – Domain, Modul-System und Sync · L

Das Herzstück. Hier entscheidet sich, ob die App später leicht erweiterbar bleibt.

- [x] **Domain:** `RepoMeta`, `RepoSnapshot { meta, payloads: [ModuleID: AnyPayload], summaries, detailsFetchedAt, lastDetailError }`, `SyncState`, `Change`/`ChangeSet`, `ModuleSummary` (Zähler, `needsAttention`, `wantsFrequentRefresh`), `ModulePayload`
- [x] **ModuleKit:**
  - [x] `InsightModule`-Protokoll (Fragment, Dekodieren, Zusammenfassung, Folgeanfragen, Änderungen) + Typlöschung `AnyInsightModule`. Die **Darstellung** kommt in Phase 4 als eigenes Protokoll, damit ModuleKit ohne SwiftUI testbar bleibt
  - [x] `ModuleRegistry` (Reihenfolge, an/aus); prüft beim Registrieren: Präfix `m_<id>_` für jedes Feld der obersten Ebene, keine doppelten Felder oder Module, keine Inline-Fragmente oben
  - [x] `QueryBuilder`: setzt die Fragmente aller aktiven Module zu einer `nodes(ids:)`-Abfrage zusammen, deklariert nur die benötigten Variablen (`since7d`, `since30d`, `updatedSince7d`)
  - [x] **Paketgröße nach Rechenzeit** (Konzept 4.3): 10 Repos pro Detail-Anfrage, 3 Pakete parallel; bei HTTP 502/504 Paket halbieren und erneut versuchen; Dauer und Kosten pro Paket im Log
  - [x] `supplementaryRequests` + `merge(…, previous:)` für REST-Folgeanfragen der Module (gedrosselt über den Transport, mit ETag); fehlgeschlagene Folgeanfragen können den alten Stand behalten
  - [x] Test-Modul `CountModule` (in `TestSupport`)
- [x] **Sync:**
  - [x] `SyncEngine` (actor): Bestand → Filter → Details in Paketen → Folgeanfragen → Änderungen → speichern. Fehler einzelner Repos/Pakete brechen nicht ab, diese Repos behalten ihren Stand; 401/offline/Rate-Limit brechen ab, ohne den Stand zu verändern
  - [x] `SyncFilter` (archiviert, Forks, Owner, Glob-Muster), angewendet vor den Details
  - [x] `RefreshPlanner` (reine Logik): Stufen Kurztakt/aktiv/ruhend, Fälligkeiten, Bestand alle 30 Min., Auslöser `launch`/`manual` = alles, `panelOpened` = aktive Repos mit Daten > 1 Min., `wake` = Fälliges mit früherem Bestand
  - [x] `RefreshScheduler` (actor): schläft bis zur nächsten Fälligkeit (max. 60 s), wacht bei Auslösern sofort auf, Backoff 30 s → 15 Min., bei Rate-Limit bis zum Reset; meldet `started`/`finished`/`failed` als `AsyncStream`
  - [x] Auslöser in der App: Panel öffnen, Aufwachen (`NSWorkspace.didWakeNotification`), Netzwerk wieder da (`NWPathMonitor`), ⌘R
  - [x] `ChangeDetector`: neue/entfernte Repos, Push, Modul-Änderungen; beim ersten Durchlauf keine Meldungen
  - [ ] Offen aus Phase 0: ob `pushedAt`/`updatedAt` Änderungen an Issues/PRs zuverlässig anzeigen. **Die Beobachtung läuft jetzt** (Log-Zeile „Aktivitäts-Signal: n mit, m ohne Änderung“); auswerten, sobald die echten Module aus Phase 3 Daten liefern
- [x] **Persistence:** `JSONFileSnapshotStore` (Versionsfeld, atomar, Zeitpunkte verlustfrei), `JSONFileSeenStateStore` („neu seit dem letzten Öffnen“); beides im Sandbox-Container, beim Abmelden gelöscht
- [x] **AppModel:** zeigt beim Start sofort den Cache, startet dann den Scheduler; Fehler lassen die alten Daten sichtbar („Stand von …“, nächster Versuch im Tooltip)
- [x] Tests: Registry und QueryBuilder (Ausgabe-Snapshot), RepoSnapshot-Kodierung, SyncEngine gegen GitHub-Simulator (Filter, Pakete, 502-Halbierung, nicht abrufbare Repos, Änderungen, ETag, Cache, 401, Abmelden), Planer, Scheduler, Speicher (insgesamt 63 Tests)

**Fertig, wenn:** Ein Sync-Durchlauf im Test (oder über eine Debug-Schaltfläche) Snapshots für alle Repos erzeugt und der zweite Start die Daten offline sofort anzeigt. → erfüllt: Test `restoresFromStore`, in der App „Cache geladen: 70 Repos“ vor dem ersten Netzzugriff.

---

## Phase 3 – Die vier Module · M/L

- [x] **Autor-Einteilung** (Konzept 6) als Regelkette in `Domain` (`AuthorClassifier`, `AuthorRules`), weil PR- **und** Actions-Modul sie brauchen; GraphQL- und REST-Schreibweise der Bot-Logins
- [x] **IssuesModule**
  - [x] Fragment: `issues(states: OPEN, first: 20, orderBy: UPDATED_AT)` mit Titel, URL, Labels, Autor, Kommentaranzahl, Zeitstempeln, Cursor
  - [x] Payload: `totalCount`, `items`, `hasMore`, `endCursor`
  - [x] `IssuesModule.fetchPage(…)` zum Nachladen in der Detailansicht (wird in Phase 4 angebunden)
  - [x] Änderungen über `ItemDiff`: neu (Nummer größer als alle bisherigen), geändert, geschlossen (nur wenn nicht bloß aus dem Fenster verdrängt)
- [x] **PullRequestsModule**
  - [x] Fragment: offene PRs (30) mit `isDraft`, `headRefName`, `author { __typename login }`, `statusCheckRollup` des letzten Commits
  - [x] Zusammenfassung: Anzahl je Autor-Art, rote Checks gesamt und bei Menschen; **Alarm nur bei Menschen-PRs** (E7)
  - [x] Tests: Tabelle mit allen Fällen der Regelkette (inkl. selbst betriebenes Renovate, `[bot]`-Suffix, ich, Mensch)
- [x] **ActivityModule**
  - [x] Fragment: `history(since: 7d/30d)`, `pushedAt`, Issues seit 7 Tagen, letzte 30 PRs → Zählung über 7 Tage
  - [x] Wert nach Konzept 7 (Gewichte in `ActivityWeights`), Stufen über Drittel der aktiven Repos (`ActivityRanking`)
  - [x] `fetchWeeklyCommits` (`stats/participation`, 202 → `.pending`) und `fetchEvents` (Events-API, ETag) für die Detailansicht
- [x] **ActionsModule** (Konzept 8)
  - [x] Fragment: `statusCheckRollup` + `checkSuites { workflowRun }` des Standard-Branches (nur `github-actions`), `.github/workflows`
  - [x] REST `actions/runs?per_page=30` nur für Repos mit Workflows **und** (Push in den letzten 7 Tagen **oder** Standard-Branch rot/ausstehend **oder** laufender Run); sonst bleiben die letzten Runs erhalten
  - [x] `RunOutcome` für alle `status`/`conclusion`-Werte (REST und GraphQL), `WorkflowRunSummary`
  - [x] `WorkflowAnalysis`: Zustand je Workflow+Branch, „rot seit“, Fehlschläge in Folge (Abbrüche zählen nicht), Erfolgsquote, Dauer
  - [x] Laufender Run → `wantsFrequentRefresh` → Kurztakt
  - [x] Änderungen `workflowFailed` / `workflowRecovered`
  - [x] Alarm (E7): Standard-Branch rot oder roter Workflow in einem PR-Lauf eines Menschen (Actor + Branch über die Regelkette)
- [x] Module in der App registriert (`ModuleRegistry.standard()`); die Engine ruft `merge` jetzt für jedes Modul auf, damit Daten aus dem letzten Durchlauf übernommen werden können
- [x] Tests: 8 anonymisierte **echte** Repo-Knoten (alle Module lesen alle Knoten), leeres Repo, Regelkette, `ItemDiff`, Wert/Stufen, Events, Nachladen, Status-Zuordnung, Serien, Alarm, REST-Merge, Änderungen (insgesamt 86 Tests)
- [x] **Echter Lauf** (26.11.2026): 70 Repos in 7 Paketen à 10, langsamstes Paket 5,2 s, 43 Punkte, 18 REST-Abfragen, 0 Fehler, ganzer Durchlauf 24 s. Ergebnis deckt sich mit dem Spike (43 Issues, 107 PRs, davon 98 Renovate, 6 Dependabot, 3 von Menschen; 17 rote PR-Checks, alle in Bot-PRs; 39 Repos mit Workflows)
- [ ] Offen aus Phase 0: Signal `pushedAt`/`updatedAt` auswerten – jetzt mit echten Änderungen im Log („Aktivitäts-Signal“), nach ein paar Tagen Laufzeit

Unterwegs gefunden und behoben: Im `RefreshScheduler` konnte ein Auslöser (z. B. ⌘R) verloren gehen, wenn er während einer Wartestelle ohne fälligen Plan kam; außerdem drehte die Schleife bei Backoff mit wartendem Auslöser leer. Auslöser werden jetzt vor jedem `await` übernommen und während eines Backoffs aufgehoben.

**Fertig, wenn:** Alle vier Module Daten liefern, Zusammenfassungen erzeugen und vollständig getestet sind (noch ohne fertige UI). → erfüllt.

---

## Phase 4 – Oberfläche · L

- [x] **Darstellung als Teil der Module:** neues Target `ModuleUIKit` mit dem Protokoll `ModuleUI` (Symbol in der Repo-Zeile, Zusatzinfo, Detail-Abschnitt, eigener Reiter, „neu seit …“) und dem `ModuleUIContext` (Stand, Einstellungen, Suche, Aktionen, Dienste für Nachladen). Das Panel setzt nur noch zusammen; ein neues Modul bringt seine Oberfläche selbst mit
- [x] **DesignSystem:** `CountBadge`, `LabelChip` (GitHub-Farben), `AuthorKindIcon`, `ActivityIndicator`, `StatusIcon` (✓/✗/läuft mit Animation/abgebrochen), `Sparkline`, `RelativeTimeText` (bricht nie um), `NewDot`, `TagText`, `SectionTitle`, `EmptyStateView`
- [x] **Menüleisten-Symbol:** Anzeige-Modi (nur Symbol, Punkt bei Neuem, offene PRs von Menschen, Summe), roter Punkt bei Alarm (E7, abschaltbar), Tooltip mit Grund; Rechtsklick-Menü mit „Einstellungen …“
- [x] **Popover:**
  - [x] Kopfbereich: Konto-Menü (Abmelden), Suche (⌘F, Esc schließt), Aktualisieren (⌘R), Einstellungen (⌘,)
  - [x] Reiter aus der Modul-Registry: Übersicht · Issues · PRs · Aktivität · Actions; nur der gewählte Reiter zeigt seinen Titel, die anderen Symbol + Zahl (rot bei Alarm)
  - [x] Übersicht: Favoriten oben, Sortierung (Aktivität, Name, letzter Push, offene Einträge), Markierung für Neues, Kontextmenü (öffnen, Link kopieren, als gesehen markieren, Favorit), Pfeiltasten + ↩
  - [x] Issues-Reiter: über alle Repos, Filter nach Repo und Label, **Bot-Issues ausblenden** (Standard an; im Test 43 → 5, der Rest waren Renovates „Dependency Dashboards“)
  - [x] PRs-Reiter: Gruppen nach Autor-Art, Bot-Gruppen eingeklappt („98 in 28 Repos“, rote Checks je Gruppe)
  - [x] Actions-Reiter: Fehlgeschlagen (erst Standard-Branch, dann Menschen-PRs, dann Bots) · Läuft gerade · Zuletzt erfolgreich (eingeklappt); Filter alle Branches / Bot-PRs
  - [x] Aktivitäts-Reiter: Feed der 15 aktivsten Repos aus der Events-API (ETag); Links werden aus Repo und Nummer gebaut, weil GitHub die Payloads gekürzt hat
  - [x] CI-Status, Aktivitätsstufe, Commits/7T und „rot seit …“ in der Repo-Zeile der Übersicht
  - [x] Fußzeile: zuletzt aktualisiert bzw. „Stand von …“ bei Fehlern, API-Kontingent
- [x] **Detailansicht** (eigene Navigation im Panel, ⌘[ bzw. ⌘← zurück): Kopf mit Favorit und „Auf GitHub“, je Modul ein Abschnitt (Issues mit „Weitere laden“, PRs, Aktivität mit Kennzahlen, Wochen-Sparkline und Ereignissen, Actions mit Workflow-Zuständen und letzten Runs); markiert das Repo als gesehen
- [x] **Einstellungsfenster** (eigenes `NSWindow`, weil das `Settings`-Szenen-Fenster aus einer App ohne Dock-Icon nicht zuverlässig nach vorn kommt) mit Konto, Repositories, Pull Requests, Actions, Aktualisierung, Module, Allgemein; Einstellungen werden in den `UserDefaults` gespeichert und wirken sofort (Filter, Regeln und Module lösen einen Sync aus)
- [x] Debug-Startparameter für Screenshots: `--show-panel`, `--tab <id>`, `--repo <name>`, `--show-settings`, `--snapshot <name>`, `--no-glass`
- [ ] SwiftUI-Previews mit Beispieldaten (noch nicht angelegt; die Ansichten wurden per Snapshot mit echten Daten geprüft)
- [ ] **Von Hand prüfen:** Farben und Lesbarkeit auf der echten Glas-Ebene (Snapshots zeigen die Glas-Ebene nicht; ohne sie stimmen Farben und Kontraste), Tastaturbedienung, Kontextmenüs, Einstellungsfenster

**Fertig, wenn:** Alle vier Anforderungen (Issues, PRs mit Autor-Art, Aktivität, Actions-Runs) im Popover von Anfang bis Ende funktionieren, mit echten Daten. → erfüllt, bis auf die Prüfung von Hand.

---

## Phase 5 – Feinschliff · M

- [ ] Start bei Anmeldung (`SMAppService.mainApp`)
- [ ] Lokalisierung Deutsch/Englisch (String Catalog)
- [ ] Barrierefreiheit: VoiceOver-Beschriftungen, Dynamic Type soweit unter macOS möglich, Kontraste
- [ ] Hell/Dunkel, Liquid Glass prüfen
- [ ] Performance mit 300+ Repos (ggf. künstliche Fixtures): flüssiges Scrollen, Speicherbedarf, Abfragekosten
- [ ] Netzwerk- und Fehlerfälle: offline, Token widerrufen, Rate-Limit erreicht, Organisation blockiert die OAuth-App (Hinweis + Link zur Freigabe)
- [ ] Logging über `os.Logger` aufräumen (keine Tokens, keine privaten Titel auf Stufe `public`)

---

## Phase 6 – Auslieferung · S

- [ ] GitHub Actions: Build + Tests auf einem macOS-Runner bei jedem Push/PR (`xcodegen generate` → `xcodebuild test`)
- [ ] Voraussetzung: Mitgliedschaft im Apple Developer Program, Zertifikat „Developer ID Application“, App-spezifisches Passwort bzw. API-Key für `notarytool` als CI-Secret
- [ ] Signieren mit Developer ID, Notarisierung (`notarytool`), DMG oder ZIP
- [ ] Release-Workflow bei Tags → Artefakt an das GitHub Release
- [ ] README mit Screenshots, Anleitung zur Anmeldung, Datenschutz-Hinweis

---

## Nach v1: Backlog (jeweils als Modul)

| Modul / Funktion | Art | Baut auf |
|---|---|---|
| Benachrichtigungen bei neuen PRs/Issues und bei `workflowFailed`/`workflowRecovered` | Abnehmer des `ChangeSet` | ChangeDetector |
| Einzelne Checks eines PRs aufklappen (welcher Job ist rot) | Erweiterung von `PullRequestsModule` | ActionsModule |
| Fehlgeschlagene Runs neu starten / Logs-Ausschnitt anzeigen | Aktion im `ActionsModule` (Schreibrecht nötig) | ActionsModule |
| Review-Status / Review-Anfragen an mich | `GlobalInsightModule` (Suche `review-requested:@me`) | ModuleKit |
| Renovate-Sammelansicht (alle Dependency-PRs, gruppiert nach Paket) | eigener Reiter | Klassifizierung |
| Releases & Tags | `InsightModule` | |
| Desktop-Widget (WidgetKit) | liest den SnapshotStore über eine App Group | Persistence |
| Globaler Hotkey | Panel per Code öffnen (bereits möglich) | `PanelController` |
| Mehrere Accounts / GitHub Enterprise | `AccountContext` pro Client | GitHubAPI |
| Automatische Updates (Sparkle) | Infrastruktur | Phase 6 |
| Trends über Wochen | Historie im Store (SwiftData/SQLite) | Persistence-Protokolle |

---

## Risiken

| Risiko | Auswirkung | Gegenmaßnahme |
|---|---|---|
| Sehr viele Repos → Rate-Limit | veraltete Daten | gestufter Takt, Bündelung, ETag (Spike: ca. 35 Punkte pro Durchlauf, unkritisch) |
| Schwere Detail-Abfragen → Zeitlimit (HTTP 502) | Daten fehlen ganz | **im Spike eingetreten** ab 25 Repos pro Anfrage → Pakete à 10, bei 502 halbieren. Mit allen vier Modulen bis 6 s pro Paket (Limit ca. 10 s); bei mehr Modulen Paketgröße senken |
| Organisationen blockieren OAuth-Apps | Repos fehlen ohne erkennbaren Grund | erkennen (fehlende Repos/Fehlermeldung), Hinweis + PAT als Alternative |
| Events-API verzögert | Feed hinkt hinterher | Zählung über GraphQL, Feed nur ergänzend |
| Eigenes `NSPanel` verhält sich anders als ein System-Popover | Fokus, Schließen, Spaces oder Vollbild fühlen sich falsch an | Verhalten früh in Phase 0 prüfen (eigene Aufgabe), `collectionBehavior` und `level` bewusst setzen |
| Modul-Fragmente kollidieren | kaputte Abfrage | Präfix-Konvention + Prüfung beim Registrieren + Test |
| Viele Repos mit aktiven Workflows → viele REST-Anfragen | REST-Kontingent knapp | REST nur für aktive Repos, ETag, GraphQL-Status für alle übrigen |
| Geplante Workflows (`schedule`) schlagen still in ruhenden Repos fehl | rot, ohne dass es auffällt | GraphQL-Status des Standard-Branches deckt alle Repos ab; Auslöser `schedule` ist filterbar |

---

## Empfohlene Reihenfolge

Phase 0 → 1 → 2 → 3 → 4 → 5 → 6. Phase 3 und 4 lassen sich nach Phase 2 verzahnen:
Pro Modul erst Daten und Tests, dann sofort die zugehörige UI. So ist nach dem
IssuesModule bereits eine benutzbare erste Version da.
