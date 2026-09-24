#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ne 3 ]; then
    echo "usage: build-linux-probe.sh BASE_INITRD PROBE_SCRIPT OUTPUT_INITRD" >&2
    exit 2
fi
base=$(realpath "$1")
probe=$(realpath "$2")
output=$(realpath -m "$3")
test -f "$base"
test -f "$probe"
test ! -e "$output"
command -v busybox >/dev/null
command -v gzip >/dev/null

temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM
mkdir "$temporary/limiar"
cp -- "$probe" "$temporary/limiar/probe-init"
chmod 755 "$temporary/limiar/probe-init"
# The kernel accepts concatenated initramfs archives; the upstream archive is unchanged.
(
    cd "$temporary"
    printf 'limiar\nlimiar/probe-init\n' | busybox cpio -o -H newc 2>/dev/null
) | gzip -n > "$temporary/overlay.gz"
mkdir -p -- "$(dirname "$output")"
(set -C; cat "$base" "$temporary/overlay.gz" > "$output")
sha256sum "$base" "$output"
