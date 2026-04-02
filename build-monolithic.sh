#!/bin/bash
# build-monolithic.sh - Build a single ffmpeg.dll with everything statically linked
#
# Usage: ./build-monolithic.sh [win32|win64]
#
# This script:
# 1. Clones FFmpeg + all dependency libraries from FFmpeg-Builds config
# 2. Builds everything as static libs (.a)
# 3. Links them all together with our wrapper into ONE ffmpeg.dll
#
# Requirements: Ubuntu/Debian with MinGW cross-compiler
#   sudo apt-get install -y gcc-mingw-w64-i686 g++-mingw-w64-i686 \
#     gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64 nasm yasm make git pkg-config

set -euo pipefail

ARCH="${1:-win32}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILDROOT="$SCRIPT_DIR/build-mono"
PREFIX="$BUILDROOT/prefix"
JOBS=$(nproc)

# ── Target config ──
if [[ "$ARCH" == "win64" ]]; then
    CROSS=x86_64-w64-mingw32
    FFMPEG_ARCH=x86_64
    FFMPEG_TARGET=mingw64
else
    CROSS=i686-w64-mingw32
    FFMPEG_ARCH=x86
    FFMPEG_TARGET=mingw32
fi

CC="${CROSS}-gcc"
CXX="${CROSS}-g++"
AR="${CROSS}-ar"
RANLIB="${CROSS}-ranlib"
STRIP="${CROSS}-strip"

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

echo "==> Building monolithic ffmpeg.dll for $ARCH ($CROSS)"
echo "    Build root: $BUILDROOT"
echo "    Jobs: $JOBS"
echo ""

mkdir -p "$BUILDROOT" "$PREFIX"

# ── Step 1: Build common dependencies ──

build_zlib() {
    echo "==> [1/7] Building zlib..."
    cd "$BUILDROOT"
    if [[ ! -d zlib ]]; then
        git clone --depth=1 https://github.com/madler/zlib.git
    fi
    cd zlib
    # zlib's configure doesn't support cross-compile well, use cmake or manual
    make -f win32/Makefile.gcc \
        PREFIX="${CROSS}-" \
        -j"$JOBS" 2>&1 | tail -5
    # Install manually
    cp -f zlib1.dll "$PREFIX/bin/" 2>/dev/null || true
    cp -f libz.dll.a "$PREFIX/lib/" 2>/dev/null || true
    cp -f libz.a "$PREFIX/lib/" 2>/dev/null || true
    cp -f zlib.h zconf.h "$PREFIX/include/" 2>/dev/null || true
    mkdir -p "$PREFIX/lib/pkgconfig"
    cat > "$PREFIX/lib/pkgconfig/zlib.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: zlib
Description: zlib compression library
Version: 1.3
Libs: -L\${libdir} -lz
Cflags: -I\${includedir}
EOF
    echo "    zlib done"
}

build_bzip2() {
    echo "==> [2/7] Building bzip2..."
    cd "$BUILDROOT"
    if [[ ! -d bzip2 ]]; then
        git clone --depth=1 https://sourceware.org/git/bzip2.git || {
            # Fallback: download tarball
            curl -sL https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz | tar xz
            mv bzip2-1.0.8 bzip2
        }
    fi
    cd bzip2
    make -f Makefile-libbz2_so CC="$CC" AR="$AR" RANLIB="$RANLIB" -j"$JOBS" 2>&1 | tail -3 || true
    make libbz2.a CC="$CC" AR="$AR" RANLIB="$RANLIB" -j"$JOBS" 2>&1 | tail -3 || true
    cp -f bzlib.h "$PREFIX/include/" 2>/dev/null || true
    cp -f libbz2.a "$PREFIX/lib/" 2>/dev/null || true
    mkdir -p "$PREFIX/lib/pkgconfig"
    cat > "$PREFIX/lib/pkgconfig/bzip2.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: bzip2
Description: bzip2 compression library
Version: 1.0.8
Libs: -L\${libdir} -lbz2
Cflags: -I\${includedir}
EOF
    echo "    bzip2 done"
}

