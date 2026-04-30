#!/bin/sh

# build_llama.sh - Build script for llama.cpp with various backend options
#
# Usage:
#   ./build_llama.sh [options]
#
# Options:
#   --backend <cuda|vulkan|metal|hip|sycl|cann|opencl|cpu>  Select backend (default: cuda)
#   --build-type <Release|Debug|RelWithDebInfo>            Build type (default: Release)
#   --jobs <N>                                             Number of parallel jobs (default: auto)
#   --static                                               Build static libraries
#   --help                                                 Show this help message
#
# Examples:
#   ./build_llama.sh                           # Build with CUDA backend (Release)
#   ./build_llama.sh --backend vulkan          # Build with Vulkan backend
#   ./build_llama.sh --build-type Debug        # Build Debug version
#   ./build_llama.sh --jobs 8 --static         # Build with 8 parallel jobs, static libs

set -e  # Exit on any error

# Default values
BACKEND="cuda"
BUILD_TYPE="Release"
JOBS=""
STATIC=""
BUILD_DIR="build"

# remove the build directory if it exist
if [ -d $BUILD_DIR ]; then
    rm -rf $BUILD_DIR
fi

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
    echo "Examples:"
    echo "  $0                           # Build with CUDA backend (Release)"
    echo "  $0 --backend vulkan          # Build with Vulkan backend"
    echo "  $0 --build-type Debug        # Build Debug version"
    echo "  $0 --jobs 8 --static         # Build with 8 parallel jobs, static libs"
}

# Parse command line arguments
while [ $# -gt 0 ]; do
    case $1 in
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
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validate backend option
case $BACKEND in
    cuda|vulkan|metal|hip|sycl|cann|opencl|cpu)
        ;;
    *)
        echo "Error: Invalid backend '$BACKEND'. Valid options are: cuda, vulkan, metal, hip, sycl, cann, opencl, cpu"
        exit 1
        ;;
esac

# Build CMake options
CMAKE_OPTIONS="-B $BUILD_DIR -DCMAKE_BUILD_TYPE=$BUILD_TYPE -DLLAMA_OPENSSL=ON -DLLAMA_SERVER_SSL=ON -DLLAMA_BUILD_LIBRESSL=OFF " #  

# Add static build option if requested
if [ -n "$STATIC" ]; then
    CMAKE_OPTIONS="$CMAKE_OPTIONS -DBUILD_SHARED_LIBS=OFF"
fi

# Add backend-specific options
case $BACKEND in
    cuda)
        # Check if nvcc is available and set CUDACXX if needed
        if [ -z "$CUDACXX" ]; then
            if [ -f "/usr/local/cuda/bin/nvcc" ]; then
                export CUDACXX=/usr/local/cuda/bin/nvcc
            elif command -v nvcc >/dev/null 2>&1; then
                export CUDACXX=nvcc
            fi
        fi
        # Set CMAKE_PREFIX_PATH for CUDA toolkit detection
        export CMAKE_PREFIX_PATH=/usr/local/cuda
        CMAKE_OPTIONS="$CMAKE_OPTIONS -DGGML_CUDA=ON -DGGML_NATIVE=OFF -DGGML_CUDA_ENABLE_UNIFIED_MEMORY=ON -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=ON -DLLAMA_BUILD_SERVER=ON"
        # CMAKE_OPTION="$CMAKE_OPTIONS -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=./build/bin -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=ON -DLLAMA_BUILD_SERVER=ON -DGGML_CUDA=ON -DGGML_CUDA_FA_ALL_QUANTS=ON -DGGML_CUDA_ENABLE_UNIFIED_MEMORY=ON  -DGGML_CUDA_FORCE_MMQ=ON"
        ;;
    vulkan)
        CMAKE_OPTIONS="$CMAKE_OPTIONS -DGGML_VULKAN=ON -DGGML_CUDA=OFF"
        ;;
    metal)
        CMAKE_OPTIONS="$CMAKE_OPTIONS -DGGML_METAL=ON -DGGML_CUDA=OFF"
        ;;
    hip)
        CMAKE_OPTIONS="$CMAKE_OPTIONS -DGGML_HIP=ON -DGGML_CUDA=OFF"
        ;;
    sycl)
        CMAKE_OPTIONS="$CMAKE_OPTIONS -DGGML_SYCL=ON -DGGML_CUDA=OFF"
        ;;
    cann)
        CMAKE_OPTIONS="$CMAKE_OPTIONS -DGGML_CANN=ON -DGGML_CUDA=OFF"
        ;;
    opencl)
        CMAKE_OPTIONS="$CMAKE_OPTIONS -DGGML_OPENCL=ON -DGGML_CUDA=OFF"
        ;;
    cpu)
        # Explicitly disable GPU backends for pure CPU build
        CMAKE_OPTIONS="$CMAKE_OPTIONS -DGGML_CUDA=OFF"
        ;;
esac

# Add parallel jobs option if specified
BUILD_OPTIONS=""
if [ -n "$JOBS" ]; then
    BUILD_OPTIONS="-j $JOBS"
fi

echo "Building llama.cpp with the following configuration:"
echo "  Backend:     $BACKEND"
echo "  Build type:  $BUILD_TYPE"
echo "  Build dir:   $BUILD_DIR"
echo "  Parallel:    ${JOBS:-auto}"
echo "  Static:      ${STATIC:-OFF}"
echo ""
echo "CMake options: $CMAKE_OPTIONS"
echo ""

# Run CMake configure
echo "Configuring build... $CMAKE_OPTIONS"

# Set OpenSSL paths to use conda version
export OPENSSL_ROOT_DIR=$HOME/.conda
export OPENSSL_LIBRARIES=$HOME/.conda/lib
export PKG_CONFIG_PATH=$HOME/.conda/lib/pkgconfig:$PKG_CONFIG_PATH

cmake $CMAKE_OPTIONS

# Run build
echo "Building..."
cmake --build $BUILD_DIR --config $BUILD_TYPE $BUILD_OPTIONS

echo ""
echo "Build completed successfully!"
echo "Binaries are available in $BUILD_DIR/bin/"
