#!/usr/bin/env bash

base=$(dirname "$(readlink -f "$0")")
install=$base/install

set -euo pipefail

# Set specific tag (e.g., "llvmorg-19.1.0") to override auto-detection.
llvm_override_version=""
# Set specific tag (e.g., "1.82.0") to override auto-detection.
rust_override_version=""

function parse_parameters() {
    while (($#)); do
        case $1 in
            all | binutils | deps | fixup | llvm | pack | revision | rust) action=$1 ;;
            *) exit 33 ;;
        esac
        shift
    done
}

function do_all() {
    do_deps
    get_latest_llvm_tag
    get_latest_rust_tag
    do_llvm
    do_binutils
    do_rust
    do_fixup
    do_pack
    do_revision
}

function do_deps() {
    [[ -z ${GITHUB_ACTIONS:-} ]] && return 0
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
        pkg-config \
        texinfo \
        xz-utils \
        zlib1g-dev \
        patchelf
}

function get_latest_llvm_tag() {
    [[ -n "${llvm_version:-}" ]] && return 0

    if [[ -n "$llvm_override_version" ]]; then
        echo "Using hardcoded version: $llvm_override_version"
        llvm_version="$llvm_override_version"
        return 0
    fi

    echo "Fetching latest LLVM release tag from GitHub Releases..."
    llvm_version=$(curl -fsSL --retry 3 --retry-delay 5 \
        https://api.github.com/repos/llvm/llvm-project/releases/latest |
        grep '"tag_name"' |
        sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

    if [[ -z "$llvm_version" ]]; then
        echo "Error: Could not fetch latest LLVM version from GitHub Releases." >&2
        exit 1
    fi

    echo "Resolved LLVM version: $llvm_version"
}

function get_latest_rust_tag() {
    [[ -n "${rust_version:-}" ]] && return 0

    if [[ -n "$rust_override_version" ]]; then
        echo "Using hardcoded version: $rust_override_version"
        rust_version="$rust_override_version"
        return 0
    fi

    echo "Fetching latest Rust release tag from GitHub Releases..."
    rust_version=$(curl -fsSL --retry 3 --retry-delay 5 \
        https://api.github.com/repos/rust-lang/rust/releases/latest |
        grep '"tag_name"' |
        sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

    if [[ -z "$rust_version" ]]; then
        echo "Error: Could not fetch latest Rust version from GitHub Releases." >&2
        exit 1
    fi

    echo "Resolved Rust version: $rust_version"
}

function do_llvm() {
    get_latest_llvm_tag

    extra_args=()
    [[ -n ${GITHUB_ACTIONS:-} ]] && extra_args+=(--no-ccache)

    echo "Building $llvm_version..."
    "$base"/build-llvm.py \
        --vendor-string 'llvmorg' \
        --targets AArch64 ARM X86 \
        --projects clang lld compiler-rt polly \
        --lto thin \
        --quiet-cmake \
        --no-update \
        --ref "$llvm_version" \
        --shallow-clone \
        --multicall \
        --install-folder "$install" \
        "${extra_args[@]}"
}

function do_binutils() {
    "$base"/build-binutils.py \
        --install-folder "$install" \
        --show-build-commands \
        --targets aarch64 arm x86_64
}

function do_rust() {
    get_latest_rust_tag

    echo "Building Rust $rust_version..."
    "$base"/build-rust.py \
        --llvm-install-folder "$install" \
        --install-folder "$install" \
        --ref "$rust_version" \
        --vendor-string 'rust' \
        --no-update
}

function do_fixup() {
    echo "Removing unused products..."
    rm -rf "$install"/include
    find "$install" -type f \( -name '*.a' -o -name '*.la' \) -delete

    echo "Stripping remaining products..."
    find "$install" -type f -exec sh -c 'file -b -- "$1" | grep -q "not stripped"' _ {} \; \
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
            patchelf --set-rpath "\$ORIGIN/../lib" "$1"
        elif echo "$file_type" | grep -q "shared object"; then
            echo "  -> Patching library: $1"
            patchelf --set-rpath "\$ORIGIN" "$1"
        fi
    ' _ {} \;
}

function do_pack() {
    echo "Packing build into archive..."
    tar -zcf clang.tar.gz \
        --owner=0 --group=0 --numeric-owner \
        -C "$install" .

    echo "Archive size: $(du -sh clang.tar.gz)"
    echo "Number of files: $(tar -tf clang.tar.gz | wc -l)"
}

function do_revision() {
    echo "Generating revision info..."
    build_date=$(date -u +"%Y-%m-%d")

    if [[ -f "$install/bin/clang" ]]; then
        clang_version=$("$install/bin/clang" --version | head -n1 | sed 's/.*version //;s/ .*//')
    else
        clang_version="N/A"
    fi

    binutils_version=$(grep "LATEST_BINUTILS_RELEASE" "$base/build-binutils.py" | sed -n 's/.*(\([0-9]\+\)[^0-9]*\([0-9]\+\)[^0-9]*\([0-9]\+\).*/\1.\2.\3/p')

    if [[ -f "$install/bin/rustc" ]]; then
        rust_version=$("$install/bin/rustc" --version | awk '{print $2}')
    else
        rust_version="N/A"
    fi

    cat <<EOF >"$base/revision_info.md"
- Build Date: $build_date
- Clang Version: $clang_version
- Rust Version: $rust_version
- Binutils Version: $binutils_version
EOF

    if [[ -n ${GITHUB_ACTIONS:-} ]]; then
        {
            echo "BUILD_DATE=$build_date"
            echo "CLANG_VERSION=$clang_version"
            echo "RUST_VERSION=$rust_version"
            echo "BINUTILS_VERSION=$binutils_version"
        } >>"$GITHUB_ENV"
    fi
    cat "$base/revision_info.md"
}

parse_parameters "$@"
do_"${action:=all}"
