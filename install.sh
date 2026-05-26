#!/usr/bin/env bash
#
# install.sh - One-command installer for llama.cpp
#
# Clones the repository, builds llama-server, copies models from
# user-specified folders, and generates a models.ini preset file.
#
# Usage:
#   ./install.sh [options]
#
# Options:
#   --backend <cuda|vulkan|metal|hip|sycl|cann|opencl|cpu>
#       Compute backend (default: auto-detect cuda or cpu)
#   --build-type <Release|Debug|RelWithDebInfo>
#       CMake build type (default: Release)
#   --jobs <N>
#       Parallel build jobs (default: 128)
#   --models-source <dir1>,<dir2>,...
#       Comma-separated list of directories to scan for .gguf models.
#       Models are copied to ~/.llama/models/ for fast local loading.
#   --install-dir <dir>
#       Directory for symlinking binaries (default: ~/.bin)
#   --models-dir <dir>
#       Destination directory for copied models (default: ~/.llama/models)
#   --build-dir <dir>
#       Parent directory for build artifacts (default: ~/.llama/build)
#   --repo-url <url>
#       Git repository URL (default: https://github.com/ggml-org/llama.cpp)
#   --repo-branch <branch>
#       Git branch to checkout (default: master)
#   --skip-clone
#       Skip cloning if the source directory already exists
#   --skip-build
#       Skip the build step (clone, configure, build, install). Useful for
#       re-generating models.ini after adding new models.
#   --help
#       Show this help message
#
# Quick install (one-liner):
#   bash -c 'git clone --depth 1 --recurse-submodules https://github.com/ggml-org/llama.cpp && cd llama.cpp && ./install.sh'
#
# After installation, start the server with:
#   llama-server --models-preset ~/.llama/models.ini
#

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────

INSTALL_DIR="${HOME}/.bin"
MODELS_DIR="${HOME}/.llama/models"
BUILD_DIR="${HOME}/.llama/build"
REPO_DIR=""
REPO_URL="https://github.com/ggml-org/llama.cpp"
REPO_BRANCH="master"
BACKEND=""          # empty = auto-detect
BUILD_TYPE="Release"
JOBS=128
MODELS_SOURCE=""
SKIP_CLONE=false
SKIP_BUILD=false

# Detect if install.sh is being run from inside a llama.cpp checkout
IN_REPO=false
if [[ -d .git && -f CMakeLists.txt ]]; then
    IN_REPO=true
    REPO_DIR="$(pwd)"
fi

LLAMA_MODELS_INI="${HOME}/.llama/models.ini"

# ─── Helpers ──────────────────────────────────────────────────────────────────

log_info()  { echo -e "\033[1;34m[install]\033[0m $*"; }
log_ok()    { echo -e "\033[1;32m[  ok  ]\033[0m $*"; }
log_warn()  { echo -e "\033[1;33m[ warn ]\033[0m $*"; }
log_error() { echo -e "\033[1;31m[error ]\033[0m $*" >&2; }

show_help() {
    sed -n '3,/^$/s/^# \?//p' "$0"
    exit 0
}

die() { log_error "$@"; exit 1; }

