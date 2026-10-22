# bilge – Roadmap

> Status: Entwurf v0.1 · Stand: 2026-10-22
> Grundlage: [SPEC.md](SPEC.md) und [ARCHITECTURE.md](ARCHITECTURE.md).

## Arbeitsweise

- Jede Phase endet in einem **lauffähigen, getesteten Zustand** auf `main`.
- Jeder Arbeitspaket-Punkt ist so geschnitten, dass er in **einer Claude-Code-Session** umsetzbar ist: erst planen (Plan Mode), dann Tests, dann Implementierung, dann Commit.
- „Fertig wenn“ ist die Abnahme. Ein Punkt ohne Tests ist nicht fertig.
- Erkenntnisse, die SPEC oder ARCHITECTURE verändern, werden **dort** nachgetragen, nicht nur im Code.

## Übersicht

| Phase | Ziel | Ergebnis |
|---|---|---|
| 0 | Fundament & Spike | Annahmen auf dem Pi geprüft, Repo-Gerüst mit CI |
| 1 | Scan-Pipeline (headless) | `bilge run-once` scannt alle Images und speichert in SQLite |
| 2 | Scheduler & API | Täglicher Lauf, JSON-API, manuelles Auslösen |
| 3 | Dashboard | Übersicht, Detail, Läufe im Browser |
| 4 | Filter & Ignores | High/Critical, fixbar, Ignore-Regeln |
| 5 | Discord | Meldung neuer High/Critical-Findings pro Lauf |
| 6 | Packaging & Release | Multi-Arch-Image auf GHCR, Compose-Beispiel, README → **v1.0** |
| später | Optimierungen | weitere Notifier, Metriken … |

---

## Phase 0 – Fundament & Spike

**Ziel:** Die riskantesten Annahmen prüfen, bevor Code entsteht, und ein Gerüst schaffen, in dem Claude Code von Anfang an bauen, testen und linten kann.

### 0.1 Spike: Trivy über den Socket-Proxy

Werkzeug und Anleitung: [`spike/README.md`](../spike/README.md). Ergebnisse: [`spike-results.md`](spike-results.md).

- [x] Auf dem Pi: `docker-socket-proxy` mit `IMAGES=1`, `POST=0` im internen Netz, daneben ein Container mit `trivy`.
- [x] `trivy image --image-src docker` gegen ein Image per Tag **und** per Image-ID testen.
- [x] Proxy-Logs prüfen: Welche Endpunkte ruft Trivy auf? Werden welche verweigert?
- [x] Verhalten mit `--skip-java-db-update` ohne vorhandene Java-DB. (Scan bricht ab; Entscheidung zu `BILGE_JAVA_DB` offen.)
- [x] Messen für 4 typische Images (Alpine, Debian, Node, Java): RAM-Spitze, Dauer, Größe des Caches; zweiter Scan desselben Images zum Vergleich.
- [x] Echte Trivy-JSON-Reports als Fixtures sichern. (lokal in `spike/pi-results/`, Auswahl in spike-results.md)

**Fertig wenn:** Offene Punkte aus SPEC §10 beantwortet und in SPEC/ARCHITECTURE nachgetragen sind; Messwerte stehen in `docs/spike-results.md`.

### 0.2 Repo-Gerüst
- [ ] `go mod init github.com/michaelmrt/bilge`, Verzeichnisstruktur laut ARCHITECTURE §3.
- [ ] `web/` mit Vite + React + TypeScript, Platzhalter `web/dist/index.html`, `web/embed.go`.
- [ ] `Makefile` mit `build`, `test`, `lint`, `dev`, `web`, `docker`.
- [ ] `golangci-lint`-Konfiguration, `gofmt`, ESLint/Prettier für `web/`.
- [ ] GitHub Actions: Go-Tests, Lint, Frontend-Build bei jedem Push/PR.
- [ ] `.gitignore`, `.editorconfig`.

**Fertig wenn:** `make test lint build` läuft lokal und in CI grün, das Binary startet und liefert die Platzhalter-Seite aus.

---

## Phase 1 – Scan-Pipeline (headless)

