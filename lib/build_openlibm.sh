#!/usr/bin/env bash
# Builds the provider's payload from pinned inputs: OpenLibm at the commit Yggdrasil builds for
# native OpenLibm_jll 0.8.7, with wasi-sdk 34's clang, for wasm64 (LP64), freestanding.
# usage: build_openlibm.sh <work dir> <out dir>
set -eu
WORK=$1; OUT=$2
SDK_URL=https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-34/wasi-sdk-34.0-x86_64-linux.tar.gz
SDK_SHA256=b761e3a0721dbae9c09a0059e5fdb2bf917d1b4a8a7b430fb3b5aafb0984b2c4
OPENLIBM_COMMIT=9fbeafcd4f1b6ef6aa3946c1c8faead50f38a94d
mkdir -p "$WORK" "$OUT/lib/wasm64" "$OUT/share"
cd "$WORK"
[ -f sdk.tgz ] || curl -sSL -o sdk.tgz "$SDK_URL"
echo "$SDK_SHA256  sdk.tgz" | sha256sum -c -
[ -d wasi-sdk-34.0-x86_64-linux ] || tar xzf sdk.tgz
SDK=$PWD/wasi-sdk-34.0-x86_64-linux
[ -d openlibm ] || git clone -q https://github.com/JuliaMath/openlibm.git
git -C openlibm fetch -q origin "$OPENLIBM_COMMIT"
git -C openlibm checkout -q -f "$OPENLIBM_COMMIT"; git -C openlibm clean -qfdx
cd openlibm
# OpenLibm's wasm32 arch, retargeted: its freestanding headers state ILP32
sed -i 's/--target=wasm32-unknown-unknown/--target=wasm64-unknown-unknown/' Make.inc
sed -i -e 's/typedef unsigned int       uintptr_t;/typedef unsigned long      uintptr_t;/' \
       -e 's/typedef int                intptr_t;/typedef long               intptr_t;/' \
       -e 's/sizeof (uintptr_t) == 4/sizeof (uintptr_t) == 8/' wasm32/stdint.h
sed -i -e 's/#define LONG_MIN INT32_MIN/#define LONG_MIN INT64_MIN/' \
       -e 's/#define LONG_MAX INT32_MAX/#define LONG_MAX INT64_MAX/' wasm32/limits.h
make -j2 ARCH=wasm32 CC="$SDK/bin/clang" AR="$SDK/bin/llvm-ar" SOURCE_DATE_EPOCH=0 libopenlibm.a >/dev/null 2>"$WORK/build.log"
cp libopenlibm.a "$OUT/lib/wasm64/libopenlibm.a"
sha256sum "$OUT/lib/wasm64/libopenlibm.a"