build_libiconv() {
    echo "==> [3/7] Building libiconv..."
    cd "$BUILDROOT"
    if [[ ! -d libiconv ]]; then
        curl -sL https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.17.tar.gz | tar xz
        mv libiconv-1.17 libiconv
    fi
    cd libiconv
    if [[ ! -f Makefile ]]; then
        ./configure --host="$CROSS" --prefix="$PREFIX" \
            --disable-shared --enable-static \
            --disable-nls --disable-rpath 2>&1 | tail -5
    fi
    make -j"$JOBS" 2>&1 | tail -3
    make install 2>&1 | tail -3
    echo "    libiconv done"
}

build_x264() {
    echo "==> [4/7] Building x264..."
    cd "$BUILDROOT"
    if [[ ! -d x264 ]]; then
        git clone --depth=1 https://code.videolan.org/videolan/x264.git
    fi
    cd x264
    ./configure \
        --host="$CROSS" --cross-prefix="$CROSS-" \
        --prefix="$PREFIX" \
        --enable-static --disable-shared \
        --disable-cli --disable-opencl \
        --bit-depth=all 2>&1 | tail -5
    make -j"$JOBS" 2>&1 | tail -3
    make install 2>&1 | tail -3
    echo "    x264 done"
}

build_x265() {
    echo "==> [5/7] Building x265..."
    cd "$BUILDROOT"
    if [[ ! -d x265 ]]; then
        git clone --depth=1 https://bitbucket.org/multicoreware/x265_git.git x265
    fi
    cd x265/source
    mkdir -p build && cd build
    cmake .. \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DENABLE_SHARED=OFF \
        -DENABLE_CLI=OFF \
        -DCMAKE_C_FLAGS="-O2" \
        -DCMAKE_CXX_FLAGS="-O2" 2>&1 | tail -5
    make -j"$JOBS" 2>&1 | tail -3
    make install 2>&1 | tail -3
    echo "    x265 done"
}

build_fdk_aac() {
    echo "==> [6/7] Building fdk-aac..."
    cd "$BUILDROOT"
    if [[ ! -d fdk-aac ]]; then
        git clone --depth=1 https://github.com/mstorsjo/fdk-aac.git
    fi
    cd fdk-aac
    if [[ ! -f configure ]]; then
        autoreconf -fiv 2>&1 | tail -3
    fi
    if [[ ! -f Makefile ]]; then
        ./configure --host="$CROSS" --prefix="$PREFIX" \
            --disable-shared --enable-static 2>&1 | tail -5
    fi
    make -j"$JOBS" 2>&1 | tail -3
    make install 2>&1 | tail -3
    echo "    fdk-aac done"
}

build_lame() {
    echo "==> [7/7] Building lame..."
    cd "$BUILDROOT"
    if [[ ! -d lame ]]; then
        curl -sL https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz | tar xz
        mv lame-3.100 lame
    fi
    cd lame
    if [[ ! -f Makefile ]]; then
        ./configure --host="$CROSS" --prefix="$PREFIX" \
            --disable-shared --enable-static \
            --disable-frontend --disable-analyzer-hooks 2>&1 | tail -5
    fi
    make -j"$JOBS" 2>&1 | tail -3
    make install 2>&1 | tail -3
    echo "    lame done"
}

build_opus() {
    echo "==> [bonus] Building opus..."
    cd "$BUILDROOT"
    if [[ ! -d opus ]]; then
        git clone --depth=1 https://github.com/xiph/opus.git
    fi
    cd opus
    if [[ ! -f configure ]]; then
        autoreconf -fiv 2>&1 | tail -3
    fi
    if [[ ! -f Makefile ]]; then
        ./configure --host="$CROSS" --prefix="$PREFIX" \
            --disable-shared --enable-static \
            --disable-doc --disable-extra-programs 2>&1 | tail -5
    fi
    make -j"$JOBS" 2>&1 | tail -3
    make install 2>&1 | tail -3
    echo "    opus done"
}

