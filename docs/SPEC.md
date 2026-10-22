# bilge – Spezifikation

> Status: Entwurf v0.1 · Stand: 2026-10-22
> Dieses Dokument beschreibt **was** bilge tut und warum. Das **wie** steht in
> [ARCHITECTURE.md](ARCHITECTURE.md), die Reihenfolge der Umsetzung in [ROADMAP.md](ROADMAP.md).

## 1. Zweck

bilge ist ein schlanker, selbst gehosteter Schwachstellen-Scanner für die **lokalen
Docker-Images eines Hosts**. Er läuft als einzelner Container (Zielplattform:
Raspberry Pi, arm64), scannt die Images täglich mit Trivy und zeigt die Ergebnisse
in einem Web-Dashboard an. Neue kritische Findings meldet er an Discord.

Der Name: Die Bilge ist der Ort im Schiff, an dem man nach Lecks schaut.

## 2. Abgrenzung

| | bilge | Arcane, Dockhand u. ä. |
|---|---|---|
| Aufgabe | nur Schwachstellen-Scan | kompletter Docker-Manager |
| Docker-Zugriff | **nur lesend**, über Socket-Proxy | Schreibzugriff auf den Socket |
| Ressourcen im Leerlauf | ca. 10–20 MB RAM | deutlich mehr |

### Nicht-Ziele (v1)

- Keine Verwaltung von Containern, Images oder Volumes (kein Pull, kein Löschen, kein Update).
- Keine Scans von Registries oder entfernten Hosts; nur Images des lokalen Daemons.
- Kein Multi-Host-Betrieb.
- Keine Benutzerverwaltung oder Authentifizierung (siehe §7.1).
- Kein Secret-, Misconfiguration- oder Lizenz-Scan; nur Schwachstellen (`--scanners vuln`).
- Keine automatische Behebung.
- Kein Kubernetes-Support.

## 3. Begriffe

| Begriff | Bedeutung |
|---|---|
| **Image** | Ein lokales Docker-Image, eindeutig identifiziert durch seine **Image-ID** (`sha256:…`). Ein Image kann mehrere Tags haben. |
| **Subjekt** | Ein `repo:tag` (z. B. `nginx:1.27`). Für ungetaggte Images ist das Subjekt die Image-ID. Dient als stabiler Bezug über Image-Updates hinweg. |
| **Lauf (Run)** | Ein vollständiger Durchgang des täglichen Ablaufs (§5). |
| **Scan** | Die Trivy-Prüfung genau eines Images innerhalb eines Laufs. |
| **Finding** | Eine Schwachstelle in einem Paket eines Images: (CVE-ID, Paketname, installierte Version, Fix-Version, Severity). |
| **Fixbar** | Ein Finding mit bekannter Fix-Version (`FixedVersion` nicht leer). |
| **Ignore** | Eine Regel, die eine CVE global oder für ein bestimmtes Repository ausblendet. |
| **Neues Finding** | Ein Finding, das für keines der Subjekte des Images bisher gesehen wurde (§6.4). |

## 4. Funktionale Anforderungen

### 4.1 Trivy-Datenbank

- **F-DB-1** bilge lädt die Trivy-Schwachstellen-Datenbank einmal pro Lauf herunter (vor den Scans) und cached sie im Daten-Volume.
- **F-DB-2** Die Java-Datenbank (`trivy-java-db`) ist per Konfiguration zuschaltbar (Standard: an), weil sie viel Speicherplatz belegt.
- **F-DB-3** Schlägt das Update fehl, aber eine gecachte DB existiert, wird mit der alten DB gescannt und eine Warnung protokolliert. Ohne gecachte DB wird der Lauf mit Fehler beendet.
- **F-DB-4** Version und Stand (`UpdatedAt`) der verwendeten DB werden pro Lauf gespeichert und im Dashboard angezeigt.

### 4.2 Image-Erkennung