# Detect and install missing build tools
install_prerequisites() {
    local missing=($@)

    local pkg_manager=""
    if command -v apt-get >/dev/null 2>&1; then
        pkg_manager="apt-get"
    elif command -v dnf >/dev/null 2>&1; then
        pkg_manager="dnf"
    elif command -v yum >/dev/null 2>&1; then
        pkg_manager="yum"
    elif command -v pacman >/dev/null 2>&1; then
        pkg_manager="pacman"
    else
        die "No supported package manager found (apt, dnf, yum, pacman). Install these tools manually: ${missing[*]}"
    fi

    log_info "Installing missing tools via $pkg_manager: ${missing[*]}"
    echo ""

    # Map human-readable names to package names
    local pkgs=()
    for m in "${missing[@]}"; do
        case "$m" in
            git) pkgs+=("git") ;;
            cmake) pkgs+=("cmake") ;;
            "a C++ compiler*") pkgs+=("build-essential") ;;
        esac
    done

    case "$pkg_manager" in
        apt-get)
            export DEBIAN_FRONTEND=noninteractive
            sudo apt-get update -qq
            sudo apt-get install -y "${pkgs[@]}"
            ;;
        dnf|yum)
            sudo $pkg_manager install -y "${pkgs[@]}"
            ;;
        pacman)
            sudo pacman -Syu --noconfirm --needed "${pkgs[@]}"
            ;;
    esac

    # Verify installation
    local still_missing=()
    for m in "${missing[@]}"; do
        if [[ "$m" == "a C++ compiler*" ]]; then
            command -v g++ >/dev/null 2>&1 || command -v clang++ >/dev/null 2>&1 || command -v c++ >/dev/null 2>&1 || still_missing+=("$m")
        else
            command -v "$m" >/dev/null 2>&1 || still_missing+=("$m")
        fi
    done
    if [[ ${#still_missing[@]} -gt 0 ]]; then
        die "Failed to install: ${still_missing[*]}"
    fi
    log_ok "Installed: ${missing[*]}"
    echo ""
}

# Check that required tools are available
check_prerequisites() {
    local missing=()
    command -v git >/dev/null 2>&1 || missing+=("git")
    command -v cmake >/dev/null 2>&1 || missing+=("cmake")
    # Accept any C++ compiler (g++, clang++, c++)
    if ! command -v g++ >/dev/null 2>&1 && ! command -v clang++ >/dev/null 2>&1 && ! command -v c++ >/dev/null 2>&1; then
        missing+=("a C++ compiler (g++, clang++, or c++)")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        if [[ -t 0 ]]; then
            install_prerequisites "${missing[@]}"
        else
            die "Missing required tools: ${missing[*]}"
        fi
    fi
}

# Auto-detect the best available backend
detect_backend() {
    if command -v nvcc >/dev/null 2>&1; then
        echo "cuda"
        return
    fi
    # Check for CUDA toolkit in common locations
    if [[ -f /usr/local/cuda/bin/nvcc ]]; then
        echo "cuda"
        return
    fi
    # macOS defaults to Metal
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "metal"
        return
    fi
    echo "cpu"
}

# Copy models from source directories to MODELS_DIR
# Handles deduplication by filename
copy_models() {
    local IFS=','
    local dirs=($1)
    local count=0
    local skipped=0

    mkdir -p "$MODELS_DIR"

    for dir in "${dirs[@]}"; do
        dir="$(echo "$dir" | xargs)"
        [[ -d "$dir" ]] || continue

        # Copy all .gguf and .mmproj files, preserving relative directory structure
        while IFS= read -r -d '' src_file; do
            local rel_path="${src_file#"$dir"/}"
            local dest_file="${MODELS_DIR}/${rel_path}"
            local dest_parent
            dest_parent="$(dirname "$dest_file")"

            if [[ -f "$dest_file" ]]; then
                # Check if files are identical (by inode or checksum)
                if cmp -s "$src_file" "$dest_file"; then
                    skipped=$((skipped + 1))
                    continue
                fi
                log_warn "Overwriting existing model: $rel_path"
            fi

            mkdir -p "$dest_parent"
            cp -f "$src_file" "$dest_file"
            count=$((count + 1))
            log_info "Copied: $rel_path"
        done < <(find "$dir" -maxdepth 3 \( -name '*.gguf' -o -name '*.mmproj' \) -print0 2>/dev/null)
    done

    if [[ $count -eq 0 && $skipped -gt 0 ]]; then
        log_ok "All $skipped model(s) already up to date."
    elif [[ $count -gt 0 ]]; then
        log_ok "Copied $count model file(s) ($skipped skipped)."
    fi
}

# Generate models.ini from discovered models in MODELS_DIR
#
# INI format (parsed by common_preset_context::load_from_ini):
#   - Keys are environment variable names (LLAMA_ARG_*, __PRESET_*), NOT CLI arg names
#   - [*] section → global preset, cascaded into all other presets
#   - [model_name] section → individual model preset
#   - Boolean keys use truthy strings: "true", "on", "1", etc.
#
# Each model gets its own preset section named after the model file (without extension).
generate_models_ini() {
    mkdir -p "$(dirname "$LLAMA_MODELS_INI")"

    {
        echo "# llama.cpp model presets"
        echo "# Generated by install.sh on $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "# Usage: llama-server --models-preset ${LLAMA_MODELS_INI}"
        echo ""

        # Global preset [*] — settings cascaded into every model preset
        echo "[*]"
        echo "# Global defaults applied to all models"
        echo "LLAMA_ARG_HOST = 127.0.0.1"
        echo "LLAMA_ARG_PORT = 8080"
        echo "LLAMA_ARG_N_GPU_LAYERS = all"
        echo "LLAMA_ARG_FLASH_ATTN = auto"
        echo "LLAMA_ARG_FIT = on"
        echo "LLAMA_ARG_JINJA = true"
        echo "# Force-kill model instance after 60s of graceful shutdown"
        echo "__PRESET_STOP_TIMEOUT = 60"
        echo ""

        local model_count=0

        if [[ -d "$MODELS_DIR" ]]; then
            # Find all root .gguf files (not shards like .gguf.00)
            while IFS= read -r -d '' model_path; do
                local model_name
                model_name="$(basename "$model_path" .gguf)"
                local model_rel
                model_rel="${model_path#"$MODELS_DIR"/}"

                echo "[$model_name]"
                echo "LLAMA_ARG_MODEL = ${MODELS_DIR}/${model_rel}"

                # Check for a companion .mmproj file (multimodal projector)
                if [[ -f "${model_path%.gguf}.mmproj" ]]; then
                    local mmproj_rel="${model_path#"$MODELS_DIR"/}"
                    mmproj_rel="${mmproj_rel%.gguf}.mmproj"
                    echo "LLAMA_ARG_MMPROJ = ${MODELS_DIR}/${mmproj_rel}"
                fi

                echo ""

                model_count=$((model_count + 1))
            done < <(find "$MODELS_DIR" -maxdepth 3 -name '*.gguf' -not -name '*.gguf.*' -print0 2>/dev/null | sort -z)
        fi

        # Also check HF cache directory as fallback
        local hf_cache="${HOME}/.cache/huggingface/hub"
        if [[ -d "$hf_cache" && $model_count -eq 0 ]]; then
            log_warn "No models found in ${MODELS_DIR}. Scanning HF cache..."
            while IFS= read -r -d '' model_path; do
                local model_name
                model_name="$(basename "$(dirname "$model_path")")_$(basename "$model_path" .gguf)"
                # Sanitize name: replace special chars with underscores
                model_name="${model_name//[^a-zA-Z0-9_.-]/_}"

                echo "[$model_name]"
                echo "LLAMA_ARG_MODEL = ${model_path}"
                echo ""

                model_count=$((model_count + 1))
            done < <(find "$hf_cache" -maxdepth 6 -name '*.gguf' -not -name '*.gguf.*' -print0 2>/dev/null | sort -z | { local n=0; while IFS= read -r -d '' line && [[ $n -lt 50 ]]; do printf '%s\0' "$line"; n=$((n+1)); done; })
        fi

    } > "$LLAMA_MODELS_INI"

    local count
    count=$(grep -c '^\[' "$LLAMA_MODELS_INI" 2>/dev/null || true)
    count=$((count - 1))  # subtract [*] global section

    log_ok "Generated ${LLAMA_MODELS_INI} with $count model preset(s)."
}

# ─── Argument parsing ─────────────────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --backend)
                BACKEND="$2"; shift 2 ;;
            --build-type)
                BUILD_TYPE="$2"; shift 2 ;;
            --jobs)
                JOBS="$2"; shift 2 ;;
            --models-source)
                MODELS_SOURCE="$2"; shift 2 ;;
            --install-dir)
                INSTALL_DIR="$2"; shift 2 ;;
            --models-dir)
                MODELS_DIR="$2"; shift 2 ;;
            --build-dir)
                BUILD_DIR="$2"; shift 2 ;;
            --repo-url)
                REPO_URL="$2"; shift 2 ;;
            --repo-branch)
                REPO_BRANCH="$2"; shift 2 ;;
            --skip-clone)
                SKIP_CLONE=true; shift ;;
            --skip-build)
                SKIP_BUILD=true; shift ;;
            --help)
                show_help ;;
            *)
                die "Unknown option: $1  (use --help for usage)" ;;
        esac
    done
}

