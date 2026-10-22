# CLAUDE.md

bilge: schlanker, selbst gehosteter Schwachstellen-Scanner für lokale Docker-Images (Trivy). Ein Go-Binary mit eingebettetem React-Frontend, SQLite, läuft als ein Container auf einem Raspberry Pi (arm64).

## Dokumentation – zuerst lesen

- `docs/SPEC.md` – was bilge tut; Anforderungen mit IDs (z. B. `F-SCAN-1`, `NF-SEC-1`)
- `docs/ARCHITECTURE.md` – Pakete, Interfaces, Datenmodell, API, Build
- `docs/ROADMAP.md` – Phasen und Arbeitspakete mit Abnahmekriterien

Vor jeder Aufgabe den passenden Roadmap-Punkt und die betroffenen SPEC-Abschnitte lesen. Ändert sich eine Anforderung oder Architekturentscheidung, das Dokument im selben Commit anpassen.

## Befehle

> Gelten ab Roadmap Phase 0.2. Bis dahin existieren sie noch nicht.

```bash
make build        # Frontend bauen + Go-Binary (bin/bilge)
make test         # go test ./... und Frontend-Tests
make lint         # golangci-lint + eslint
make dev          # Go-Backend auf :8080 + Vite-Dev-Server mit /api-Proxy
go test ./internal/scan/ -run TestNewFindings   # einzelnen Test ausführen
```

## Harte Regeln

- **IMPORTANT:** bilge greift auf Docker **nur lesend** über `docker-socket-proxy` zu (`IMAGES=1`, `POST=0`). Nie Code schreiben, der Container startet, Images pullt/löscht oder einen anderen Endpunkt als die in ARCHITECTURE §4.2/§4.3 genannten benötigt.
- **IMPORTANT:** Kein CGO. SQLite ausschließlich über `modernc.org/sqlite`.
- Trivy nur über `exec.CommandContext` mit Argument-Liste aufrufen, nie über eine Shell.
- Die Discord-Webhook-URL nie loggen oder über die API ausgeben.
- Neue Go-Abhängigkeiten nur nach Rückfrage. Standardbibliothek bevorzugen (`net/http`, `log/slog`, `database/sql`, `embed`). Kein Docker-SDK, kein ORM, kein Web-Framework.
- Neue npm-Abhängigkeiten nur nach Rückfrage. Kein UI-Framework, keine CDNs.

## Code-Stil

**Go**
- Pakete unter `internal/` wie in ARCHITECTURE §3; Abhängigkeiten von außen (Docker, Trivy, Discord, Zeit) hinter kleinen Interfaces.
- Fachlogik (Diff, Ignore-Matching, Repo-Parsing) als reine Funktionen ohne I/O.
- Fehler mit Kontext wrappen: `fmt.Errorf("scan image %s: %w", id, err)`.
- `context.Context` als erster Parameter bei allem, was I/O macht.
- Logging nur über `log/slog` mit strukturierten Feldern.
- Plain SQL; Migrationen als neue nummerierte Datei in `internal/store/migrations/`, bestehende Migrationen nie ändern.

**Frontend (`web/`)**
- TypeScript strict, Funktionskomponenten, Hooks.
- API-Zugriffe nur über `src/api.ts`; Typen dort spiegeln die Go-DTOs.
- Filterzustand in der URL (`useSearchParams`), nicht in globalem State.

## Tests

- Tests zuerst bzw. zusammen mit dem Code schreiben; ein Feature ohne Tests ist nicht fertig.
- Tabellengetriebene Tests für Fachlogik.
- Trivy-Parser gegen echte Reports in `internal/trivy/testdata/`; nie Trivy-JSON von Hand erfinden.
- Docker- und Discord-Adapter mit `httptest.Server`, Store mit SQLite in `t.TempDir()`.
- Tests dürfen weder echtes Docker, echtes Trivy noch das Netzwerk brauchen.

## Arbeitsablauf

1. Roadmap-Punkt und SPEC-Abschnitte lesen; bei Unklarheiten fragen statt raten.
2. Bei nicht-trivialen Aufgaben erst einen Plan vorlegen.
3. Implementieren in kleinen Schritten; `make test lint` muss grün sein.
4. Roadmap-Checkbox abhaken, ggf. SPEC/ARCHITECTURE aktualisieren.
5. Commits nach [Conventional Commits](https://www.conventionalcommits.org/), atomar (ein logischer Schritt pro Commit), nur Titel ohne Body, Englisch im Imperativ (z. B. `feat(trivy): add JSON report parser`). Gemischte Änderungen auf mehrere Commits aufteilen.

## Sprache

Dokumentation in `docs/` und diese Datei: Deutsch. Code, Bezeichner, Kommentare, Commit-Messages, Log-Meldungen: Englisch.
