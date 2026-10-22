#!/bin/sh
# Runs inside the trivy container. Checks which Docker API endpoints the
# socket-proxy allows. Usage: proxy-check.sh <image-id>
set -u

base="http://socket-proxy:2375"
image_id="$1"

status() {
	# busybox wget prints the status line with -S, also for error responses.
	"$@" 2>&1 | grep -oE 'HTTP/1\.[01] [0-9]{3}' | head -n 1 | cut -d' ' -f2
}

check() {
	method="$1"
	path="$2"
	expect="$3"
	if [ "$method" = POST ]; then
		code=$(status wget -S -q -O /dev/null --post-data='' "$base$path")
	else
		code=$(status wget -S -q -O /dev/null "$base$path")
	fi
	code=${code:-none}
	if [ "$code" = "$expect" ]; then verdict=ok; else verdict=UNEXPECTED; fi
	printf '%-10s %-6s %-45s got=%-5s expected=%s\n' "$verdict" "$method" "$path" "$code" "$expect"
}

check GET /_ping 200
check GET /version 200
check GET /images/json 200
check GET "/images/$image_id/json" 200
check GET /info 403
check GET /containers/json 403
check GET /volumes 403
# Harmless if it were allowed: the container does not exist (would be 404).
check POST /containers/bilge-spike-does-not-exist/start 403