build_vorbis() {
    echo "==> [bonus] Building libvorbis..."
    cd "$BUILDROOT"
    # Build libogg first
    if [[ ! -d libogg ]]; then
        git clone --depth=1 https://github.com/xiph/ogg.git libogg
    fi
    cd libogg
    if [[ ! -f configure ]]; then autoreconf -fiv 2>&1 | tail -3; fi
    if [[ ! -f Makefile ]]; then
        ./configure --host="$CROSS" --prefix="$PREFIX" \
            --disable-shared --enable-static 2>&1 | tail -5
    fi
    make -j"$JOBS" 2>&1 | tail -3
    make install 2>&1 | tail -3

    cd "$BUILDROOT"
    if [[ ! -d libvorbis ]]; then
        git clone --depth=1 https://github.com/xiph/vorbis.git libvorbis
    fi
    cd libvorbis
    if [[ ! -f configure ]]; then autoreconf -fiv 2>&1 | tail -3; fi
    if [[ ! -f Makefile ]]; then
        ./configure --host="$CROSS" --prefix="$PREFIX" \
            --disable-shared --enable-static \
            --disable-doc --disable-examples 2>&1 | tail -5
    fi
    make -j"$JOBS" 2>&1 | tail -3
    make install 2>&1 | tail -3
    echo "    libvorbis done"
}

build_aom() {
    echo "==> [bonus] Building aom (AV1)..."
    cd "$BUILDROOT"
    if [[ ! -d aom ]]; then
        git clone --depth=1 https://aomedia.googlesource.com/aom
    fi
    cd aom
    mkdir -p build && cd build
    cmake .. \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DENABLE_SHARED=OFF \
        -DENABLE_DOCS=OFF \
        -DENABLE_EXAMPLES=OFF \
        -DENABLE_TESTDATA=OFF \
        -DENABLE_TESTS=OFF \
        -DENABLE_TOOLS=OFF \
        -DCMAKE_C_FLAGS="-O2" \
        -DCMAKE_CXX_FLAGS="-O2" 2>&1 | tail -5
    make -j"$JOBS" 2>&1 | tail -3
    make install 2>&1 | tail -3
    echo "    aom done"
}

# ── Build dependencies ──
echo "========================================"
echo " Building dependencies (static libs)"
echo "========================================"

# Essential deps
build_zlib || echo "WARN: zlib failed (may not be needed)"
build_bzip2 || echo "WARN: bzip2 failed"
build_libiconv || echo "WARN: libiconv failed"
build_x264 || echo "WARN: x264 failed"
build_x265 || echo "WARN: x265 failed"
build_fdk_aac || echo "WARN: fdk-aac failed"
build_lame || echo "WARN: lame failed"
build_opus || echo "WARN: opus failed"
build_vorbis || echo "WARN: vorbis failed"

# ── Step 2: Build FFmpeg as static libs ──
echo ""
echo "========================================"
echo " Building FFmpeg (static)"
echo "========================================"

cd "$BUILDROOT"
FFMPEG_REPO="${FFMPEG_REPO:-https://github.com/FFmpeg/FFmpeg.git}"
FFMPEG_BRANCH="${FFMPEG_BRANCH:-release/7.1}"

if [[ ! -d ffmpeg ]]; then
    git clone --depth=1 --branch="$FFMPEG_BRANCH" "$FFMPEG_REPO" ffmpeg
fi

cd ffmpeg
make distclean 2>/dev/null || true

# Build FFmpeg configure flags - disable everything we don't need, enable codecs we want
EXTRA_LIBS="-lstdc++"

./configure \
    --prefix="$PREFIX" \
    --target-os=mingw32 \
    --arch="$FFMPEG_ARCH" \
    --cross-prefix="$CROSS-" \
    --enable-cross-compile \
    --enable-static \
    --disable-shared \
    --enable-gpl \
    --enable-version3 \
    --disable-debug \
    --disable-doc \
    --disable-ffplay \
    --disable-ffprobe \
    --disable-ffmpeg \
    --disable-autodetect \
    --disable-programs \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libfdk-aac \
    --enable-libmp3lame \
    --enable-libopus \
    --enable-libvorbis \
    --pkg-config="pkg-config" \
    --pkg-config-flags="--static" \
    --extra-cflags="-O2 -I$PREFIX/include" \
    --extra-ldflags="-L$PREFIX/lib" \
    --extra-libs="$EXTRA_LIBS" 2>&1 | tail -20

echo "==> Building FFmpeg..."
make -j"$JOBS" V=1 2>&1 | tail -10

# ── Step 3: Build the wrapper and link everything into ffmpeg.dll ──
echo ""
echo "========================================"
echo " Linking monolithic ffmpeg.dll"
echo "========================================"

WRAPPER_C="$SCRIPT_DIR/src/ffmpeg_dll.c"