- **F-IMG-1** bilge listet alle lokalen Images über die Docker Engine API (`GET /images/json`) via Socket-Proxy.
- **F-IMG-2** Jede Image-ID wird pro Lauf **genau einmal** gescannt, auch wenn sie mehrere Tags hat.
- **F-IMG-3** Ungetaggte Images (`<none>:<none>`, dangling) werden standardmäßig übersprungen (konfigurierbar).
- **F-IMG-4** Images, die nicht mehr existieren, werden als „entfernt“ markiert und nach Ablauf der Aufbewahrungsfrist gelöscht.

### 4.3 Scannen

- **F-SCAN-1** Images werden **nacheinander** gescannt, nie parallel.
- **F-SCAN-2** Es läuft immer höchstens ein Lauf gleichzeitig.
- **F-SCAN-3** Jeder Scan hat ein Timeout (Standard 15 min). Ein Fehler oder Timeout bei einem Image bricht den Lauf nicht ab; der Scan wird als fehlgeschlagen gespeichert.
- **F-SCAN-4** Trivy wird als Subprozess mit JSON-Ausgabe aufgerufen, nur mit dem Vulnerability-Scanner und ohne eigenes DB-Update.
- **F-SCAN-5** Pro Finding werden mindestens gespeichert: CVE-ID, Paketname, installierte Version, Fix-Version, Severity, Status (Trivy), Titel, Primär-URL, Ziel (z. B. `debian 12.5`, `usr/lib/node_modules/...`).

### 4.4 Zeitplan & Auslösung

- **F-SCHED-1** Der Lauf startet täglich nach einem konfigurierbaren Cron-Ausdruck (Standard: `0 3 * * *`, Zeitzone aus `TZ`).
- **F-SCHED-2** Beim allerersten Start (leere Datenbank) startet sofort ein Lauf, damit das Dashboard nicht 24 h leer bleibt (abschaltbar).
- **F-SCHED-3** Ein Lauf kann im Dashboard manuell ausgelöst werden. Läuft bereits einer, wird die Anfrage abgelehnt (HTTP 409) und der laufende Lauf angezeigt.

### 4.5 Dashboard

- **F-UI-1** **Übersicht:** alle Images mit Tags, gekürzter ID, Erstellungsdatum, Größe, Zeitpunkt des letzten Scans, Scan-Status und Anzahl der Findings je Severity. Sortierung standardmäßig nach Kritikalität (Critical, dann High, …).
- **F-UI-2** **Image-Detail:** Tabelle aller Findings eines Images, gruppiert oder sortierbar nach Severity, mit Link zur CVE.
- **F-UI-3** **Status-Leiste:** letzter Lauf (Zeitpunkt, Dauer, Ergebnis), nächster geplanter Lauf, Trivy-DB-Stand, Button „Jetzt scannen“, Fortschritt eines laufenden Laufs (Image x von y).
- **F-UI-4** **Läufe:** Liste der vergangenen Läufe mit Dauer, Anzahl gescannter Images, Fehlern und neuen Findings.
- **F-UI-5** **Ignores:** Liste aller Ignore-Regeln, anlegen und löschen.
- **F-UI-6** Das Dashboard funktioniert ohne externe Ressourcen (keine CDNs); alles ist ins Binary eingebettet.

### 4.6 Filter

Filter gelten in Übersicht und Detail-Ansicht und werden in der URL gehalten (teilbar, Reload-fest).

- **F-FILT-1** **Nur High/Critical** – blendet Medium, Low und Unknown aus.
- **F-FILT-2** **Nicht fixbare ausblenden** – blendet Findings ohne Fix-Version aus.
- **F-FILT-3** **Ignorierte ausblenden** – Standard an; ausgeschaltet werden ignorierte Findings markiert angezeigt.
- **F-FILT-4** Die Severity-Zähler in der Übersicht berücksichtigen die aktiven Filter.

### 4.7 Ignores

