#!/usr/bin/env bash
#
# uninstall.sh - Cleanup utility for llama.cpp installation
#
# Removes binaries, models, configuration, and build artifacts
# created by install.sh.
#
# Usage:
#   ./uninstall.sh [options]
#
# Options:
#   --install-dir <dir>
#       Directory where binaries were symlinked (default: ~/.bin)
#   --models-dir <dir>
#       Directory where models were copied (default: ~/.llama/models)
#   --build-dir <dir>
#       Directory where build artifacts are stored (default: ~/.llama/build)
#   --force
#       Skip confirmation prompt

set -euo pipefail

# ─── Defaults ──────────────────────────────────────────────────────────────────

INSTALL_DIR="${HOME}/.bin"
MODELS_DIR="${HOME}/.llama/models"
BUILD_DIR="${HOME}/.llama/build"
LLAMA_MODELS_INI="${HOME}/.llama/models.ini"
FORCE=false

# ─── Helpers ──────────────────────────────────────────────────────────────────

log_info()  { echo -e "\033[1;34m[uninstall]\033[0m $*" >&2; }
log_ok()    { echo -e "\033[1;32m[  ok  ]\033[0m $*" >&2; }
log_warn()  { echo -e "\033[1;33m[ warn ]\033[0m $*" >&2; }
log_error() { echo -e "\033[1;31m[error ]\033[0m $*" >&2; }

die() { log_error "$@"; exit 1; }

# ─── Argument Parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --models-dir)  MODELS_DIR="$2"; shift 2 ;;
        --build-dir)   BUILD_DIR="$2"; shift 2 ;;
        --force)       FORCE=true; shift ;;
        *)             die "Unknown option: $1" ;;
    esac
done

# ─── Execution ─────────────────────────────────────────────────────────────────

echo "╔══════════════════════════════════════════════════════╗"
echo "║           llama.cpp Uninstall Utility               ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Binaries dir:  $INSTALL_DIR"
echo "║  Models dir:    $MODELS_DIR"
echo "║  Build dir:     $BUILD_DIR"
echo "║  Presets file:  $LLAMA_MODELS_INI"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

if [[ "$FORCE" == false ]]; then
    read -rp "This will permanently delete the above directories and files. Continue? [y/N] " answer
    case "$answer" in
        [yY][eE][sS]|[yY]) ;;
        *) log_info "Uninstall cancelled."; exit 0 ;;
    esac
fi

# 1. Remove Binaries
if [[ -d "$INSTALL_DIR" ]]; then
    log_info "Removing binaries from $INSTALL_DIR..."
    # Only remove the specific binaries installed by install.sh to avoid nuking the whole .bin folder
    for bin in llama-server llama-cli llama-quantize llama-ctl; do
        if [[ -L "${INSTALL_DIR}/${bin}" ]]; then
            rm "${INSTALL_DIR}/${bin}"
            log_ok "Removed symlink: ${bin}"
        fi
    done
else
    log_warn "Installation directory $INSTALL_DIR not found. Skipping."
fi

# 2. Remove Models and Presets
if [[ -f "$LLAMA_MODELS_INI" ]]; then
    log_info "Removing presets file: $LLAMA_MODELS_INI"
    rm "$LLAMA_MODELS_INI"
    log_ok "Deleted $LLAMA_MODELS_INI"
fi

if [[ -d "$MODELS_DIR" ]]; then
    log_info "Removing models directory: $MODELS_DIR"
    rm -rf "$MODELS_DIR"
    log_ok "Deleted $MODELS_DIR"
else
    log_warn "Models directory $MODELS_DIR not found. Skipping."
fi

# 3. Remove Build Artifacts
if [[ -d "$BUILD_DIR" ]]; then
    log_info "Removing build directory: $BUILD_DIR"
    rm -rf "$BUILD_DIR"
    log_ok "Deleted $BUILD_DIR"
else
    log_warn "Build directory $BUILD_DIR not found. Skipping."
fi

echo ""
log_ok "Uninstallation complete. All llama.cpp artifacts have been removed."
