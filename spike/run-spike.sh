#!/usr/bin/env bash
# Spike 0.1 for bilge: runs Trivy through docker-socket-proxy and measures
# time, memory and disk usage. Instructions: README.md
set -euo pipefail
cd "$(dirname "$0")"

read -r -a IMAGES <<<"${SPIKE_IMAGES:-alpine:latest debian:stable-slim node:lts-slim jenkins/jenkins:lts}"
JAVA_IMAGE="${SPIKE_JAVA_IMAGE-jenkins/jenkins:lts}" # empty = skip Java DB tests

export SPIKE_UID SPIKE_GID
SPIKE_UID=$(id -u)
SPIKE_GID=$(id -g)

mkdir -p cache/tmp cache/home results/reports
exec > >(tee results/console.log) 2>&1
trap 'docker compose down >/dev/null 2>&1 || true' EXIT

printf 'label\texit\tseconds\tpeak_rss_mb\tvulns\timage_id\n' >results/measurements.tsv
printf 'image\tid\tsize_mb\n' >results/images.tsv

section() { printf '\n== %s\n' "$*"; }
in_trivy() { docker compose --progress quiet run --rm -T trivy "$@"; }
measure() { in_trivy /spike/measure.sh "$@"; }

scan_args() { # <cache-dir>
	echo image --image-src docker --scanners vuln --format json --quiet \
		--skip-db-update --skip-java-db-update --timeout 60m --cache-dir "$1"
}

section "System"
tr -d '\0' </proc/device-tree/model 2>/dev/null && echo || true
uname -a
free -m || true
df -h .
docker version --format 'Docker {{.Server.Version}} (API {{.Server.APIVersion}})'
docker info --format 'Cgroup v{{.CgroupVersion}}, MemoryLimit={{.MemoryLimit}}, SwapLimit={{.SwapLimit}}'

section "Pull images (directly on the host, not through the proxy)"
docker compose --profile tools pull -q
for img in "${IMAGES[@]}"; do
	docker pull -q "$img"
	printf '%s\t%s\t%s\n' "$img" \
		"$(docker image inspect -f '{{.Id}}' "$img")" \
		"$(($(docker image inspect -f '{{.Size}}' "$img") / 1048576))" >>results/images.tsv
done
column -t results/images.tsv 2>/dev/null || cat results/images.tsv

section "Versions"
in_trivy -c 'trivy --version'
docker image inspect -f '{{index .RepoDigests 0}}' "tecnativa/docker-socket-proxy:${PROXY_TAG:-latest}"
docker image inspect -f '{{index .RepoDigests 0}}' "aquasec/trivy:${TRIVY_TAG:-latest}"

section "Start socket-proxy"
docker compose up -d socket-proxy
sleep 3

section "Proxy permissions"
in_trivy /spike/proxy-check.sh "$(docker image inspect -f '{{.Id}}' "${IMAGES[0]}")"

section "Trivy DB download"
measure db-download image --download-db-only --cache-dir /cache
if [[ -n "$JAVA_IMAGE" ]]; then
	measure java-db-download image --download-java-db-only --cache-dir /cache
fi

section "Scans (cold cache by tag, warm cache by tag, by full ID, by short ID)"
read -r -a SCAN <<<"$(scan_args /cache)"
for img in "${IMAGES[@]}"; do
	name=${img//[\/:]/_}
	id=$(docker image inspect -f '{{.Id}}' "$img")
	short=${id#sha256:}
	short=${short:0:12}
	echo "-- $img (expected $id)"
	measure "$name.tag-cold" "${SCAN[@]}" "$img"
	measure "$name.tag-warm" "${SCAN[@]}" "$img"
	measure "$name.id-full" "${SCAN[@]}" "$id"
	measure "$name.id-short" "${SCAN[@]}" "$short"
done

if [[ -n "$JAVA_IMAGE" ]]; then
	section "Java image without Java DB (--skip-java-db-update, no java-db present)"
	in_trivy -c 'rm -rf /cache/nojava && mkdir -p /cache/nojava && cp -r /cache/db /cache/nojava/db'
	read -r -a SCAN_NOJAVA <<<"$(scan_args /cache/nojava)"
	measure "${JAVA_IMAGE//[\/:]/_}.no-java-db" "${SCAN_NOJAVA[@]}" "$JAVA_IMAGE"
fi

section "Cache sizes"
in_trivy -c 'du -sh /cache/* | sort -h'

section "Docker API endpoints requested through the proxy"
docker compose logs --no-color socket-proxy >results/proxy.log
grep -oE '"(GET|HEAD|POST|PUT|DELETE) [^ "]+' results/proxy.log |
	sed -E 's/\?.*//; s#^"##; s#/v[0-9.]+/#/#; s#sha256:[0-9a-f]+|[0-9a-f]{12,64}#<id>#g' |
	sort | uniq -c | sort -rn || echo "(no request lines found in proxy log)"

section "Denied requests (HTTP 403)"
grep -E ' 403 ' results/proxy.log || echo "none"

section "Measurements"
column -t -s $'\t' results/measurements.tsv 2>/dev/null || cat results/measurements.tsv

tar czf bilge-spike-results.tgz results
section "Done: $(pwd)/bilge-spike-results.tgz"
