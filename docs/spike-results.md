# Spike 0.1 – Ergebnisse

> Lauf am 2026-10-22 auf dem Raspberry Pi mit [`spike/run-spike.sh`](../spike/run-spike.sh).
> Rohdaten liegen lokal (nicht im Repo) in `spike/pi-results/`.

## Umgebung

| | |
|---|---|
| Hardware | Raspberry Pi 5 Model B, 8 GB RAM, NVMe-SSD |
| System | Raspberry Pi OS, Kernel 6.12.75 (aarch64), cgroup v2 |
| Docker | 29.9.2 (API 1.56), **Memory-Limits nicht verfügbar** (`MemoryLimit=false`) |
| Trivy | 0.76.1 (`aquasec/trivy@sha256:790fd66d…`) |
| Proxy | `tecnativa/docker-socket-proxy@sha256:1f5038b5…` |

Gesamtdauer des Laufs: etwa **4 Minuten**, davon fast 2 Minuten für die Java-DB. Meine Schätzung von 30–60 Minuten war viel zu hoch; NVMe und schnelles Internet machen viel aus.

## Messwerte

| Image | Größe | Findings | kalt: Zeit / RAM | warm: Zeit / RAM |
|---|---|---|---|---|
| `alpine:latest` (3.24.3) | 8 MB | 0 | < 1 s / 105 MB | < 1 s / 94 MB |
| `debian:stable-slim` (13.7) | 95 MB | 162 | 1 s / 114 MB | < 1 s / 105 MB |
| `node:lts-slim` (Debian 12) | 237 MB | 240 | 3 s / 126 MB | < 1 s / 114 MB |
| `jenkins/jenkins:lts` | 449 MB | 439 | 7 s / 261 MB | < 1 s / 134 MB |

RAM = Spitze des Trivy-Prozesses (`Maximum resident set size`). Pro Trivy-Aufruf kommt etwa 1 s für den Container-Start im Spike dazu; bei bilge entfällt das.

| Download | Dauer | RAM | Größe auf Disk |
|---|---|---|---|
| Trivy-DB | 17 s | 110 MB | 1,5 GB |
| Java-DB | 102 s | 96 MB | 1,5 GB |
| Layer-Cache (`fanal`) für alle 4 Images | – | – | 1,8 MB |

## Antworten auf SPEC §10

1. **Reicht der Proxy mit `IMAGES=1`?** Ja. Kein einziger Trivy-Aufruf wurde verweigert. Verweigert wurden nur die absichtlichen Gegenproben (`/info`, `/containers/json`, `/volumes`, `POST …/start`). Trivy nutzt ausschließlich `HEAD /_ping`, `GET /images/{ref}/json`, `GET /images/{ref}/history` und `GET /images/get`.
2. **Image-ID als Scan-Ziel?** Ja, volle und kurze ID funktionieren. `Metadata.ImageID` stimmt in allen Reports mit der erwarteten ID überein; die Findings sind identisch zum Scan per Tag.
3. **Ohne Java-DB?** **Scheitert.** Mit `--skip-java-db-update` und ohne vorhandene Java-DB bricht Trivy bei Images mit `.jar`-Dateien komplett ab (`FATAL … '--skip-java-db-update' cannot be specified on the first run`). Es gibt dann gar keinen Report, auch nicht für die OS-Pakete. `BILGE_JAVA_DB=false` lässt sich so nicht umsetzen → Entscheidung nötig (siehe unten).
4. **RAM, Dauer, Volume auf dem Pi?** RAM-Spitze maximal 261 MB, Scans dauern Sekunden, das Volume braucht ca. 3 GB (beide DBs je 1,5 GB, Layer-Cache vernachlässigbar).
5. **Spart der Layer-Cache?** Deutlich. Warme Scans dauern unter 1 s und brauchen weniger RAM. Das Proxy-Log zeigt **5** Image-Exporte (`/images/get`) für **17** Scans: nur die vier kalten Scans und der Scan mit separatem Cache haben exportiert. Ein unverändertes Image wird also bei täglichen Scans nicht erneut entpackt.

## Folgerungen

- **SBOM-Modus ist überflüssig.** Trivys Layer-Cache leistet bereits genau das, was der SBOM-Modus sparen sollte (SPEC E3). Er wird aus der Roadmap gestrichen.
- **Hardware-Empfehlung senken.** 4 GB RAM sind nicht nötig; ein Pi mit 2 GB hat bei Trivy-Spitzen von ~260 MB viel Luft. 1 GB ist ungetestet.
- **Container-Memory-Limits wirken auf Raspberry Pi OS nicht**, weil der Kernel den Memory-Controller standardmäßig abschaltet. `mem_limit` in Compose bringt also nichts; das Mittel der Wahl bleibt `GOMEMLIMIT` für den Trivy-Prozess.
- **Volume-Bedarf** von ca. 3 GB plus Reserve im README dokumentieren.
- **Der erste Lauf** dauert wegen der Downloads ca. 2 Minuten länger als spätere.

## Erkenntnisse für den Parser (Phase 1.4)

- `SchemaVersion` ist `2`; der Report hat `Trivy.Version`.
- `Metadata.OS` ist ein **Objekt** `{Family, Name}` (z. B. `debian` / `13.7`), kein String.
- `Results[].Class` kommt als `os-pkgs` oder `lang-pkgs` vor; `Type` u. a. als `alpine`, `debian`, `node-pkg`, `jar`, `gobinary`.
- `FixedVersion` **fehlt** im JSON, wenn es keinen Fix gibt (nicht leerer String).
- `Status` kommt als `affected`, `fixed`, `fix_deferred`, `will_not_fix` vor. `fixed` trat genau dann auf, wenn `FixedVersion` gesetzt war.
- Java-Findings stehen alle unter `Target: "Java"`; welches `.jar` betroffen ist, steht in `PkgPath`. `PkgPath` gehört deshalb in die Identität eines Findings (SPEC §6.2).
- `Fingerprint` ist **nicht stabil**: Er unterscheidet sich zwischen Scan per Tag und per ID. Nicht als Schlüssel verwenden.
- Severity `UNKNOWN` kommt tatsächlich vor (bis zu 9 pro Image).
- Reports sind groß: bis 2 MB pro Image wegen `Description`, `References` und `CVSS`. bilge speichert diese Felder nicht.

## Auffällig für die Filter

Bei Debian-basierten Images ist **kaum etwas fixbar**: `debian:stable-slim` hat 0 von 162, `node:lts-slim` 11 von 240 Findings mit Fix-Version. Der Filter „nicht fixbare ausblenden“ (F-FILT-2) blendet dort also fast alles aus. Das ist korrekt, sollte im Dashboard aber nachvollziehbar sein (z. B. Zähler „X ausgeblendet“).

## Test-Fixtures

Für `internal/trivy/testdata/` (Phase 1.4) eignen sich die kalten Scans per Tag:

| Datei | Größe | deckt ab |
|---|---|---|
| `alpine_latest.tag-cold.json` | 21 KB | Report ohne Findings |
| `node_lts-slim.tag-cold.json` | 1,1 MB | OS- und Node-Pakete, alle vier Status-Werte, CRITICAL |
| `jenkins_jenkins_lts.tag-cold.json` | 1,9 MB | `jar` mit `PkgPath`, `gobinary`, UNKNOWN |

Alles öffentliche Images, also unbedenklich fürs Repo. Bis Phase 1.4 bleiben sie lokal in `spike/pi-results/`.