if [[ ! -f "$WRAPPER_C" ]]; then
    echo "ERROR: Wrapper source not found at $WRAPPER_C"
    exit 1
fi

# Compile wrapper (rename main → ffmpeg_main)
CFLAGS="-O2 -D_ISOC99_SOURCE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE \
    -D_WIN32_WINNT=0x0600 -D__USE_MINGW_ANSI_STDIO=1 -DHAVE_AV_CONFIG_H \
    -I. -Ifftools -I$PREFIX/include"

# Compile all fftools sources as objects
FFTOOLS_OBJS=""
for src in fftools/cmdutils.c fftools/ffmpeg.c fftools/ffmpeg_dec.c \
    fftools/ffmpeg_demux.c fftools/ffmpeg_enc.c fftools/ffmpeg_filter.c \
    fftools/ffmpeg_mux.c fftools/ffmpeg_mux_init.c fftools/ffmpeg_opt.c \
    fftools/ffmpeg_sched.c fftools/ffmpeg_hw.c fftools/objpool.c \
    fftools/sync_queue.c fftools/thread_queue.c; do
    if [[ -f "$src" ]]; then
        obj="${src%.c}.o"
        if [[ "$src" == "fftools/ffmpeg.c" ]]; then
            $CC $CFLAGS -Dmain=ffmpeg_main -c "$src" -o "$obj"
        else
            $CC $CFLAGS -c "$src" -o "$obj"
        fi
        FFTOOLS_OBJS="$FFTOOLS_OBJS $obj"
    fi
done

# Compile wrapper
$CC $CFLAGS -c "$WRAPPER_C" -o fftools/ffmpeg_dll.o
FFTOOLS_OBJS="$FFTOOLS_OBJS fftools/ffmpeg_dll.o"

# Collect all static library archives (.a files)
STATIC_LIBS=""
for lib in libavcodec libavformat libavutil libswscale libswresample libavfilter libavdevice; do
    if [[ -f "${lib}/${lib}.a" ]]; then
        STATIC_LIBS="$STATIC_LIBS ${lib}/${lib}.a"
    fi
done

# Collect external dependency static libs
EXT_LIBS=""
for pc in x264 x265 fdk-aac mp3lame libopus vorbis vorbisenc ogg; do
    LIB_PATH=$(pkg-config --variable=libdir "$pc" 2>/dev/null || echo "$PREFIX/lib")
done

# External static libs to link
for libname in libx264.a libx265.a libfdk-aac.a libmp3lame.a libopus.a \
    libvorbis.a libvorbisenc.a libogg.a libz.a libbz2.a libiconv.a; do
    if [[ -f "$PREFIX/lib/$libname" ]]; then
        EXT_LIBS="$EXT_LIBS $PREFIX/lib/$libname"
    fi
done

echo "FFTOOLS objects: $(echo $FFTOOLS_OBJS | wc -w)"
echo "FFmpeg static libs: $(echo $STATIC_LIBS | wc -w)"
echo "External static libs: $(echo $EXT_LIBS | wc -w)"

# Final link into single ffmpeg.dll
$CC -shared -o "$SCRIPT_DIR/ffmpeg.dll" \
    $FFTOOLS_OBJS \
    $STATIC_LIBS \
    $EXT_LIBS \
    -L$PREFIX/lib \
    -lws2_32 -lbcrypt -lsecur32 -lshlwapi -lstrmiids -luuid -loleaut32 -lole32 \
    -lvfw32 -lwinmm -lpsapi -ladvapi32 -luser32 -lgdi32 \
    -Wl,--out-implib,"$SCRIPT_DIR/libffmpeg.dll.a" \
    -Wl,--export-all-symbols \
    -static-libgcc -static-libstdc++

echo ""
echo "==> Stripping..."
$STRIP --strip-unneeded "$SCRIPT_DIR/ffmpeg.dll" 2>/dev/null || true

echo ""
echo "========================================"
echo " DONE!"
echo "========================================"
ls -lh "$SCRIPT_DIR/ffmpeg.dll"
file "$SCRIPT_DIR/ffmpeg.dll"
echo ""
echo "Output: $SCRIPT_DIR/ffmpeg.dll"
echo "Import lib: $SCRIPT_DIR/libffmpeg.dll.a"
