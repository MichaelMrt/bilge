#!/bin/sh
# Runs inside the trivy container.
# Usage: measure.sh <label> <trivy args...>
# Writes stdout/stderr to /results/reports/<label>.{json,stderr} and appends
# one line to /results/measurements.tsv.
set -u

label="$1"
shift
mkdir -p /results/reports
out="/results/reports/$label.json"
err="/results/reports/$label.stderr"
tim="/results/reports/$label.time"

start=$(date +%s)
time -v -o "$tim" trivy "$@" >"$out" 2>"$err"
rc=$?
secs=$(($(date +%s) - start))

# Peak resident set size of the trivy process.
peak_kb=$(awk -F': ' '/Maximum resident set size/ {print $2}' "$tim")
peak_mb=$((${peak_kb:-0} / 1024))

vulns=$(grep -c '"VulnerabilityID"' "$out" 2>/dev/null)
image_id=$(grep -o '"ImageID": *"sha256:[0-9a-f]*"' "$out" 2>/dev/null | head -n 1 | grep -o 'sha256:[0-9a-f]*')

printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
	"$label" "$rc" "$secs" "$peak_mb" "${vulns:-0}" "${image_id:-}" \
	>>/results/measurements.tsv
echo "$label: exit=$rc ${secs}s peak_rss=${peak_mb}MB vulns=${vulns:-0}"
if [ "$rc" -ne 0 ]; then
	echo "  stderr (tail):"
	tail -n 5 "$err" | sed 's/^/    /'
fi
