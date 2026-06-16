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
#       Parallel build jobs (default: auto-detect CPU cores, capped at 32)
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
#       Git repository URL (default: https://github.sec.samsung.net/aman-walia/llama.cpp)
#   --repo-branch <branch>
#       Git branch to checkout (default: master)
#   --skip-clone
#       Skip cloning if the source directory already exists
#   --skip-build
#       Skip the build step (clone, configure, build, install). Useful for
#       re-generating models.ini after adding new models.
#   --clean
#       Force a clean build by removing the build directory before configuring.
#   --help
#       Show this help message
#
# Quick install (one-liner):
#   bash -c 'git clone --depth 1 --recurse-submodules https://github.sec.samsung.net/aman-walia/llama.cpp && cd llama.cpp && ./install.sh'
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
REPO_URL="https://github.sec.samsung.net/aman-walia/llama.cpp"
REPO_BRANCH="master"
BACKEND=""          # empty = auto-detect
BUILD_TYPE="Release"
JOBS=0              # 0 = auto-detect CPU cores (capped at 32)
MODELS_SOURCE="/netapp/output/aman.walia/share/models"
SKIP_CLONE=false
SKIP_BUILD=false
CLEAN_BUILD=false

# Detect if install.sh is being run from inside a llama.cpp checkout
IN_REPO=false
if [[ -d .git && -f CMakeLists.txt ]]; then
    IN_REPO=true
    REPO_DIR="$(pwd)"
fi

LLAMA_MODELS_INI="${HOME}/.llama/models.ini"

# ─── Helpers ──────────────────────────────────────────────────────────────────

log_info()  { echo -e "\033[1;34m[install]\033[0m $*" >&2; }
log_ok()    { echo -e "\033[1;32m[  ok  ]\033[0m $*" >&2; }
log_warn()  { echo -e "\033[1;33m[ warn ]\033[0m $*" >&2; }
log_error() { echo -e "\033[1;31m[error ]\033[0m $*" >&2; }

show_help() {
    sed -n '3,/^$/s/^# \?//p' "$0"
    exit 0
}

die() { log_error "$@"; exit 1; }

# Auto-detect parallel jobs based on CPU cores, capped at 32
# to avoid I/O contention on most systems
auto_detect_jobs() {
    local cores=0
    if command -v nproc >/dev/null 2>&1; then
        cores=$(nproc)
    elif command -v sysctl >/dev/null 2>&1 && sysctl -a 2>/dev/null | grep -q hw.ncpu; then
        cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 0)
    elif [[ -f /proc/cpuinfo ]]; then
        cores=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 0)
    fi

    # Cap at 32 to avoid excessive I/O contention
    if [[ $cores -gt 32 ]]; then
        cores=32
    fi

    # Ensure at least 2 jobs
    if [[ $cores -lt 2 ]]; then
        cores=2
    fi

    echo "$cores"
}

# Compute a hash of the current build configuration
compute_config_hash() {
    local config="BACKEND=${BACKEND:-unset}"
    config+="|BUILD_TYPE=${BUILD_TYPE}"
    config+="|CMAKE_OPTS=${*:-}"
    echo -n "$config" | md5sum 2>/dev/null | cut -d' ' -f1 || echo -n "$config" | cksum | cut -d' ' -f1
}