- **F-IGN-1** Eine Ignore-Regel besteht aus CVE-ID, optionalem **Scope** (Repository ohne Tag, z. B. `nginx` oder `ghcr.io/foo/bar`; leer = global) und optionalem Grund.
- **F-IGN-2** Ein Finding ist ignoriert, wenn eine globale Regel für die CVE existiert **oder** eine Regel, deren Scope einem der Repositories des Images entspricht.
- **F-IGN-3** Regeln können direkt aus einer Finding-Zeile heraus angelegt werden („für dieses Repo ignorieren“ / „global ignorieren“).
- **F-IGN-4** Ignores wirken sofort auf Anzeige und Benachrichtigungen, ohne erneuten Scan. Findings werden nie gelöscht, nur ausgeblendet.

### 4.8 Discord-Benachrichtigung

- **F-NOT-1** Ist eine Webhook-URL konfiguriert, sendet bilge **am Ende eines Laufs höchstens eine Nachricht**, und zwar nur, wenn es neue Findings gibt (§6.4).
- **F-NOT-2** Berücksichtigt werden nur Findings mit Severity ≥ konfigurierter Schwelle (Standard: `HIGH`, also High und Critical), die nicht ignoriert sind. Optional nur fixbare.
- **F-NOT-3** Die Nachricht fasst pro Image zusammen: Tags, Anzahl neuer Critical/High, die wichtigsten CVE-IDs (mit Paket und Fix-Version). Bei Überschreitung der Discord-Limits wird gekürzt („… und 12 weitere“) und auf das Dashboard verwiesen.
- **F-NOT-4** Optional enthält die Nachricht einen Link zum Dashboard (konfigurierbare Basis-URL).
- **F-NOT-5** Beim allerersten Lauf (Baseline) wird keine Liste aller Findings gesendet, sondern nur eine kurze Zusammenfassung („bilge ist aktiv: N Images, X Critical, Y High“), um eine Flut zu vermeiden.
- **F-NOT-6** Schlägt das Senden fehl, wird bis zu 3-mal mit Backoff wiederholt; danach wird der Fehler am Lauf gespeichert. Ein Fehler beim Senden lässt den Lauf nicht scheitern.
- **F-NOT-7** Ein Testversand ist über das Dashboard möglich.

### 4.9 Aufbewahrung

- **F-RET-1** Läufe und deren Scans/Findings werden nach einer konfigurierbaren Frist (Standard: 30 Tage) gelöscht; der jeweils letzte erfolgreiche Scan eines noch vorhandenen Images bleibt immer erhalten.
- **F-RET-2** Die Tabelle der bereits gesehenen Findings (§6.4) wird nicht automatisch gelöscht, solange das Subjekt existiert.

## 5. Täglicher Ablauf

1. **Lauf anlegen** (Status `running`), Sperre setzen.
2. **Trivy-DB aktualisieren** (F-DB-1 bis F-DB-3).
3. **Images auflisten** über den Proxy, deduplizieren nach Image-ID, Filter anwenden (F-IMG-3), Images-Tabelle aktualisieren.
4. **Jedes Image nacheinander scannen**, Ergebnis pro Image sofort speichern (ein Absturz mitten im Lauf verliert keine fertigen Scans).
5. **Vergleichen:** neue Findings gegenüber den bisher gesehenen bestimmen (§6.4).
6. **Benachrichtigen:** neue High/Critical-Findings gesammelt an Discord senden.
7. **Aufräumen:** Aufbewahrung anwenden, Lauf abschließen (`succeeded`, `partial` bei einzelnen Image-Fehlern, `failed`).

## 6. Fachliche Regeln

### 6.1 Severity