# ─── Build steps ──────────────────────────────────────────────────────────────

do_clone() {
    # Already inside a llama.cpp repo — no clone needed
    if [[ "$IN_REPO" == true ]]; then
        log_info "Running from inside llama.cpp repo: ${REPO_DIR}"
        return
    fi

    # Default: clone into build directory
    REPO_DIR="${BUILD_DIR}/src"

    if [[ -d "${REPO_DIR}/.git" && "$SKIP_CLONE" == true ]]; then
        log_info "Repo already exists at ${REPO_DIR}, pulling latest..."
        git -C "$REPO_DIR" fetch --tags origin "$REPO_BRANCH"
        git -C "$REPO_DIR" checkout "$REPO_BRANCH"
        git -C "$REPO_DIR" pull || true
        log_ok "Repo updated."
        return
    fi

    if [[ -d "$REPO_DIR" ]]; then
        log_info "Removing stale directory: ${REPO_DIR}"
        rm -rf "$REPO_DIR"
    fi

    log_info "Cloning llama.cpp → ${REPO_DIR}"
    git clone --branch "$REPO_BRANCH" --depth 1 --recurse-submodules "$REPO_URL" "$REPO_DIR"
    log_ok "Clone complete."
}

do_configure() {
    local build_subdir="${BUILD_DIR}/build"

    rm -rf "$build_subdir"

    # Determine backend
    if [[ -z "$BACKEND" ]]; then
        BACKEND="$(detect_backend)"
        log_info "Auto-detected backend: ${BACKEND}"
    fi

    local -a cmake_opts=(
        -B "$build_subdir"
        -S "$REPO_DIR"
        "-DCMAKE_BUILD_TYPE=${BUILD_TYPE}"
        -DLLAMA_OPENSSL=ON
        -DLLAMA_BUILD_TESTS=OFF
        -DLLAMA_BUILD_EXAMPLES=ON
        -DLLAMA_BUILD_SERVER=ON
        -DLLAMA_NATIVE=ON
    )

    # Backend-specific flags
    case "$BACKEND" in
        cuda)
            cmake_opts+=(
                -DGGML_CUDA=ON
                -DGGML_CUDA_ENABLE_UNIFIED_MEMORY=ON
            )
            # Locate nvcc
            if [[ -z "${CUDACXX:-}" ]]; then
                if [[ -f /usr/local/cuda/bin/nvcc ]]; then
                    export CUDACXX="/usr/local/cuda/bin/nvcc"
                elif command -v nvcc >/dev/null 2>&1; then
                    export CUDACXX="nvcc"
                fi
            fi
            local cuda_dir
            cuda_dir="$(dirname "$(dirname "${CUDACXX:-/usr/local/cuda/bin/nvcc}")")"
            if [[ -n "${CMAKE_PREFIX_PATH:-}" ]]; then
                export CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH}:${cuda_dir}"
            else
                export CMAKE_PREFIX_PATH="${cuda_dir}"
            fi
            ;;
        vulkan)
            cmake_opts+=(-DGGML_VULKAN=ON) ;;
        metal)
            cmake_opts+=(-DGGML_METAL=ON) ;;
        hip)
            cmake_opts+=(-DGGML_HIP=ON) ;;
        sycl)
            cmake_opts+=(-DGGML_SYCL=ON) ;;
        cann)
            cmake_opts+=(-DGGML_CANN=ON) ;;
        opencl)
            cmake_opts+=(-DGGML_OPENCL=ON) ;;
        cpu)
            # CPU-only — no GPU backend flags
            ;;
        *)
            die "Invalid backend: $BACKEND" ;;
    esac

    # OpenSSL hints (conda / system)
    if [[ -d "${HOME}/.conda" ]]; then
        export OPENSSL_ROOT_DIR="${HOME}/.conda"
        export OPENSSL_LIBRARIES="${HOME}/.conda/lib"
        export PKG_CONFIG_PATH="${HOME}/.conda/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    fi

    log_info "Configuring (backend=${BACKEND}, type=${BUILD_TYPE})..."
    cmake "${cmake_opts[@]}"
    log_ok "Configuration complete."
}

