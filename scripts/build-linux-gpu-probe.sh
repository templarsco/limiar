#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ne 5 ]; then
    echo "usage: build-linux-gpu-probe.sh BASE_INITRD PROBE_SCRIPT CPP_SOURCE HEADERS OUTPUT" >&2
    exit 2
fi
base=$(realpath "$1")
probe=$(realpath "$2")
source=$(realpath "$3")
headers=$(realpath "$4")
output=$(realpath -m "$5")
test ! -e "$output"
for tool in g++ busybox gzip ldd ldconfig sha256sum install; do command -v "$tool" >/dev/null; done
for library in libdxcore.so libd3d12.so libd3d12core.so; do
    test -f "/usr/lib/wsl/lib/$library"
done
test -d /usr/lib/wsl/drivers

temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM
root="$temporary/root"
mkdir -p "$root/limiar"
cp -- "$probe" "$root/limiar/probe-init"
chmod 755 "$root/limiar/probe-init"
g++ -std=c++17 -O2 -Wall -Wextra \
    -I"$headers/include" -I"$headers/include/wsl/stubs" \
    "$source" "$headers/src/dxguids.cpp" \
    -L/usr/lib/wsl/lib -ldxcore -ld3d12 \
    -Wl,-rpath,/usr/lib/wsl/lib -o "$root/limiar/gpu-probe"

# Copy only the local Linux runtime components, not the Windows driver store.
printf '%s\n' /usr/lib/wsl/lib/libdxcore.so /usr/lib/wsl/lib/libd3d12.so \
    /usr/lib/wsl/lib/libd3d12core.so > "$temporary/libraries"
find /usr/lib/wsl/drivers -maxdepth 4 -type f -name '*.so*' >> "$temporary/libraries"
# AMD's shader cache loads OpenSSL dynamically, so ldd alone does not find it.
for soname in libssl.so.3 libcrypto.so.3; do
    library=$(ldconfig -p | awk -v name="$soname" '$1 == name && /x86-64/ {print $NF}')
    test -n "$library"
    test -f "$library"
    printf '%s\n' "$library" >> "$temporary/libraries"
done
test "$(wc -l < "$temporary/libraries")" -le 128
while IFS= read -r library; do
    install -D -m 755 -- "$library" "$root$library"
    ldd "$library"
done < "$temporary/libraries" > "$temporary/dependencies"
ldd "$root/limiar/gpu-probe" >> "$temporary/dependencies"
if awk '/not found/ {missing=1} END {exit !missing}' "$temporary/dependencies"; then
    echo "A GPU runtime dependency is missing." >&2
    exit 1
fi
awk '$2 == "=>" && $3 ~ /^\// {print $3} $1 ~ /^\// {print $1}' \
    "$temporary/dependencies" | sort -u > "$temporary/paths"
while IFS= read -r library; do
    install -D -m 755 -- "$library" "$root$library"
done < "$temporary/paths"
size=$(du -sb "$root" | cut -f1)
test "$size" -le 536870912
(
    cd "$root"
    find . -type f -print0 | sort -z | xargs -0 sha256sum
) > "$temporary/manifest"
cp -- "$temporary/manifest" "$root/limiar/gpu-inputs.sha256"
(
    cd "$root"
    find . -print0 | sort -z | busybox cpio -0 -o -H newc 2>/dev/null
) | gzip -n > "$temporary/overlay.gz"
mkdir -p -- "$(dirname "$output")"
(set -C; cat "$base" "$temporary/overlay.gz" > "$output")
sha256sum "$base" "$output"
echo "Contains locally installed runtime/driver binaries. Do not redistribute the generated image."
