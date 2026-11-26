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

- [ ] `GraphQLClient` (actor): POST `/graphql`, Variablen, Dekodierung, **Teilfehler** (`errors` + `data` gleichzeitig) sauber abbilden
- [ ] `RESTClient` (actor): ETag-Cache (`If-None-Match` → 304), Pagination über `Link`-Header, Behandlung von `202 Accepted` bei `stats/*`
- [ ] `RateLimitTracker`: `remaining`/`resetAt` aus GraphQL und den `X-RateLimit-*`-Headern; Backoff bei 403/429 und `Retry-After`; maximal 2–3 Anfragen parallel
- [ ] Fehlertypen: `offline`, `unauthorized`, `rateLimited(resetAt)`, `server`, `decoding`
- [ ] `KeychainTokenStore`: speichern/lesen/löschen
- [ ] OAuth-App im eigenen GitHub-Account registrieren, Device Flow aktivieren (Client-ID in die Build-Konfiguration)
- [ ] OAuth-App in den ca. 5 eigenen Organisationen freigeben (falls dort OAuth-Beschränkungen aktiv sind) und prüfen, dass deren Repos vollständig erscheinen
- [ ] `DeviceFlowAuthenticator`: Code anfordern → Code + Link anzeigen → pollen (`interval`, `slow_down`, `expired_token` beachten)
- [ ] PAT-Eingabe als Alternative, Token mit `viewer { login }` prüfen
- [ ] Anmelde-Ansicht (erstes Öffnen) und Abmelden (löscht Token und Cache)
- [ ] Tests: `URLProtocol`-Mock, Fixtures, Device-Flow-Zustandsmaschine, Rate-Limit-Backoff

**Fertig, wenn:** Die Anmeldung per Device Flow klappt, das Token einen Neustart übersteht und alle Tests grün sind.

---

## Phase 2 – Domain, Modul-System und Sync · L

Das Herzstück. Hier entscheidet sich, ob die App später leicht erweiterbar bleibt.

- [ ] **Domain:** `RepoRef`, `RepoMeta`, `RepoSnapshot { meta, payloads: [ModuleID: AnyPayload], fetchedAt }`, `ChangeSet`, `ModuleSummary`
- [ ] **ModuleKit:**
  - [ ] `InsightModule`-Protokoll + Typlöschung `AnyInsightModule`
  - [ ] `ModuleRegistry` (Reihenfolge, an/aus aus den Einstellungen)
  - [ ] `QueryBuilder`: setzt die Fragmente aller aktiven Module zu einer `nodes(ids:)`-Abfrage zusammen; erkennt doppelte Feldnamen schon beim Registrieren
  - [ ] **Paketgröße nach Rechenzeit** (Konzept 4.3): Standard 10 Repos pro Detail-Anfrage, 2–3 parallel; bei HTTP 502/504 oder Timeout Paket halbieren und erneut versuchen; gemessene Dauer pro Paket loggen
  - [ ] Haken `supplementaryRequests` für REST-Folgeanfragen der Module (gedrosselt, mit ETag)
  - [ ] Test-Modul zum Prüfen der Mechanik
- [ ] **Sync:**
  - [ ] `SyncEngine` (actor): Bestand (seitenweise) → Repos in aktiv/ruhend einteilen → Details in Paketen von 10 IDs (siehe unten) → Snapshots zusammenführen
  - [ ] Filter anwenden (archiviert, Forks, Organisationen, Ausschluss-Muster), bevor Details geladen werden
  - [ ] `RefreshScheduler`: Takte pro Stufe (aktiv, ruhend, Bestand, Kurztakt bei laufenden Runs), Auslöser (Popover geöffnet, Aufwachen über `NSWorkspace.didWakeNotification`, Netzwerk über `NWPathMonitor`, manuell), Backoff
  - [ ] `ChangeDetector`: alter vs. neuer Snapshot → neu/geschlossen/geändert
  - [ ] Offen aus Phase 0: beobachten, ob `pushedAt`/`updatedAt` Änderungen an Issues/PRs zuverlässig anzeigen (sonst Einteilung aktiv/ruhend nur über die Detaildaten)
- [ ] **Persistence:** `SnapshotStore` (JSON, atomar schreiben, Versionsfeld für spätere Migrationen), `SeenStateStore`
- [ ] **AppModel** (`@MainActor @Observable`): lädt beim Start den Cache (sofort sichtbar) und startet dann den Scheduler
- [ ] Tests: QueryBuilder (Ausgabe-Snapshot), SyncEngine mit Fixtures, ChangeDetector, Laden/Speichern des Cache

**Fertig, wenn:** Ein Sync-Durchlauf im Test (oder über eine Debug-Schaltfläche) Snapshots für alle Repos erzeugt und der zweite Start die Daten offline sofort anzeigt.

---

## Phase 3 – Die vier Module · M/L

- [ ] **IssuesModule**
  - [ ] Fragment: `issues(states: OPEN, first: 20, orderBy: UPDATED_AT)` mit Titel, URL, Labels, Autor, Zeitstempeln
  - [ ] Payload: `totalCount`, `items: [IssueSummary]`, `hasMore`
  - [ ] Nachladen weiterer Seiten in der Detailansicht (eigene Abfrage pro Repo)