do_build() {
    local build_subdir="${BUILD_DIR}/build"

    log_info "Building with ${JOBS} parallel jobs..."
    cmake --build "$build_subdir" --config "$BUILD_TYPE" -j "$JOBS"
    log_ok "Build complete."
}

do_install() {
    local build_bin="${BUILD_DIR}/build/bin"

    mkdir -p "$INSTALL_DIR"

    # Binaries to install
    local -a binaries=(llama-server llama-cli llama-quantize)

    for bin in "${binaries[@]}"; do
        local src="${build_bin}/${bin}"
        if [[ -f "$src" ]]; then
            local dest="${INSTALL_DIR}/${bin}"
            # Remove stale symlink or overwrite existing
            rm -f "$dest"
            ln -sf "$src" "$dest"
            log_info "Linked: ${bin} → ${dest}"
        else
            log_warn "Binary not found (skipping): $bin"
        fi
    done

    # Copy shared libraries so symlinks resolve correctly
    # Linux uses .so, macOS uses .dylib
    local lib_ext="so"
    case "$(uname)" in
        Darwin) lib_ext="dylib" ;;
    esac

    local -a lib_patterns=(
        "$build_bin"/libllama.${lib_ext}*
        "$build_bin"/libggml*.${lib_ext}*
    )
    for lib in "${lib_patterns[@]}"; do
        if [[ -f "$lib" ]]; then
            cp -f "$lib" "$INSTALL_DIR/"
        fi
    done

    log_ok "Installed to ${INSTALL_DIR}/"
}