# Check if build directory needs to be cleaned due to config changes
needs_clean() {
    local build_subdir="$1"
    local config_file="${build_subdir}/.llama_install_config"
    local current_hash
    current_hash=$(compute_config_hash "$@")

    # If --clean is specified, always clean
    if [[ "$CLEAN_BUILD" == true ]]; then
        return 0
    fi

    # If config file doesn't exist, clean for first build
    if [[ ! -f "$config_file" ]]; then
        return 0
    fi

    # If hash changed, clean
    local stored_hash
    stored_hash=$(cat "$config_file" 2>/dev/null || echo "")
    if [[ "$current_hash" != "$stored_hash" ]]; then
        log_info "Build configuration changed — cleaning build directory"
        return 0
    fi

    # No clean needed — incremental build is possible
    log_info "Configuration unchanged — using incremental build"
    return 1
}

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
            "a C++ compiler"*) pkgs+=("g++") ;;
        esac
    done

    case "$pkg_manager" in
        apt-get)
            export DEBIAN_FRONTEND=noninteractive
            sudo apt-get update -qq
            sudo apt-get install -y --reinstall "${pkgs[@]}" 2>/dev/null || sudo apt-get install -y "${pkgs[@]}"
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
        if [[ "$m" == *"C++ compiler"* ]]; then
            # Check both PATH and common locations
            if ! command -v g++ >/dev/null 2>&1 && ! command -v clang++ >/dev/null 2>&1 && ! command -v c++ >/dev/null 2>&1; then
                if [[ -x /usr/bin/g++ ]] || [[ -x /usr/local/bin/g++ ]]; then
                    log_info "Found g++ at /usr/bin, adding to PATH"
                    export PATH="/usr/bin:/usr/local/bin:$PATH"
                else
                    still_missing+=("$m")
                fi
            fi
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
    # Ensure build-essential is installed on Debian/Ubuntu systems
    if [[ -f /etc/debian_version ]]; then
        if ! dpkg -s build-essential >/dev/null 2>&1; then
            log_info "Installing build-essential (C++ compiler, make, etc.)"
            sudo apt-get update -qq
            sudo apt-get install -y build-essential
            log_ok "Installed build-essential"
        fi
    fi

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

