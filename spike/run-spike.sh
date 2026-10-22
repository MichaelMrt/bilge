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

# The live progress line goes straight to the terminal (fd 3), not into
# console.log; without a terminal (e.g. nohup) it is disabled.
if [[ -t 1 ]]; then
	exec 3>&1
	LIVE=1
else
	exec 3>/dev/null
	LIVE=0
fi
exec > >(tee results/console.log) 2>&1

# `docker compose down` leaves running one-off `run` containers behind, so
# remove every container of the project first (also on Ctrl+C).
cleanup() {
	local ids
	ids=$(docker ps -aq --filter label=com.docker.compose.project=bilge-spike)
	if [[ -n "$ids" ]]; then
		# shellcheck disable=SC2086 # word splitting of the ID list is intended
		docker rm -f $ids >/dev/null 2>&1 || true
	fi
	docker compose --profile tools down >/dev/null 2>&1 || true
	rm -f results/.step.log
}
abort() {
	printf '\r\033[K' >&3
	if [[ -n "$CURRENT_PID" ]]; then
		kill "$CURRENT_PID" 2>/dev/null || true
	fi
	echo
	echo "Aborted, cleaning up ..."
	exit 130
}
CURRENT_PID=""
trap cleanup EXIT
trap abort INT TERM

printf 'label\texit\tseconds\tpeak_rss_mb\tvulns\timage_id\n' >results/measurements.tsv
printf 'image\tid\tsize_mb\n' >results/images.tsv

section() { printf '\n== %s\n' "$*"; }
in_trivy() { docker compose --progress quiet run --rm -T trivy "$@"; }
measure() { in_trivy /spike/measure.sh "$@"; }

scan_args() { # <cache-dir>
	echo image --image-src docker --scanners vuln --format json --quiet \
		--skip-db-update --skip-java-db-update --timeout 60m --cache-dir "$1"
}

# Progress: one step per long-running command (pulls, DB downloads, scans).
JAVA_STEPS=0
if [[ -n "$JAVA_IMAGE" ]]; then
	JAVA_STEPS=2
fi
TOTAL=$((1 + ${#IMAGES[@]} + 1 + 4 * ${#IMAGES[@]} + JAVA_STEPS))
STEP=0

clock() { printf '%d:%02d' $(($1 / 60)) $(($1 % 60)); }
repeat() { # <char> <count>
	local s
	printf -v s '%*s' "$2" ''
	printf '%s' "${s// /$1}"
}

# step <description> <command...>
# Runs a long step in the background, shows a live progress line on the
# terminal and prints the step's output once it has finished.
step() {
	local desc=$1 rc=0 start=$SECONDS pid filled line cols
	shift
	STEP=$((STEP + 1))
	"$@" >results/.step.log 2>&1 &
	pid=$!
	CURRENT_PID=$pid
	if [[ $LIVE -eq 1 ]]; then
		filled=$(((STEP - 1) * 20 / TOTAL))
		while kill -0 "$pid" 2>/dev/null; do
			cols=$(tput cols 2>/dev/null || echo 80)
			line="[$(repeat '#' "$filled")$(repeat '.' $((20 - filled)))] $STEP/$TOTAL"
			line+="  $(clock $((SECONDS - start)))  (total $(clock "$SECONDS"))  $desc"
			printf '\r\033[K%s' "${line:0:cols-1}" >&3
			sleep 1
		done
		printf '\r\033[K' >&3
	fi
	wait "$pid" || rc=$?
	CURRENT_PID=""
	echo "[$STEP/$TOTAL] $desc ($(clock $((SECONDS - start))))"
	cat results/.step.log
	return "$rc"
}

section "System"
tr -d '\0' </proc/device-tree/model 2>/dev/null && echo || true
uname -a
free -m || true
df -h .
docker version --format 'Docker {{.Server.Version}} (API {{.Server.APIVersion}})'
docker info --format 'Cgroup v{{.CgroupVersion}}, MemoryLimit={{.MemoryLimit}}, SwapLimit={{.SwapLimit}}'

section "Pull images (directly on the host, not through the proxy)"
step "pull trivy and socket-proxy" docker compose --profile tools pull -q
for img in "${IMAGES[@]}"; do
	step "pull $img" docker pull -q "$img"
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
step "download Trivy DB" measure db-download image --download-db-only --cache-dir /cache
if [[ -n "$JAVA_IMAGE" ]]; then
	step "download Java DB" measure java-db-download image --download-java-db-only --cache-dir /cache
fi

section "Scans (cold cache by tag, warm cache by tag, by full ID, by short ID)"
read -r -a SCAN <<<"$(scan_args /cache)"
for img in "${IMAGES[@]}"; do
	name=${img//[\/:]/_}
	id=$(docker image inspect -f '{{.Id}}' "$img")
	short=${id#sha256:}
	short=${short:0:12}
	echo "-- $img (expected $id)"
	step "scan $img by tag, cold cache" measure "$name.tag-cold" "${SCAN[@]}" "$img"
	step "scan $img by tag, warm cache" measure "$name.tag-warm" "${SCAN[@]}" "$img"
	step "scan $img by full ID" measure "$name.id-full" "${SCAN[@]}" "$id"
	step "scan $img by short ID" measure "$name.id-short" "${SCAN[@]}" "$short"
done

if [[ -n "$JAVA_IMAGE" ]]; then
	section "Java image without Java DB (--skip-java-db-update, no java-db present)"
	in_trivy -c 'rm -rf /cache/nojava && mkdir -p /cache/nojava && cp -r /cache/db /cache/nojava/db'
	read -r -a SCAN_NOJAVA <<<"$(scan_args /cache/nojava)"
	step "scan $JAVA_IMAGE without Java DB" measure "${JAVA_IMAGE//[\/:]/_}.no-java-db" "${SCAN_NOJAVA[@]}" "$JAVA_IMAGE"
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
