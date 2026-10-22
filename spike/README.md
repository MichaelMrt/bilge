# Spike 0.1 – Trivy über den Socket-Proxy auf dem Pi

Ziel: die offenen Punkte aus [SPEC §10](../docs/SPEC.md#10-offene-punkte) auf der echten Hardware klären, bevor Code entsteht (Roadmap Phase 0.1).

Das Skript prüft:

1. ob der `docker-socket-proxy` mit nur `IMAGES=1` / `POST=0` alles erlaubt, was Trivy braucht, und alles andere verweigert,
2. ob Trivy die Image-ID (voll und kurz) als Scan-Ziel akzeptiert,
3. Dauer und RAM-Spitze von Trivy pro Image, mit leerem und mit gefülltem Layer-Cache,
4. Größe von Trivy-DB, Java-DB und Layer-Cache,
5. wie sich ein Java-Image ohne Java-DB verhält.

Der Docker-Socket wird **nur** in den Proxy gemountet. Der Trivy-Container läuft ohne Root und sieht Docker nur über den Proxy, genau wie später bilge.

## Voraussetzungen auf dem Pi

- 64-Bit-Betriebssystem: `uname -m` zeigt `aarch64`
- Docker mit Compose-Plugin: `docker compose version` funktioniert
- Dein Benutzer darf Docker nutzen (Gruppe `docker`)
- Mindestens **8 GB freier Speicherplatz**: Trivy-DB ca. 1,5 GB, Java-DB und Test-Images zusammen mehrere GB
- Internetzugang (Images und Trivy-DB werden heruntergeladen)

Dauer: je nach Pi und Internetverbindung **30–60 Minuten**. Am längsten dauern die Java-DB und der erste Scan des Jenkins-Images.

## 1. Dateien auf den Pi bringen

Entweder per Git (vorher auf dem Mac `git push`):

```bash
git clone https://github.com/MichaelMrt/bilge.git ~/bilge
```

Oder direkt vom Mac kopieren (`pi@raspberrypi` anpassen):

```bash
scp -r ~/Repos/bilge/spike pi@raspberrypi:~/bilge-spike
```

## 2. Spike ausführen

Auf dem Pi, am besten in `tmux` oder `screen`, damit ein SSH-Abbruch den Lauf nicht beendet:

```bash
cd ~/bilge/spike   # bzw. ~/bilge-spike
```

```bash
./run-spike.sh
```

Standardmäßig werden `alpine:latest`, `debian:stable-slim`, `node:lts-slim` und `jenkins/jenkins:lts` gescannt. Aussagekräftiger ist es mit **deinen eigenen Images**. Die stehen dann aber in den Ergebnissen; wenn du das nicht willst, nimm nur öffentliche Images:

```bash
SPIKE_IMAGES="alpine:latest debian:stable-slim node:lts-slim jenkins/jenkins:lts nginx:latest" ./run-spike.sh
```

Weitere Variablen:

| Variable | Standard | Bedeutung |
|---|---|---|
| `SPIKE_IMAGES` | siehe oben | Leerzeichen-getrennte Liste der zu scannenden Images |
| `SPIKE_JAVA_IMAGE` | `jenkins/jenkins:lts` | Image für den Test ohne Java-DB; leer = Java-Tests überspringen |
| `TRIVY_TAG` | `latest` | Version von `aquasec/trivy` |
| `PROXY_TAG` | `latest` | Version von `tecnativa/docker-socket-proxy` |

Optional in einem zweiten Terminal den Speicher des ganzen Pi beobachten:

```bash
watch -n 2 free -m
```

## 3. Was das Skript tut

1. Systeminfos sammeln (Modell, Kernel, RAM, Speicherplatz, Docker-Version, cgroup)
2. Test-Images direkt auf dem Host pullen (nicht über den Proxy)
3. Proxy starten und erlaubte/verbotene Endpunkte prüfen (`ok` / `UNEXPECTED`)
4. Trivy-DB und Java-DB herunterladen, mit Zeit- und RAM-Messung
5. Jedes Image viermal scannen: per Tag mit leerem Cache, per Tag mit gefülltem Cache, per voller Image-ID, per kurzer Image-ID
6. Das Java-Image einmal ohne Java-DB scannen
7. Cache-Größen messen
8. Proxy-Log auswerten: welche Endpunkte Trivy aufgerufen hat und welche verweigert wurden
9. Alles in `results/` sammeln und als `bilge-spike-results.tgz` packen

## 4. Ergebnisse zurückschicken

Auf dem Mac (`pi@raspberrypi` und Pfad anpassen):

```bash
scp pi@raspberrypi:~/bilge/spike/bilge-spike-results.tgz ~/Repos/bilge/spike/
```

Dann Bescheid geben. Ich werte die Ergebnisse aus, schreibe `docs/spike-results.md`, aktualisiere SPEC und ARCHITECTURE und wähle geeignete Reports als Test-Fixtures für den Parser aus.

Das Archiv enthält: `console.log` (komplette Ausgabe), `measurements.tsv`, `images.tsv`, `proxy.log` und unter `reports/` die Trivy-JSON-Reports.

## 5. Aufräumen auf dem Pi

```bash
docker compose down
```

```bash
rm -rf cache results bilge-spike-results.tgz
```

```bash
docker image rm alpine:latest debian:stable-slim node:lts-slim jenkins/jenkins:lts aquasec/trivy:latest tecnativa/docker-socket-proxy:latest
```

Images, die du ohnehin nutzt, beim letzten Befehl weglassen.

## Lokaler Vortest (Mac, arm64)

Das Skript wurde am 2026-10-22 auf einem Mac mit Docker 29.8.2 und Trivy 0.76.1 mit `alpine` getestet (ohne Java-DB):

- Alle Proxy-Prüfungen `ok`; Trivy wurde kein einziger Aufruf verweigert.
- Trivy ruft auf: `HEAD /_ping`, `GET /images/{ref}/json`, `GET /images/{ref}/history`, `GET /images/get` (Image-Export).
- Scans per Tag, voller ID und kurzer ID funktionieren; `Metadata.ImageID` stimmt jeweils.
- Bei gefülltem Cache wurde das Image **nicht erneut exportiert** (`/images/get` nur einmal für vier Scans).
- Trivy-DB: ca. 1,5 GB entpackt. RAM-Spitze von Trivy bei `alpine`: ca. 110 MB.

Der Pi-Lauf muss das für größere Images und echte Hardware bestätigen.