# Locate nvcc in any of the common CUDA installation locations
find_nvcc() {
    # 1. Already on PATH
    if command -v nvcc >/dev/null 2>&1; then
        command -v nvcc
        return 0
    fi

    # 2. Standard CUDA toolkit paths (newest version first)
    for path in \
        /usr/local/cuda/bin/nvcc \
        /usr/bin/nvcc \
        /opt/cuda/bin/nvcc \
    ; do
        if [[ -x "$path" ]]; then
            echo "$path"
            return 0
        fi
    done

    # 3. Versioned CUDA installations: /usr/local/cuda-X.Y/bin/nvcc
    if ls /usr/local/cuda-*/bin/nvcc >/dev/null 2>&1; then
        ls -d /usr/local/cuda-*/bin/nvcc | sort -V | tail -n1
        return 0
    fi

    # 4. Conda environments
    if [[ -n "${CONDA_PREFIX:-}" ]] && [[ -x "${CONDA_PREFIX}/bin/nvcc" ]]; then
        echo "${CONDA_PREFIX}/bin/nvcc"
        return 0
    fi
    if [[ -d "${HOME}/.conda/envs" ]]; then
        for env_dir in "${HOME}/.conda/envs"/*/bin/nvcc; do
            if [[ -x "$env_dir" ]]; then
                echo "$env_dir"
                return 0
            fi
        done
    fi

    # 5. WSL / Windows NVIDIA path
    if [[ -x /mnt/c/Program\ Files/NVIDIA\ GPU\ Computing\ Toolkit/CUDA/bin/nvcc ]]; then
        echo "/mnt/c/Program\ Files/NVIDIA\ GPU\ Computing\ Toolkit/CUDA/bin/nvcc"
        return 0
    fi

    return 1
}

# Verify NVIDIA GPU drivers are actually available
has_nvidia_driver() {
    # Check for libcuda (the kernel driver interface)
    if ldconfig -p 2>/dev/null | grep -q libcuda.so; then
        return 0
    fi
    if [[ -f /dev/nvidia0 ]]; then
        return 0
    fi
    if lspci 2>/dev/null | grep -qi 'nvidia.*vga'; then
        # GPU exists; assume driver will work
        return 0
    fi
    return 1
}

# Auto-detect the best available backend
detect_backend() {
    # Check for CUDA
    local nvcc_path
    if nvcc_path="$(find_nvcc)"; then
        # Found nvcc — verify drivers before committing to CUDA
        if has_nvidia_driver; then
            log_info "Found CUDA: ${nvcc_path}"
            echo "cuda"
            return
        else
            log_warn "Found nvcc (${nvcc_path}) but no NVIDIA driver detected — falling back"
        fi
    fi

    # Check for ROCm/HIP
    if command -v hipcc >/dev/null 2>&1; then
        echo "hip"
        return
    fi
    if [[ -f /opt/rocm/bin/hipcc ]]; then
        echo "hip"
        return
    fi

    # Check for Vulkan
    if dpkg -l 2>/dev/null | grep -q 'vulkan-sdk\|vulkan-tools'; then
        echo "vulkan"
        return
    fi
    if command -v vulkaninfo >/dev/null 2>&1; then
        echo "vulkan"
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
# Uses rsync for robust copying with progress, retries, and verification.
# Falls back to cp if rsync is unavailable.
# Verifies file sizes after copy to catch partial transfers.
copy_models() {
    local IFS=','
    local dirs=($1)
    local count=0
    local skipped=0
    local failed=0

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

            local src_size
            src_size=$(stat -c%s "$src_file" 2>/dev/null || stat -f%z "$src_file" 2>/dev/null || echo -1)

            if [[ -f "$dest_file" ]]; then
                # Quick size check first — avoids expensive cmp on network mounts
                local dest_size
                dest_size=$(stat -c%s "$dest_file" 2>/dev/null || stat -f%z "$dest_file" 2>/dev/null || echo -1)

                if [[ "$src_size" == "$dest_size" && "$src_size" != "-1" ]]; then
                    skipped=$((skipped + 1))
                    continue
                fi
                log_warn "Overwriting existing model (size mismatch): $rel_path"
            fi

            mkdir -p "$dest_parent"

            local src_size_after dest_size_after
            local copy_ok=false

            local human_size
            human_size=$(numfmt --to=iec "$src_size" 2>/dev/null || echo "...")

            if command -v rsync >/dev/null 2>&1; then
                # rsync: robust for large files over network mounts, shows progress
                # Use --size-only (not --checksum) to avoid full checksum computation on multi-GB files
                log_info "Copying: $rel_path ($human_size)..."
                if rsync -a --size-only --progress "$src_file" "$dest_file"; then
                    copy_ok=true
                fi
            fi

            if [[ "$copy_ok" != true ]]; then
                # Fallback to cp with verification
                if command -v rsync >/dev/null 2>&1; then
                    log_warn "rsync failed for $rel_path, falling back to cp"
                else
                    log_info "Copying: $rel_path ($human_size)..."
                fi
                if cp -f "$src_file" "$dest_file"; then
                    copy_ok=true
                fi
            fi

            if [[ "$copy_ok" == true ]]; then
                # Verify the copy completed fully by comparing sizes
                src_size_after=$(stat -c%s "$src_file" 2>/dev/null || stat -f%z "$src_file" 2>/dev/null || echo -1)
                dest_size_after=$(stat -c%s "$dest_file" 2>/dev/null || stat -f%z "$dest_file" 2>/dev/null || echo -1)

                if [[ "$src_size_after" == "$dest_size_after" && "$dest_size_after" != "-1" && "$dest_size_after" != "0" ]]; then
                    count=$((count + 1))
                    log_ok "Copied: $rel_path"
                else
                    log_error "Copy verification failed: $rel_path (src=${src_size_after}, dst=${dest_size_after})"
                    rm -f "$dest_file"  # Remove partial file
                    failed=$((failed + 1))
                fi
            else
                log_error "Copy failed: $rel_path"
                failed=$((failed + 1))
            fi
        done < <(find "$dir" -maxdepth 5 \( -name '*.gguf' -o -name '*.mmproj' \) -print0)
    done

    if [[ $count -gt 0 ]]; then
        log_ok "Copied $count model file(s) ($skipped skipped)."
    fi
    if [[ $skipped -gt 0 && $count -eq 0 ]]; then
        log_ok "All $skipped model(s) already up to date."
    fi
    if [[ $failed -gt 0 ]]; then
        log_error "$failed model copy(s) failed. Check disk space and network connectivity."
        return 1
    fi
}

# Generate models.ini from discovered models in MODELS_DIR
#
# INI format (parsed by common_preset_context::load_from_ini):
#   - Keys are CLI arg names without dashes (e.g. "model", "n-gpu-layers"),
#     short forms (e.g. "c"), or environment variable names (e.g. "LLAMA_ARG_*").
#   - [*] section → global preset, cascaded into all other presets.
#   - [model_name] section → individual model preset.
#   - Boolean keys use truthy strings: "true", "on", "1", etc.
#
# Each model gets its own preset section. Multimodal projector files (mmproj)
# are paired with their companion model, not treated as standalone models.
#
# mmproj files may have either:
#   - .mmproj extension  (e.g. model.mmproj)
#   - .gguf extension with "mmproj" in the filename (e.g. mmproj-0001-of-00001.gguf)
#
# Sharded models are identified by the "-NNNNN-of-" pattern in the filename;
# only the first shard (-00001-of-) is used as the model path.

# ─── Helpers for model discovery ──────────────────────────────────────────────

# Returns true if the filename belongs to an mmproj (multimodal projector) file.
# Covers both .mmproj extension and .gguf files with "mmproj" in the name.
is_mmproj_file() {
    local fname
    fname="$(basename "$1")"
    case "$fname" in
        *.mmproj)    return 0 ;;
        mmproj*)    return 0 ;;
        *mmproj*)    return 0 ;;
        *mm-project*) return 0 ;;
    esac
    return 1
}

# Returns true if the filename is the first shard of a sharded model.
is_first_shard() {
    local fname
    fname="$(basename "$1")"
    case "$fname" in
        *-00001-of-*) return 0 ;;
    esac
    return 1
}

# Returns true if the filename is a shard (any index) of a sharded model.
is_shard() {
    local fname
    fname="$(basename "$1")"
    case "$fname" in
        *-[0-9][0-9][0-9][0-9][0-9]-of-*) return 0 ;;
    esac
    return 1
}

# Derive a unique preset name from a model file path.
# Uses the parent directory name (relative to MODELS_DIR), cleaned and lowercased.
# Falls back to filename-based naming for models in the root of MODELS_DIR.
model_preset_name() {
    local model_path="$1"
    local models_dir="$2"
    local rel="${model_path#"$models_dir"/}"

    local name
    if [[ "$rel" == */* ]]; then
        # Model is in a subdirectory — use the directory name
        name="$(dirname "$rel")"
    else
        # Model is directly in MODELS_DIR — use the filename without extension
        name="${rel%.gguf}"
    fi

    # Clean up: lowercase and remove common redundant tokens
    name="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
    name="${name//-gguf/}"
    name="${name//-it/}"
    name="${name//-a3b-ud-/}"
    # Replace remaining non-alphanumeric chars (except dot, hyphen, underscore) with underscore
    name="$(echo "$name" | sed 's/[^a-z0-9._-]/_/g')"

    echo "$name"
}

