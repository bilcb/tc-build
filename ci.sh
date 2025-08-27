#!/usr/bin/env bash

base=$(cd "$(dirname "$0")" && pwd)
install=$base/install
version=llvmorg-21.1.0

set -euo pipefail

function do_all() {
    do_deps
    do_binutils
    do_llvm
    do_fixup
    do_pack
    do_revision
}

function do_binutils() {
    "$base"/build-binutils.py \
        --install-folder "$install" \
        --show-build-commands \
        --targets aarch64 arm x86_64
}

function do_deps() {
    # We only run this when running on GitHub Actions
    [[ -z ${GITHUB_ACTIONS:-} ]] && return 0

    # Refresh mirrorlist to avoid dead mirrors
    sudo apt-get update -y

    sudo apt-get install -y --no-install-recommends \
        bc \
        bison \
        ca-certificates \
        clang \
        cmake \
        curl \
        file \
        flex \
        gcc \
        g++ \
        git \
        libelf-dev \
        libssl-dev \
        lld \
        make \
        ninja-build \
        python3 \
        texinfo \
        xz-utils \
        zlib1g-dev \
        patchelf
}

function do_llvm() {
    extra_args=()
    [[ -n ${GITHUB_ACTIONS:-} ]] && extra_args+=(--no-ccache)

    "$base"/build-llvm.py \
        --vendor-string "llvmorg" \
        --targets AArch64 ARM X86 \
        --defines "LLVM_PARALLEL_COMPILE_JOBS=$(nproc) LLVM_PARALLEL_LINK_JOBS=$(nproc) CMAKE_C_FLAGS=-O3 CMAKE_CXX_FLAGS=-O3 LLVM_USE_LINKER=lld LLVM_ENABLE_LLD=ON" \
        --lto thin \
        --no-ccache \
        --quiet-cmake \
        --ref "$version" \
        --shallow-clone \
        --no-update \
        --install-folder "$install" \
        "${extra_args[@]}"
}

function do_fixup() {
    echo "Removing unused products..."
    rm -rf "$install"/include
    find "$install" -type f \( -name '*.a' -o -name '*.la' \) -delete

    echo "Stripping remaining products..."
    find "$install" -type f -exec sh -c 'file -b "$1" | grep -q "not stripped"' _ {} \; \
        -print0 | xargs -0 --no-run-if-empty strip --strip-unneeded

    echo "Patching rpaths for portability..."
    find "$install" -type f -exec sh -c '
        # Call `file` only once and store its output.
        # Use `--` to protect against filenames that start with a dash.
        file_type=$(file -b -- "$1")

        # Check if it is an ELF file at all.
        if ! echo "$file_type" | grep -q "ELF"; then
            exit 0
        fi

        # Apply RPATH based on the specific ELF type.
        if echo "$file_type" | grep -q "interpreter"; then
            echo "  -> Patching executable: $1"
            patchelf --set-rpath "\$ORIGIN/../lib" -- "$1"
        elif echo "$file_type" | grep -q "shared object"; then
            echo "  -> Patching library: $1"
            patchelf --set-rpath "\$ORIGIN" -- "$1"
        fi
    ' _ {} \;
}

function do_pack() {
    echo "Packing build into archive..."
    tar -zcf clang.tar.gz \
        --owner=0 --group=0 --numeric-owner \
        -C "$install" .

    echo "Archive size:" $(du -sh clang.tar.gz)
    echo "Number of files:" $(tar -tf clang.tar.gz | wc -l)
}

function do_revision() {
    echo "Generating revision info..."
    build_date=$(date -u +"%Y-%m-%d")
    clang_version="${version#llvmorg-}"
    binutils_version=$(grep "LATEST_BINUTILS_RELEASE" "$base/build-binutils.py" | sed -n 's/.*(\([0-9]\+\)[^0-9]*\([0-9]\+\)[^0-9]*\([0-9]\+\).*/\1.\2.\3/p')
    revision_file="$base/revision_info.md"
    cat <<EOF > "$revision_file"
- Build Date: $build_date
- Clang Version: $clang_version
- Binutils Version: $binutils_version
EOF

    echo "BUILD_DATE=$build_date" >> $GITHUB_ENV
    echo "CLANG_VERSION=$clang_version" >> $GITHUB_ENV
    echo "BINUTILS_VERSION=$binutils_version" >> $GITHUB_ENV
    echo "Revision info saved to $revision_file"
    cat "$revision_file"
}

action="${1:-all}"
shift || true
do_"$action" "$@"
