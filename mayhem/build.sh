#!/usr/bin/env bash
#
# mayhem/build.sh — build h2o's four libFuzzer harnesses (fuzz/driver*.cc, as upstream's CMake
# defines them under BUILD_FUZZER), a run-once standalone reproducer per harness, and the
# project's own unit-test binary (t-00unit-evloop.t) with NORMAL flags for mayhem/test.sh.
#
# Runs as `mayhem` in /mayhem; re-runnable and offline (all deps are apt -dev packages, and
# h2o's bundled deps/ are in-tree).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
OUT="$SRC"
TARGETS="h2o-fuzzer-http1 h2o-fuzzer-http2 h2o-fuzzer-http3 h2o-fuzzer-url"

# A cached CMakeCache.txt from a run that resolved the compiler differently (ccache masquerade vs
# plain PATH) makes cmake wipe the cache AND drop the -D options on the reconfigure pass, silently
# producing a tree without the fuzzer targets. Always configure from a fresh cache.
rm -f build/normal/CMakeCache.txt build/fuzz/CMakeCache.txt

# ---------------------------------------------------------------------------------------------
# 1) Test suite first, NORMAL flags (separate tree; build/ is gitignored upstream).
# ---------------------------------------------------------------------------------------------
cmake -S . -B build/normal -G Ninja \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_BUILD_TYPE=Debug -DWITH_MRUBY=OFF -DWITH_DTRACE=OFF \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build build/normal -j"$MAYHEM_JOBS" --target t-00unit-evloop.t

# ---------------------------------------------------------------------------------------------
# 2) Sanitized fuzz build. Upstream's OSS_FUZZ switch links `-lFuzzingEngine` and adds no
#    engine flags of its own, so we supply the engine as a static archive found via
#    LIBRARY_PATH: libFuzzer for the fuzzers, the run-once driver for the standalone binaries.
# ---------------------------------------------------------------------------------------------
ENG="$SRC/build/engine"
mkdir -p "$ENG/fuzzer" "$ENG/standalone"
cp "$($CC -print-file-name=libclang_rt.fuzzer-x86_64.a)" "$ENG/fuzzer/libFuzzingEngine.a"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$ENG/standalone_main.o"
rm -f "$ENG/standalone/libFuzzingEngine.a"
ar rcs "$ENG/standalone/libFuzzingEngine.a" "$ENG/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$ENG/lsan_off.o"

# UBSan pointer-overflow and nonnull-attribute are relaxed for the fuzz build: lib/http3/common.c:1416
# (h2o_http3_update_recvbuf) does `NULL + 0` and memcpy(NULL, src, 0) on every empty input, which is
# UB in C but harmless, and halting on it would stop the h3 harness at its first (empty) input.
# ASan and every other UBSan check stay halting.
COV="-fsanitize=fuzzer-no-link -fno-sanitize=pointer-overflow,nonnull-attribute"
export LIBRARY_PATH="$ENG/fuzzer"
cmake -S . -B build/fuzz -G Ninja \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_BUILD_TYPE=Debug -DWITH_MRUBY=OFF -DWITH_DTRACE=OFF \
    -DBUILD_FUZZER=ON -DOSS_FUZZ=ON \
    -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $COV" \
    -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $COV"
# shellcheck disable=SC2086
cmake --build build/fuzz -j"$MAYHEM_JOBS" --target $TARGETS

# ---------------------------------------------------------------------------------------------
# 3) Final links: replay cmake's own link line per target with lsan_off.o added, once against
#    libFuzzer (-> /mayhem/<t>) and once against the run-once driver (-> /mayhem/<t>-standalone).
# ---------------------------------------------------------------------------------------------
relink() {  # relink <target> <libdir> <output>
    local line
    line="$(ninja -C build/fuzz -t commands "$1" | tail -n 1)"
    line="${line# : && }"; line="${line% && :}"
    case "$line" in *" -o $1 "*) ;; *) echo "unexpected link line for $1: $line" >&2; exit 1 ;; esac
    line="${line/ -o $1 / $ENG/lsan_off.o -o $3 }"
    (cd build/fuzz && LIBRARY_PATH="$2" bash -c "$line")
}
for t in $TARGETS; do
    relink "$t" "$ENG/fuzzer" "$OUT/$t"
    relink "$t" "$ENG/standalone" "$OUT/$t-standalone"
done
ls -l $(for t in $TARGETS; do echo "$OUT/$t" "$OUT/$t-standalone"; done)