# Find a companion mmproj file for a given model path.
# Looks for:
#   1. Same directory, same base name + .mmproj
#   2. Same directory, any .mmproj file
#   3. Same directory, any .gguf file with "mmproj" in the name (or sharded mmproj)
# Returns the path via stdout, or empty string if not found.
find_mmproj() {
    local model_dir
    model_dir="$(dirname "$1")"
    local model_base
    model_base="$(basename "$1" .gguf)"

    # 1. Exact match: model.gguf → model.mmproj
    if [[ -f "${model_dir}/${model_base}.mmproj" ]]; then
        echo "${model_dir}/${model_base}.mmproj"
        return
    fi

    # 2. Sharded mmproj: mmproj-00001-of-NNNNN.gguf
    local mmproj_shard
    mmproj_shard=$(find "$model_dir" -maxdepth 1 -name 'mmproj-00001-of-*.gguf' -print -quit 2>/dev/null || true)
    if [[ -n "$mmproj_shard" ]]; then
        echo "$mmproj_shard"
        return
    fi

    # 3. Any .mmproj file in the same directory
    local any_mmproj
    any_mmproj=$(find "$model_dir" -maxdepth 1 -name '*.mmproj' -not -name '*.mmproj.*' -print -quit 2>/dev/null || true)
    if [[ -n "$any_mmproj" ]]; then
        echo "$any_mmproj"
        return
    fi

    # 4. Any .gguf file with "mmproj" in the name
    local any_mmproj_gguf
    any_mmproj_gguf=$(find "$model_dir" -maxdepth 1 -name '*mmproj*.gguf' -print -quit 2>/dev/null || true)
    if [[ -n "$any_mmproj_gguf" ]]; then
        echo "$any_mmproj_gguf"
        return
    fi
}