**Ziel:** Ein Lauf funktioniert vollständig ohne UI, ausgelöst per Kommandozeile.

- [ ] **1.1 `config`** – Env-Variablen laut SPEC §8 parsen und validieren; Tests für gültige/ungültige Werte; maskierte Ausgabe.
- [ ] **1.2 `store`** – Verbindung, Migrations-Mechanismus, `0001_init.sql` laut ARCHITECTURE §5; Basis-Queries für Runs, Images, Scans, Findings.
- [ ] **1.3 `docker`** – `ListImages` über `tcp://` und `unix://`; Normalisierung von `<none>:<none>`; Tests mit `httptest`.
- [ ] **1.4 `trivy`** – Parser mit Fixtures aus 0.1 (nach `internal/trivy/testdata/` kopieren); `UpdateDB`, `Scan` mit Timeout, Prozessgruppe, Priorität, gekürztem stderr; Prüfung der `ImageID`.
- [ ] **1.5 `scan`** – Orchestrator nach SPEC §5 (ohne Benachrichtigung): Dedup nach Image-ID, sequenziell, Fehler pro Image isoliert, Ergebnisse sofort speichern, `running` → `aborted` beim Start; Tests mit Fakes.
- [ ] **1.6 CLI** – `bilge run-once` führt einen Lauf aus und gibt eine Zusammenfassung aus.

**Fertig wenn:** `bilge run-once` auf dem Pi alle Images über den Proxy scannt, Findings in SQLite landen und ein absichtlich kaputtes Image den Lauf nicht abbricht.

---

## Phase 2 – Scheduler & API

**Ziel:** bilge läuft als Dienst und stellt alle Daten per API bereit.

- [ ] **2.1 `scheduler`** – Cron mit `TZ`, Erst-Start-Lauf (F-SCHED-2), nächster Lauf abfragbar.
- [ ] **2.2 Lauf-Steuerung** – `TryStart` mit Sperre, Fortschritt im Speicher, sauberes Beenden bei SIGTERM (NF-OPS-5).
- [ ] **2.3 `api` lesend** – `/api/status`, `/api/images`, `/api/images/{id}`, `/api/images/{id}/findings`, `/api/runs`, `/healthz`.
- [ ] **2.4 `api` schreibend** – `POST /api/runs` (202/409), Content-Type-Prüfung.
- [ ] **2.5 SPA-Auslieferung** – eingebettetes `dist`, Fallback auf `index.html`, Cache-Header für gehashte Assets.
- [ ] **2.6 Aufbewahrung** – Löschen alter Läufe, „entfernt“-Markierung (F-RET-1, F-IMG-4).
- [ ] **2.7 `bilge healthcheck`** – Subkommando für den Docker-Healthcheck.

**Fertig wenn:** bilge als Dienst läuft, nachts automatisch scannt, alle Endpunkte Handler-Tests haben und `curl` gegen die API sinnvolle Daten liefert.

---

## Phase 3 – Dashboard

**Ziel:** Die Ergebnisse sind im Browser übersichtlich lesbar.

- [ ] **3.1 Grundgerüst** – Routing, Layout, `api.ts` mit Typen, Fehler- und Ladezustände, Dark Mode.
- [ ] **3.2 Status-Leiste** – letzter/nächster Lauf, DB-Stand, „Jetzt scannen“, Fortschritt mit Polling während eines Laufs.
- [ ] **3.3 Übersicht** – Image-Tabelle mit Severity-Badges, Sortierung nach Kritikalität, Fehlerhinweis bei fehlgeschlagenem Scan.
- [ ] **3.4 Image-Detail** – Findings-Tabelle, sortierbar, Link zur CVE, Ziel (OS/Bibliothek) sichtbar.
- [ ] **3.5 Läufe** – Liste vergangener Läufe.

**Fertig wenn:** Alle Ansichten aus SPEC §4.5 (außer Ignores) im Browser auf Desktop und Handy benutzbar sind und das Frontend im Binary eingebettet ausgeliefert wird.

---

## Phase 4 – Filter & Ignores

