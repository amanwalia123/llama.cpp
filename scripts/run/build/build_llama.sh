#!/usr/bin/env bash

# build_llama.sh - Build script for llama.cpp with various backend options
#
# Usage:
#   ./build_llama.sh [options]
#   Run without options for an interactive TUI.
#
# Options:
#   --backend <cuda|vulkan|metal|hip|sycl|cann|opencl|cpu>  Select backend (default: cuda)
#   --build-type <Release|Debug|RelWithDebInfo>            Build type (default: Release)
#   --jobs <N>                                             Number of parallel jobs (default: auto)
#   --static                                               Build static libraries
#   --help                                                 Show this help message

set -e  # Exit on any error

# Default values
BACKEND="cuda"
BUILD_TYPE="Release"
JOBS=""
STATIC=""
BUILD_DIR="build"

# Help message
show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --backend <cuda|vulkan|metal|hip|sycl|cann|opencl|cpu>  Select backend (default: cuda)"
    echo "  --build-type <Release|Debug|RelWithDebInfo>            Build type (default: Release)"
    echo "  --jobs <N>                                             Number of parallel jobs (default: auto)"
    echo "  --static                                               Build static libraries"
    echo "  --help                                                 Show this help message"
    echo ""
    echo "If run without arguments, an interactive setup will launch."
}

# Interactive TUI function
run_tui() {
    clear
    echo "================================================="
    echo "          llama.cpp Build Configuration          "
    echo "================================================="
    echo ""
    
    echo "1. Select Backend:"
    local backends=("cuda" "vulkan" "metal" "hip" "sycl" "cann" "opencl" "cpu")
    # Use PS3 to customize the prompt for select
    PS3="Enter choice [1-${#backends[@]}]: "
    select b in "${backends[@]}"; do
        if [ -n "$b" ]; then
            BACKEND="$b"
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
    echo "-> Selected Backend: $BACKEND"
    echo ""

    echo "2. Select Build Type:"
    local build_types=("Release" "Debug" "RelWithDebInfo")
    PS3="Enter choice [1-${#build_types[@]}]: "
    select bt in "${build_types[@]}"; do
        if [ -n "$bt" ]; then
            BUILD_TYPE="$bt"
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
    echo "-> Selected Build Type: $BUILD_TYPE"
    echo ""

    echo "3. Parallel Jobs:"
    read -p "Enter number of parallel jobs (leave empty for auto): " JOBS
    if [ -z "$JOBS" ]; then
        echo "-> Auto-detecting parallel jobs"
    else
        echo "-> Selected Jobs: $JOBS"
    fi
    echo ""

    echo "4. Static Libraries:"
    read -p "Build static libraries? [y/N]: " static_ans
    if [[ "$static_ans" =~ ^[Yy]$ ]]; then
        STATIC="ON"
        echo "-> Static libraries enabled"
    else
        STATIC=""
        echo "-> Static libraries disabled"
    fi
    echo ""
    
    echo "================================================="
    echo "Configuration complete. Press Enter to build..."
    read -r
}

if [ $# -eq 0 ]; then
    # No arguments provided, run the interactive TUI
    run_tui
else
    # Parse command line arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --backend)
                BACKEND="$2"
                shift 2
                ;;
            --build-type)
                BUILD_TYPE="$2"
                shift 2
                ;;
            --jobs)
                JOBS="$2"
                shift 2
                ;;
            --static)
                STATIC="ON"
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                echo "Error: Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
fi

# ALWAYS remove the build directory if it exists
if [ -d "$BUILD_DIR" ]; then
    echo "Removing existing build directory..."
    rm -rf "$BUILD_DIR"
fi

# Validate backend option
case "$BACKEND" in
    cuda|vulkan|metal|hip|sycl|cann|opencl|cpu)
        ;;
    *)
        echo "Error: Invalid backend '$BACKEND'. Valid options are: cuda, vulkan, metal, hip, sycl, cann, opencl, cpu"
        exit 1
        ;;
esac

# Build CMake options array to safely handle arguments with spaces
CMAKE_OPTIONS=(
    "-B" "$BUILD_DIR"
    "-DCMAKE_BUILD_TYPE=$BUILD_TYPE"
    "-DLLAMA_OPENSSL=ON"
    "-DLLAMA_SERVER_SSL=ON"
    "-DLLAMA_BUILD_LIBRESSL=OFF"
)

# Add static build option if requested
if [ -n "$STATIC" ]; then
    CMAKE_OPTIONS+=("-DBUILD_SHARED_LIBS=OFF")
fi

# Add backend-specific options
case "$BACKEND" in
    cuda)
        if [ -z "$CUDACXX" ]; then
            if [ -f "/usr/local/cuda/bin/nvcc" ]; then
                export CUDACXX="/usr/local/cuda/bin/nvcc"
            elif command -v nvcc >/dev/null 2>&1; then
                export CUDACXX="nvcc"
            fi
        fi
        export CMAKE_PREFIX_PATH="/usr/local/cuda"
        CMAKE_OPTIONS+=("-DGGML_CUDA=ON" "-DGGML_NATIVE=OFF" "-DGGML_CUDA_ENABLE_UNIFIED_MEMORY=ON" "-DLLAMA_BUILD_TESTS=OFF" "-DLLAMA_BUILD_EXAMPLES=ON" "-DLLAMA_BUILD_SERVER=ON")
        ;;
    vulkan)
        CMAKE_OPTIONS+=("-DGGML_VULKAN=ON" "-DGGML_CUDA=OFF")
        ;;
    metal)
        CMAKE_OPTIONS+=("-DGGML_METAL=ON" "-DGGML_CUDA=OFF")
        ;;
    hip)
        CMAKE_OPTIONS+=("-DGGML_HIP=ON" "-DGGML_CUDA=OFF")
        ;;
    sycl)
        CMAKE_OPTIONS+=("-DGGML_SYCL=ON" "-DGGML_CUDA=OFF")
        ;;
    cann)
        CMAKE_OPTIONS+=("-DGGML_CANN=ON" "-DGGML_CUDA=OFF")
        ;;
    opencl)
        CMAKE_OPTIONS+=("-DGGML_OPENCL=ON" "-DGGML_CUDA=OFF")
        ;;
    cpu)
        CMAKE_OPTIONS+=("-DGGML_CUDA=OFF")
        ;;
esac

# Add parallel jobs option if specified
BUILD_OPTIONS=()
if [ -n "$JOBS" ]; then
    BUILD_OPTIONS+=("-j" "$JOBS")
fi

echo "Building llama.cpp with the following configuration:"
echo "  Backend:     $BACKEND"
echo "  Build type:  $BUILD_TYPE"
echo "  Build dir:   $BUILD_DIR"
echo "  Parallel:    ${JOBS:-auto}"
echo "  Static:      ${STATIC:-OFF}"
echo ""
echo "CMake options: ${CMAKE_OPTIONS[*]}"
echo ""

# Run CMake configure
echo "Configuring build..."

export OPENSSL_ROOT_DIR="$HOME/.conda"
export OPENSSL_LIBRARIES="$HOME/.conda/lib"
export PKG_CONFIG_PATH="$HOME/.conda/lib/pkgconfig:$PKG_CONFIG_PATH"

cmake "${CMAKE_OPTIONS[@]}"

# Run build
echo "Building..."
cmake --build "$BUILD_DIR" --config "$BUILD_TYPE" "${BUILD_OPTIONS[@]}"

echo ""
echo "Build completed successfully!"
echo "Binaries are available in $BUILD_DIR/bin/"