# Discover models in a directory and emit INI preset sections.
# Arguments: <scan_dir> <maxdepth>
# Prints preset sections to stdout.
# Skips:
#   - mmproj files (handled as companions, not standalone models)
#   - Non-first shards (e.g. model-00002-of-00005.gguf)
#   - Partial/incomplete downloads (*.gguf.* patterns)
scan_models_dir() {
    local scan_dir="$1"
    local maxdepth="${2:-3}"

    while IFS= read -r -d '' gguf_file; do
        local fname
        fname="$(basename "$gguf_file")"

        if is_mmproj_file "$gguf_file"; then
            continue
        fi
        if [[ "$fname" != *.gguf ]]; then
            continue
        fi
        if [[ "$fname" == *.gguf.* ]]; then
            continue
        fi
        # Skip shards that are NOT the first shard
        if is_shard "$gguf_file" && ! is_first_shard "$gguf_file"; then
            continue
        fi

        local preset_name
        preset_name="$(model_preset_name "$gguf_file" "$MODELS_DIR")"

        echo ""
        echo "[$preset_name]"
        echo "model = $gguf_file"

        # Check for a companion mmproj file
        local mmproj_path
        mmproj_path="$(find_mmproj "$gguf_file")"
        if [[ -n "$mmproj_path" ]]; then
            echo "mmproj = $mmproj_path"
        fi

    done < <(find "$scan_dir" -maxdepth "$maxdepth" -name '*.gguf' -not -name '*.gguf.*' -print0 2>/dev/null | sort -z)
}

# Discover models in the HF cache and emit INI preset sections.
# Limits to 50 models to avoid bloated presets.
scan_hf_cache() {
    local hf_cache="${HOME}/.cache/huggingface/hub"
    local count=0

    while IFS= read -r -d '' gguf_file; do
        [[ $count -ge 50 ]] && break

        local fname
        fname="$(basename "$gguf_file")"

        # Skip mmproj files
        if is_mmproj_file "$gguf_file"; then
            continue
        fi

        # Skip non-first shards
        if is_shard "$gguf_file" && ! is_first_shard "$gguf_file"; then
            continue
        fi

        local preset_name
        # Use parent directory name + base name for uniqueness in flat HF cache
        preset_name="$(basename "$(dirname "$gguf_file")")_$(basename "$gguf_file" .gguf)"
        preset_name="${preset_name//[^a-zA-Z0-9_.-]/_}"

        echo ""
        echo "[$preset_name]"
        echo "model = $gguf_file"

        # Check for companion mmproj
        local mmproj_path
        mmproj_path="$(find_mmproj "$gguf_file")"
        if [[ -n "$mmproj_path" ]]; then
            echo "mmproj = $mmproj_path"
        fi

        count=$((count + 1))
    done < <(find "$hf_cache" -maxdepth 6 -name '*.gguf' -not -name '*.gguf.*' -print0 2>/dev/null | sort -z)

    echo "$count"
}

generate_models_ini() {
    mkdir -p "$(dirname "$LLAMA_MODELS_INI")"

    local model_count=0

    {
        echo "version = 1"
        echo ""
        echo "[*]"
        echo "jinja = true"

        # Scan primary models directory
        if [[ -d "$MODELS_DIR" ]]; then
            scan_models_dir "$MODELS_DIR" 3
        fi

        # Fallback: scan HF cache if no models found in MODELS_DIR
        # (We need a separate pass because we can't easily count from the subshell)
        local hf_cache="${HOME}/.cache/huggingface/hub"
        if [[ -d "$hf_cache" ]]; then
            # Only use HF cache if MODELS_DIR had no models (checked by re-scanning)
            local primary_count=0
            while IFS= read -r -d '' gguf_file; do
                local fname
                fname="$(basename "$gguf_file")"
                is_mmproj_file "$gguf_file" && continue
                is_shard "$gguf_file" && ! is_first_shard "$gguf_file" && continue
                primary_count=$((primary_count + 1))
            done < <(find "$MODELS_DIR" -maxdepth 3 -name '*.gguf' -not -name '*.gguf.*' -print0 2>/dev/null)

            if [[ $primary_count -eq 0 ]]; then
                log_warn "No models found in ${MODELS_DIR}. Scanning HF cache..."
                # scan_hf_cache outputs preset sections then a count on the last line;
                # tail -n -2 discards that trailing count so it doesn't leak into the INI
                scan_hf_cache | tail -n -2
                model_count=$(scan_hf_cache | tail -n1)
            fi
        fi

    } > "$LLAMA_MODELS_INI"

    # Count actual presets (non-empty sections excluding [*])
    model_count=$(grep -c '^\[' "$LLAMA_MODELS_INI" 2>/dev/null || echo 0)
    model_count=$((model_count - 1))  # subtract [*] global section
    [[ $model_count -lt 0 ]] && model_count=0

    log_ok "Generated ${LLAMA_MODELS_INI} with $model_count model preset(s)."
}

