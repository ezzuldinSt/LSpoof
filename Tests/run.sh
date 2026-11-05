#!/usr/bin/env bash
# Runs the host tests for the parts of LSpoof that don't need UIKit: the motion
# model, the track codecs, GPX/TCX/FIT reading and writing, map links, and the saved
# route format.
#
#   Tests/run.sh          # all tests
#   Tests/run.sh c        # only the C tests (no Objective-C toolchain needed)
#
# The C tests need a C compiler. The Objective-C tests need Foundation: on macOS
# that is the system one, and on Linux it is GNUstep (apt install gnustep-devel
# libblocksruntime-dev clang).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
CC="${CC:-cc}"
FAILED=0

run() {
    local name="$1"
    echo "== $name"
    if ! "$OUT/$name"; then FAILED=1; fi
}

SANITIZE=""
if echo 'int main(void){return 0;}' | "$CC" -x c -fsanitize=address,undefined -o "$OUT/probe" - 2>/dev/null; then
    SANITIZE="-fsanitize=address,undefined -fno-omit-frame-pointer"
fi

# shellcheck disable=SC2086
"$CC" -std=c11 -O1 -g -Wall -Wextra $SANITIZE -o "$OUT/motion_tests" \
    Tests/motion_tests.c Source/RouteMotion.c Source/RouteGeometry.c -lm
run motion_tests
# shellcheck disable=SC2086
"$CC" -std=c11 -O1 -g -Wall -Wextra $SANITIZE -o "$OUT/codec_tests" \
    Tests/codec_tests.c Source/LSTrackCodec.c -lm
run codec_tests

if [ "${1:-all}" = "c" ]; then exit "$FAILED"; fi

build_objc() {
    local out="$1"; shift
    if [ "$(uname)" = "Darwin" ]; then
        clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter -o "$out" "$@" -framework Foundation -lm
    else
        if ! command -v gnustep-config >/dev/null; then
            echo "gnustep-config not found; install GNUstep or run 'Tests/run.sh c'." >&2
            exit 2
        fi
        # GNUstep's headers look for objc/blocks_runtime.h, which the gcc runtime doesn't ship.
        mkdir -p "$OUT/shim/objc"
        echo '#include <Block.h>' > "$OUT/shim/objc/blocks_runtime.h"
        local gccinc
        gccinc="$(gcc -print-file-name=include 2>/dev/null || true)"
        # shellcheck disable=SC2046
        clang $(gnustep-config --objc-flags) -fobjc-runtime=gcc -fblocks -I"$OUT/shim" ${gccinc:+-I"$gccinc"} \
            -Wall -Wextra -Wno-unused-parameter -o "$out" "$@" $(gnustep-config --base-libs) -lBlocksRuntime -lm
    fi
}

build_objc "$OUT/trackio_tests" Tests/trackio_tests.m Source/LSTrackIO.m Source/LSTrackCodec.c
run trackio_tests
build_objc "$OUT/maplinks_tests" Tests/maplinks_tests.m Source/LSMapLinks.m
run maplinks_tests
build_objc "$OUT/routearchive_tests" Tests/routearchive_tests.m Source/LSRouteArchive.m Source/LSRouteStore.m
run routearchive_tests

exit "$FAILED"