Trivy-Stufen: `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, `UNKNOWN`. Sortierung in genau dieser Reihenfolge.

### 6.2 Identität eines Findings

Innerhalb eines Images ist ein Finding eindeutig durch **(CVE-ID, Paketname, installierte Version, Ziel)**. Findings, die Trivy mehrfach meldet, werden dedupliziert.

### 6.3 Aktueller Stand eines Images

Der aktuelle Stand eines Images ist sein **letzter erfolgreicher Scan**. Schlägt ein Scan fehl, zeigt das Dashboard weiter den letzten erfolgreichen Stand mit Fehlerhinweis.

### 6.4 „Neu“ für Benachrichtigungen

bilge führt eine Liste bereits gesehener Paare **(Subjekt, CVE-ID, Paketname)** mit Zeitpunkt der ersten Sichtung.

Ein Finding eines Images gilt als **neu**, wenn das Paar (CVE-ID, Paketname) für **keines** der Subjekte des Images bereits gesehen wurde. Nach dem Lauf werden alle Paare für alle Subjekte des Images als gesehen eingetragen.

Konsequenzen (gewollt):
- Wird `nginx:latest` auf ein neues Image aktualisiert, das dieselbe CVE noch enthält, wird **nicht** erneut gemeldet.
- Taucht eine CVE nach DB-Update neu auf, wird sie gemeldet, auch wenn sich das Image nicht geändert hat.
- Eine CVE, die verschwindet und später wieder auftaucht, wird nicht erneut gemeldet.
- Wird ein Ignore wieder gelöscht, löst das keine nachträgliche Meldung aus.

## 7. Nicht-funktionale Anforderungen

### 7.1 Sicherheit

- **NF-SEC-1** bilge hat **keinen** direkten Zugriff auf `/var/run/docker.sock`. Der Zugriff erfolgt ausschließlich über `docker-socket-proxy` mit `IMAGES=1`, `POST=0` und allen anderen Bereichen deaktiviert.
- **NF-SEC-2** Der Proxy ist nur in einem internen Docker-Netz erreichbar, das kein Port-Publishing hat.
- **NF-SEC-3** Wird bilge kompromittiert, kann ein Angreifer Images lesen, aber keine Container starten, keine Images verändern und nicht Root auf dem Host werden.
- **NF-SEC-4** Das Dashboard hat keine eigene Authentifizierung und ist für den Betrieb im LAN gedacht. Wer es von außen erreichbar macht, setzt einen Reverse-Proxy mit Auth davor (dokumentiert im README).
- **NF-SEC-5** Der Container läuft als Nicht-Root-Benutzer, mit `no-new-privileges`, ohne Capabilities und mit read-only Root-Dateisystem (nur das Daten-Volume ist beschreibbar).
- **NF-SEC-6** Trivy wird ohne Shell mit Argument-Liste aufgerufen; Image-Referenzen aus der Docker-API werden nie in Shell-Strings interpoliert.
- **NF-SEC-7** Die Discord-Webhook-URL ist ein Geheimnis: Sie erscheint weder in Logs noch in API-Antworten.

### 7.2 Ressourcen & Plattform

- **NF-RES-1** bilge selbst braucht im Leerlauf ≤ 30 MB RAM (Ziel: 10–20 MB).
- **NF-RES-2** Während eines Scans darf Trivy kurzzeitig mehr Speicher nutzen; Empfehlung: Pi mit ≥ 4 GB RAM. Trivy läuft mit niedriger CPU-Priorität und optional mit `GOMEMLIMIT`. Temporäre Dateien landen auf dem Volume, nicht im RAM.
- **NF-RES-3** Speicherbedarf des Volumes: Trivy-DB, optional Java-DB und Layer-Cache, zusammen einige GB. Die genauen Werte werden im Spike (Roadmap Phase 0) gemessen und im README dokumentiert.
- **NF-PLAT-1** Container-Images für `linux/arm64` (primär) und `linux/amd64`.
- **NF-PLAT-2** Ein einzelnes statisches Go-Binary ohne CGO, Frontend eingebettet.

### 7.3 Betrieb

- **NF-OPS-1** Gesamte Konfiguration über Umgebungsvariablen (§8).
- **NF-OPS-2** Ein Daten-Volume (`/data`) enthält SQLite-DB und Trivy-Cache. Ohne Volume gehen nur Daten verloren, keine Funktion.
- **NF-OPS-3** Health-Endpoint für Docker-Healthcheck.
- **NF-OPS-4** Strukturierte Logs auf stdout.
- **NF-OPS-5** Sauberes Herunterfahren bei SIGTERM: laufender Trivy-Prozess wird beendet, der Lauf als abgebrochen markiert.
- **NF-OPS-6** Ein beim Start vorgefundener Lauf mit Status `running` (z. B. nach Stromausfall) wird als `aborted` markiert.

## 8. Konfiguration

| Variable | Standard | Beschreibung |
|---|---|---|
| `BILGE_LISTEN_ADDR` | `:8080` | Adresse des HTTP-Servers |
| `BILGE_DATA_DIR` | `/data` | Verzeichnis für SQLite-DB und Trivy-Cache |
| `DOCKER_HOST` | `tcp://socket-proxy:2375` | Adresse des Socket-Proxys |
| `BILGE_SCHEDULE` | `0 3 * * *` | Cron-Ausdruck für den täglichen Lauf |
| `TZ` | `UTC` | Zeitzone für den Zeitplan |
| `BILGE_SCAN_ON_FIRST_START` | `true` | Sofortiger Lauf bei leerer Datenbank |
| `BILGE_SCAN_TIMEOUT` | `15m` | Timeout pro Image |
| `BILGE_SKIP_DANGLING` | `true` | Ungetaggte Images überspringen |
| `BILGE_JAVA_DB` | `true` | Java-DB herunterladen und nutzen |
| `BILGE_TRIVY_DB_REPOSITORY` | (Trivy-Standard) | Alternatives DB-Repository/Mirror |
| `BILGE_TRIVY_MEMLIMIT` | (leer) | `GOMEMLIMIT` für den Trivy-Prozess, z. B. `1GiB` |
| `BILGE_RETENTION` | `720h` | Aufbewahrungsfrist für Läufe |
| `BILGE_DISCORD_WEBHOOK_URL` | (leer) | Discord-Webhook; leer = Benachrichtigungen aus |
| `BILGE_NOTIFY_MIN_SEVERITY` | `HIGH` | Mindest-Severity für Benachrichtigungen |
| `BILGE_NOTIFY_ONLY_FIXABLE` | `false` | Nur fixbare Findings melden |
| `BILGE_PUBLIC_URL` | (leer) | Basis-URL des Dashboards für Links in Discord |
| `BILGE_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `BILGE_LOG_FORMAT` | `text` | `text` oder `json` |

Ungültige Werte führen zu einem Fehler beim Start mit klarer Meldung, nicht zu stillen Standardwerten.

## 9. Entscheidungen

| # | Entscheidung | Begründung |
|---|---|---|
| E1 | Keine eigene Auth, LAN-only | Hält bilge schlank; Auth gehört in den Reverse-Proxy. |
| E2 | Ignores global oder pro Repository | Deckt „betrifft uns nie“ und „in diesem Image irrelevant“ ab, ohne Ablaufdaten-Komplexität. |
| E3 | Scan direkt per Image, SBOM-Modus später | Trivy cached bereits Layer-Analysen; ob der SBOM-Modus auf dem Pi spürbar spart, wird erst gemessen (Roadmap). |
| E4 | „Neu“ über Subjekte (`repo:tag`), nicht Image-ID | Verhindert erneute Meldungen bei jedem Image-Update mit gleicher Rest-CVE. |
| E5 | Baseline-Lauf ohne Detail-Meldung | Vermeidet eine Flut von Discord-Nachrichten beim Einrichten. |

## 10. Offene Punkte

Werden im Spike (Roadmap Phase 0, Werkzeug in `spike/`) geklärt:

- [ ] Funktioniert `trivy image --image-src docker` vollständig über den Proxy mit nur `IMAGES=1` (und den Proxy-Standards `PING`/`VERSION`)?
- [ ] Akzeptiert Trivy die Image-ID (`sha256:…`) als Scan-Ziel, oder muss ein Tag verwendet werden?
- [ ] Verhalten von Trivy ohne Java-DB, wenn `BILGE_JAVA_DB=false`.
- [ ] RAM-Spitze, Dauer und Volume-Größe auf dem Pi für typische Images (Alpine, Debian, Node, Java).
- [ ] Wie viel spart ein zweiter Scan desselben Images durch Trivys Layer-Cache? (Entscheidungsgrundlage für den SBOM-Modus.)