# ─── Tmux server launcher ─────────────────────────────────────────────────────

prompt_start_server() {
    local multiplexer=""

    # Check for tmux; install if missing
    if ! command -v tmux >/dev/null 2>&1; then
        log_info "tmux not found. Installing..."
        if curl -fsSL https://raw.githubusercontent.com/amanwalia123/tmuxsetup/main/install.sh | bash; then
            if command -v tmux >/dev/null 2>&1; then
                multiplexer="tmux"
                log_ok "tmux installed successfully."
            fi
        fi
    else
        multiplexer="tmux"
    fi

    # Fall back to screen if tmux is still unavailable
    if [[ -z "$multiplexer" ]]; then
        if command -v screen >/dev/null 2>&1; then
            multiplexer="screen"
            log_warn "tmux unavailable. Falling back to screen."
        else
            log_warn "Neither tmux nor screen found. Skipping server launch."
            return
        fi
    fi

    local answer
    read -rp "Start llama-server in a background session? [y/N] " answer
    case "$answer" in
        [yY][eE][sS]|[yY]) ;;
        *) log_info "Skipping server launch."; return ;;
    esac

    local bin_dir="$REPO_DIR/build/bin"
    if [[ ! -d "$bin_dir" ]]; then
        bin_dir="${HOME}/.llama/build/bin"
    fi

    local server_cmd="export PATH=\"$bin_dir:\$PATH\" && llama-server --models-preset $LLAMA_MODELS_INI --host 0.0.0.0 --port 11435 --jinja --n-gpu-layers all --flash-attn on --split-mode layer --tensor-split 1,1 --parallel 1 --slots --ctx-size 200000 --batch-size 4096 --ubatch-size 1024 --cache-type-k q8_0 --cache-type-v q8_0 --reasoning on --tools all --models-max 1"

    local port=11435

    if [[ "$multiplexer" == "tmux" ]]; then
        tmux new-session -d -s llama-server "$server_cmd"
        log_ok "llama-server started in tmux session 'llama-server'."
        log_info "Attach with: tmux attach -t llama-server"
    else
        screen -dmS llama-server bash -c "$server_cmd"
        log_ok "llama-server started in screen session 'llama-server'."
        log_info "Attach with: screen -r llama-server"
    fi

    local machine_ip
    machine_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost')

    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║              llama-server is running                 ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║  Host:          ${machine_ip}:${port}"
    echo "║  WebUI:         http://${machine_ip}:${port}"
    echo "║  API endpoint:  http://${machine_ip}:${port}/v1/chat/completions"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║  Use in other tools as OpenAI-compatible base URL:"
    echo "║    http://${machine_ip}:${port}/v1"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""
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
            --clean)
                CLEAN_BUILD=true; shift ;;
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

    # Determine backend before computing config hash
    if [[ -z "$BACKEND" ]]; then
        BACKEND="$(detect_backend)"
        log_info "Auto-detected backend: ${BACKEND}"
    fi

    # Use incremental builds — only clean when configuration changes
    mkdir -p "$build_subdir"

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

    # Compute hash with backend-specific options included
    local opts_hash="${BACKEND}|${BUILD_TYPE}"

    if needs_clean "$build_subdir" "$opts_hash"; then
        rm -rf "$build_subdir"
        mkdir -p "$build_subdir"
    fi

    # Backend-specific flags
    case "$BACKEND" in
        cuda)
            cmake_opts+=(
                -DGGML_CUDA=ON
                -DGGML_CUDA_ENABLE_UNIFIED_MEMORY=ON
            )
            # Locate nvcc
            if [[ -z "${CUDACXX:-}" ]]; then
                local nvcc_path
                if nvcc_path="$(find_nvcc)"; then
                    export CUDACXX="$nvcc_path"
                    log_info "Using nvcc: ${CUDACXX}"
                else
                    die "CUDA backend selected but nvcc not found. Install nvidia-cuda-toolkit or specify --backend cpu."
                fi
            fi
            local cuda_dir
            cuda_dir="$(dirname "$(dirname "${CUDACXX}")")"
            log_info "CUDA toolkit root: ${cuda_dir}"
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

    # Persist config hash for incremental builds
    echo "$opts_hash" > "${build_subdir}/.llama_install_config"

    log_ok "Configuration complete."
}