**Ziel:** Rauschen reduzieren, Wichtiges sichtbar machen.

- [ ] **4.1 Filter-Backend** – `minSeverity`, `fixable`, `showIgnored` in SQL, Zähler konsistent (F-FILT-4).
- [ ] **4.2 Filter-UI** – Schalter in Übersicht und Detail, Zustand in der URL.
- [ ] **4.3 Ignore-Logik** – `IsIgnored` mit Repo-Parsing (inkl. Registry-Ports), tabellengetestet.
- [ ] **4.4 Ignore-API** – `GET/POST/DELETE /api/ignores`, Duplikate abgelehnt.
- [ ] **4.5 Ignore-UI** – Seite `/ignores`, Aktion „ignorieren (Repo/global)“ in der Finding-Zeile mit optionalem Grund, ignorierte Findings markiert.

**Fertig wenn:** Eine CVE global und pro Repository ignoriert werden kann, die Wirkung sofort ohne Re-Scan sichtbar ist und die Zähler in der Übersicht zu den Filtern passen.

---

## Phase 5 – Discord

**Ziel:** Nur echte Neuigkeiten erzeugen eine Meldung.

- [ ] **5.1 Diff** – `seen_findings` pflegen, `NewFindings` nach SPEC §6.4, alle Konsequenzen aus §6.4 als Testfälle.
- [ ] **5.2 Nachricht** – Embeds pro Image, Severity-Farbe, Kürzung gemäß Discord-Limits, Link zum Dashboard; Golden-File-Tests für das JSON.
- [ ] **5.3 Versand** – Retry/Backoff, `retry_after` bei 429, Fehler am Lauf speichern.
- [ ] **5.4 Baseline** – Erster Lauf sendet nur Zusammenfassung (F-NOT-5).
- [ ] **5.5 Testversand** – `POST /api/notify/test` und Button im Dashboard.

**Fertig wenn:** Auf dem Pi nach einem echten Lauf genau eine Nachricht mit den neuen High/Critical-Findings ankommt, ein zweiter Lauf ohne Änderungen keine Nachricht erzeugt und ignorierte CVEs nicht gemeldet werden.

---

## Phase 6 – Packaging & Release (v1.0)

**Ziel:** Andere können bilge in wenigen Minuten betreiben.

- [ ] **6.1 Dockerfile** – Multi-Stage laut ARCHITECTURE §7.1, Trivy-Version gepinnt, distroless, non-root.
- [ ] **6.2 Multi-Arch-Release** – GitHub Actions mit `buildx` für arm64/amd64, Push nach GHCR bei Tags, SemVer.
- [ ] **6.3 `compose.yml`** (Projekt-Root) – Beispiel laut ARCHITECTURE §7.2, getestet auf dem Pi.
- [ ] **6.4 Ressourcen prüfen** – RAM im Leerlauf ≤ 30 MB (NF-RES-1), read-only Root-FS funktioniert.
- [ ] **6.5 README** – Was/Warum, Schnellstart, Konfiguration, Sicherheitsmodell, Hinweis zu Reverse-Proxy/Auth, Ressourcenbedarf aus dem Spike, Screenshots.
- [ ] **6.6 Smoke-Test** – Skript, das Compose hochfährt, einen Lauf auslöst und `/api/status` prüft.

**Fertig wenn:** `docker compose up -d` mit dem Beispiel auf einem frischen Pi zu einem gefüllten Dashboard führt und `v1.0.0` auf GHCR veröffentlicht ist.

---

## Später (nach v1.0)

Priorisierung offen; jeweils erst nach Bedarf und Messung.

- **Ignores mit Ablaufdatum** – Regel läuft aus, CVE taucht wieder auf.
- **Weitere Notifier** – ntfy, Gotify, generischer Webhook.
- **Prometheus-Metriken** – `/metrics` mit Findings je Severity und Laufdauer.
- **Image-Filter** – Include/Exclude-Muster für Repositories.
- **Trend-Ansicht** – Verlauf der Findings pro Image über die Zeit.
- **Optionales Basic Auth** – falls LAN-only sich als zu knapp erweist.