do_models() {
    if [[ -z "$MODELS_SOURCE" ]]; then
        log_warn "No --models-source specified. Skipping model copy."
        log_info "To add models later, run:"
        log_info "  $0 --models-source /path/to/models --skip-clone"
        return
    fi

    log_info "Copying models from: ${MODELS_SOURCE}"
    copy_models "$MODELS_SOURCE"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    check_prerequisites

    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║           llama.cpp One-Command Installer            ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║  Backend:      ${BACKEND:-auto}"
    echo "║  Build type:   ${BUILD_TYPE}"
    echo "║  Jobs:         ${JOBS}"
    echo "║  Repo dir:     ${REPO_DIR:-will be cloned}"
    echo "║  Install dir:  ${INSTALL_DIR}"
    echo "║  Models dir:   ${MODELS_DIR}"
    echo "║  Models src:   ${MODELS_SOURCE:-(none)}"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""

    if [[ "$SKIP_BUILD" == true ]]; then
        log_info "Skipping build (--skip-build)."
    else
        do_clone
        do_configure
        do_build
        do_install
    fi

    echo ""
    do_models

    echo ""
    log_info "Generating model presets..."
    generate_models_ini

    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║                   Installation Complete              ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║  Binaries:   ${INSTALL_DIR}/"
    echo "║  Models:     ${MODELS_DIR}/"
    echo "║  Presets:    ${LLAMA_MODELS_INI}"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║  Start server:"
    echo "║    llama-server --models-preset ${LLAMA_MODELS_INI}"
    echo "║"
    echo "║  Interactive CLI:"
    echo "║    llama-cli --model ${MODELS_DIR}/<your-model.gguf>"
    echo "╚══════════════════════════════════════════════════════╝"
}

main "$@"
