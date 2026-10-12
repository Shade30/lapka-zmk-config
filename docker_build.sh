#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$PWD}"
VOLUME="${VOLUME:-zmk-$(basename "$REPO")-west}"
OUT="${OUT:-$REPO/build}"
IMAGE="${IMAGE:-zmkfirmware/zmk-build-arm:stable}"

mkdir -p "$OUT"
docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME" >/dev/null

read -r -d '' SCRIPT <<'INNER' || true
set -euo pipefail

rm -rf /work/zmk-config/config
mkdir -p /work/zmk-config/config
cp -R /repo/config/. /work/zmk-config/config/

cd /work/zmk-config
[ -d .west ] || west init -l config
[ -n "${NO_UPDATE:-}" ] || west update --fetch-opt=--filter=tree:0
west zephyr-export

python3 - "$@" >/tmp/targets <<'PY'
import os, pathlib, sys, yaml

filters = [a.lower() for a in sys.argv[1:]]
extra_snippet = os.environ.get("SNIPPET", "")

if os.environ.get("BOARD"):
    entries = [{"board": os.environ["BOARD"], "shield": os.environ.get("SHIELD", "")}]
else:
    entries = (yaml.safe_load(pathlib.Path("/repo/build.yaml").read_text()) or {}).get("include") or []

for entry in entries:
    board = str(entry["board"])
    shield = str(entry.get("shield") or "")
    if filters and not any(f in f"{board} {shield}".lower() for f in filters):
        continue
    snippet = " ".join(s for s in (str(entry.get("snippet") or ""), extra_snippet) if s)
    cmake = str(entry.get("cmake-args") or "")
    name = str(entry.get("artifact-name") or
               "-".join(p for p in (shield.replace(" ", "+"), board) if p).replace("/", "_"))
    if extra_snippet:
        name += "-" + extra_snippet.replace(" ", "+")
    print("\x1f".join((board, shield, snippet, cmake, name)))
PY

if [ ! -s /tmp/targets ]; then
    echo "No target matched the filter: $*" >&2
    exit 1
fi

while IFS=$'\x1f' read -r board shield snippet cmake name; do
    echo "=== $name"
    build_args=(-s zmk/app -d "/work/build/$name" -p "${PRISTINE:-auto}" -b "$board")
    for s in $snippet; do
        build_args+=(-S "$s")
    done
    cmake_args=(-DZMK_CONFIG=/work/zmk-config/config -DZMK_EXTRA_MODULES=/repo)
    if [ -n "$shield" ]; then
        cmake_args+=(-DSHIELD="$shield")
    fi
    if [ -n "$cmake" ]; then
        cmake_args+=($cmake)
    fi
    west build "${build_args[@]}" -- "${cmake_args[@]}"
    for ext in uf2 hex bin; do
        if [ -f "/work/build/$name/zephyr/zmk.$ext" ]; then
            cp "/work/build/$name/zephyr/zmk.$ext" "/out/$name.$ext"
            break
        fi
    done
done < /tmp/targets

chown -R "$OUT_OWNER" /out
INNER

docker run --rm \
  -e BOARD -e SHIELD -e SNIPPET -e PRISTINE -e NO_UPDATE -e OUT_OWNER="$(id -u):$(id -g)" \
  -v "$VOLUME":/work -v "$REPO":/repo:ro -v "$OUT":/out \
  "$IMAGE" bash -c "$SCRIPT" zmk-build "$@"

ls -la "$OUT"