do_build() {
    local build_subdir="${BUILD_DIR}/build"

    # Auto-detect jobs if not explicitly set
    local jobs=$JOBS
    if [[ $jobs -eq 0 ]]; then
        jobs=$(auto_detect_jobs)
        log_info "Auto-detected ${jobs} parallel jobs"
    fi

    log_info "Building with ${jobs} parallel jobs..."
    cmake --build "$build_subdir" --config "$BUILD_TYPE" -j "$jobs"
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

    # Install llama-ctl (lifecycle helper for the server) from the repo root
    if [[ -n "${REPO_DIR:-}" && -f "${REPO_DIR}/llama-ctl" ]]; then
        local ctl_src="${REPO_DIR}/llama-ctl"
        local ctl_dest="${INSTALL_DIR}/llama-ctl"
        chmod +x "$ctl_src"
        rm -f "$ctl_dest"
        ln -sf "$ctl_src" "$ctl_dest"
        log_info "Linked: llama-ctl → ${ctl_dest}"
    fi

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

    # Add INSTALL_DIR to PATH if not already present
    local shell_configs=("${HOME}/.bashrc" "${HOME}/.zshrc")
    local path_line='export PATH="${HOME}/.bin:$PATH"'
    for config in "${shell_configs[@]}"; do
        if [[ -f "$config" ]] && ! grep -qF '~/.bin' "$config" 2>/dev/null && ! grep -qF "$INSTALL_DIR" "$config" 2>/dev/null; then
            echo "" >> "$config"
            echo "# Added by llama.cpp install.sh" >> "$config"
            echo "$path_line" >> "$config"
            log_info "Added ~/.bin to PATH in ${config}"
        fi
    done
    export PATH="${INSTALL_DIR}:$PATH"
}

do_models() {
    if [[ -z "$MODELS_SOURCE" ]]; then
        log_warn "No --models-source specified. Skipping model copy."
        log_info "To add models later, run:"
        log_info "  $0 --models-source /path/to/models --skip-clone"
        return
    fi

    # Check if any of the source directories actually exist
    local IFS=','
    local dirs=($MODELS_SOURCE)
    local found=false
    for dir in "${dirs[@]}"; do
        dir="$(echo "$dir" | xargs)"
        if [[ -d "$dir" ]]; then
            found=true
            break
        fi
    done

    if [[ "$found" != true ]]; then
        log_warn "Models source directory not found: ${MODELS_SOURCE}"
        log_info "To add models later, run:"
        log_info "  $0 --models-source /path/to/models --skip-build"
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
    echo "║  Manage the server (recommended):"
    echo "║    llama-ctl start     # background tmux/screen session"
    echo "║    llama-ctl status    # is it running?"
    echo "║    llama-ctl logs      # attach to live logs"
    echo "║    llama-ctl stop      # kill the session"
    echo "║    llama-ctl url       # print WebUI / OpenAI-compat URL"
    echo "║"
    echo "║  Or run llama-server directly:"
    echo "║    llama-server --models-preset ${LLAMA_MODELS_INI}"
    echo "║"
    echo "║  Interactive CLI:"
    echo "║    llama-cli --model ${MODELS_DIR}/<your-model.gguf>"
    echo "╚══════════════════════════════════════════════════════╝"

    echo ""
    prompt_start_server
}

main "$@"