- [ ] **PullRequestsModule**
  - [ ] Fragment: offene PRs mit `isDraft`, `headRefName`, `author { __typename login }`, `statusCheckRollup` des letzten Commits
  - [ ] `AuthorClassifier` mit Regelkette (Konzept, Abschnitt 6), Regeln aus den Einstellungen
  - [ ] Zusammenfassung: Anzahl pro `PRAuthorKind`
  - [ ] Tests: Tabelle mit Fällen (renovate[bot], selbst betriebenes Renovate als `User`, dependabot, github-actions, ich, Mensch)
- [ ] **ActivityModule**
  - [ ] Fragment: `history(since: 7d/30d) { totalCount }`, dazu zuletzt geänderte Issues/PRs (inkl. geschlossener) mit `createdAt`/`closedAt`/`mergedAt` für die Zählung über 7 Tage
  - [ ] Wert und Stufe berechnen (Gewichte konfigurierbar, Schwellen über Quantile)
  - [ ] Detail: Sparkline aus `stats/participation`, Ereignis-Feed aus `events` (REST mit ETag, nur auf Anforderung)
  - [ ] Tests: Wertberechnung, Quantil-Stufen, Zuordnung der Ereignistypen
- [ ] **ActionsModule** (Konzept, Abschnitt 8)
  - [ ] Fragment: `statusCheckRollup` + `checkSuites { workflowRun }` des Standard-Branches, `object(expression: "HEAD:.github/workflows")`
  - [ ] REST-Folgeanfrage `actions/runs?per_page=30` nur für aktive Repos mit Workflows
  - [ ] `RunOutcome`-Zuordnung aller `status`/`conclusion`-Werte, `WorkflowRunSummary`
  - [ ] Ableitungen: aktueller Zustand pro Workflow+Branch (letzter Versuch zählt), „rot seit“ + Fehlschläge in Folge, Erfolgsquote, Dauer
  - [ ] Signal „Run läuft“ an den Scheduler (Kurztakt)
  - [ ] `ChangeDetector`-Erweiterung: `workflowFailed`, `workflowRecovered`
  - [ ] Verknüpfung Run → PR → `PRAuthorKind`, um Bot-Runs ausblenden zu können
  - [ ] Tests: Zuordnungstabelle, Streak-Berechnung (inkl. Re-Runs und abgebrochener Runs), Repo ohne Workflows, Actions deaktiviert (404)

**Fertig, wenn:** Alle vier Module Daten liefern, Zusammenfassungen erzeugen und vollständig getestet sind (noch ohne fertige UI).

---

## Phase 4 – Oberfläche · L

- [ ] **DesignSystem:** `CountBadge`, `Chip` (Label-Farben von GitHub), `AuthorKindIcon`, `ActivityIndicator`, `RunStatusIcon` (✓/✗/läuft mit Animation/abgebrochen), `Sparkline`, `RelativeTimeText`, `RepoRow`, Zustände für Laden/Leer/Fehler
- [ ] **Menüleisten-Symbol:** Anzeige-Modi (nichts, Punkt, Zähler), roter Punkt bei Fehlschlag auf dem Standard-Branch oder in einem Menschen-PR (E7), Fehlerzustand
- [ ] **Popover:**
  - [ ] Kopfbereich: Konto, Suche, Aktualisieren, Einstellungen
  - [ ] Reiter: Übersicht · Issues · PRs · Actions · Aktivität (Reiter kommen aus der Modul-Registry)
  - [ ] Übersicht: Favoriten, Sortierung (Aktivität, Name, letzter Push, offene Einträge), Markierung für Neues
  - [ ] Issues-Reiter: über alle Repos, Filter nach Repo und Label
  - [ ] PRs-Reiter: Gruppen nach Autor-Art, Bot-Gruppen eingeklappt
  - [ ] Actions-Reiter: Fehlgeschlagen · Läuft gerade · Zuletzt erfolgreich; Filter Branch/Auslöser/Bot-Runs
  - [ ] CI-Status in der Repo-Zeile der Übersicht
  - [ ] Aktivitäts-Reiter: Feed
  - [ ] Fußzeile: zuletzt aktualisiert, API-Kontingent
- [ ] **Detailansicht** per `NavigationStack` im Popover, ein Abschnitt pro Modul
- [ ] Interaktion: Öffnen im Browser (`NSWorkspace.shared.open`), Kontextmenü (Link kopieren, als gesehen markieren, Favorit), Tastatur (⌘F, ⌘R, ⌘,, Pfeiltasten, ↩)
- [ ] **Einstellungsfenster** (`Settings`-Szene) mit den Reitern aus dem Konzept (3.3)
- [ ] SwiftUI-Previews für alle Ansichten mit Beispieldaten (Fixtures)

**Fertig, wenn:** Alle vier Anforderungen (Issues, PRs mit Autor-Art, Aktivität, Actions-Runs) im Popover von Anfang bis Ende funktionieren, mit echten Daten.

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
| Schwere Detail-Abfragen → Zeitlimit (HTTP 502) | Daten fehlen ganz | **im Spike eingetreten** ab 25 Repos pro Anfrage → Pakete à 10, bei 502 halbieren |
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
