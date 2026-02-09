#!/usr/bin/env bash
#
# Build the DuckDB GCS extension for multiple platforms and upload to GCS.
#
# Auto-detects the host platform and builds natively when possible,
# falls back to Docker for everything else.
#
# Usage:
#   ./scripts/build-and-upload.sh              # build all + upload
#   ./scripts/build-and-upload.sh --no-upload  # build only
#   ./scripts/build-and-upload.sh osx_arm64    # build one platform + upload
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DUCKDB_VERSION="v1.4.4"
GCS_BUCKET="def-duckdb-extensions"
EXTENSION_NAME="gcs"
DOCKER_IMAGE="ubuntu:22.04"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] !${NC} $*"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $*"; }

# ---------------------------------------------------------------------------
# Detect host platform
# ---------------------------------------------------------------------------
detect_host_platform() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Darwin)
            case "$arch" in
                arm64)  echo "osx_arm64" ;;
                x86_64) echo "osx_amd64" ;;
                *)      echo "unknown" ;;
            esac
            ;;
        Linux)
            case "$arch" in
                aarch64) echo "linux_arm64" ;;
                x86_64)  echo "linux_amd64" ;;
                *)       echo "unknown" ;;
            esac
            ;;
        *) echo "unknown" ;;
    esac
}

HOST_PLATFORM="$(detect_host_platform)"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
DO_UPLOAD=true
PLATFORMS=()

for arg in "$@"; do
    case "$arg" in
        --no-upload) DO_UPLOAD=false ;;
        --help|-h)
            echo "Usage: $0 [--no-upload] [platform ...]"
            echo ""
            echo "Platforms: osx_arm64  osx_amd64  linux_amd64  linux_arm64"
            echo "If no platform is specified, all four are built."
            echo ""
            echo "Host detected: $HOST_PLATFORM"
            exit 0
            ;;
        *) PLATFORMS+=("$arg") ;;
    esac
done

if [ ${#PLATFORMS[@]} -eq 0 ]; then
    case "$HOST_PLATFORM" in
        osx_arm64|osx_amd64)
            PLATFORMS=(osx_arm64 osx_amd64 linux_amd64 linux_arm64) ;;
        linux_amd64|linux_arm64)
            PLATFORMS=(linux_amd64 linux_arm64) ;;
        *)
            PLATFORMS=(linux_amd64 linux_arm64) ;;
    esac
    log "Auto-selected platforms for $HOST_PLATFORM host"
fi

# ---------------------------------------------------------------------------
# Output directory
# ---------------------------------------------------------------------------
OUTPUT_DIR="$PROJECT_DIR/dist/$DUCKDB_VERSION"
mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
nproc_portable() {
    # Override with JOBS env var: JOBS=8 ./scripts/build-and-upload.sh
    if [ -n "${JOBS:-}" ]; then
        echo "$JOBS"
    elif command -v nproc &>/dev/null; then
        nproc
    elif command -v sysctl &>/dev/null; then
        sysctl -n hw.ncpu
    else
        echo 4
    fi
}

compress_extension() {
    local src="$1"
    local dst="$2"
    if [ -f "$src" ]; then
        gzip -c "$src" > "$dst"
        ok "Compressed: $dst ($(du -h "$dst" | cut -f1))"
    else
        err "Extension not found: $src"
        return 1
    fi
}

ensure_vcpkg() {
    if [ -z "${VCPKG_TOOLCHAIN_PATH:-}" ]; then
        if [ -n "${VCPKG_ROOT:-}" ]; then
            export VCPKG_TOOLCHAIN_PATH="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake"
        else
            err "VCPKG_ROOT or VCPKG_TOOLCHAIN_PATH must be set for native builds"
            return 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Native build (runs directly on the host)
# ---------------------------------------------------------------------------
build_native() {
    local target_platform="$1"
    log "Building $target_platform (native)..."

    cd "$PROJECT_DIR"
    rm -rf build/release
    ensure_vcpkg

    local make_env=""
    if [ "$HOST_PLATFORM" = "osx_arm64" ] && [ "$target_platform" = "osx_amd64" ]; then
        log "Cross-compiling: arm64 host -> x86_64 target"
        make_env="OSX_BUILD_ARCH=x86_64 VCPKG_TARGET_TRIPLET=x64-osx-release VCPKG_HOST_TRIPLET=arm64-osx-release"
    elif [ "$HOST_PLATFORM" = "osx_amd64" ] && [ "$target_platform" = "osx_arm64" ]; then
        log "Cross-compiling: x86_64 host -> arm64 target"
        make_env="OSX_BUILD_ARCH=arm64 VCPKG_TARGET_TRIPLET=arm64-osx-release VCPKG_HOST_TRIPLET=x64-osx-release"
    fi

    eval "$make_env make -j$(nproc_portable)" 2>&1 | tail -5

    local ext="build/release/extension/$EXTENSION_NAME/$EXTENSION_NAME.duckdb_extension"
    mkdir -p "$OUTPUT_DIR/$target_platform"
    compress_extension "$ext" "$OUTPUT_DIR/$target_platform/$EXTENSION_NAME.duckdb_extension.gz"
}

# ---------------------------------------------------------------------------
# Docker build (for cross-platform builds)
# ---------------------------------------------------------------------------
build_docker() {
    local target_platform="$1"

    local docker_platform
    case "$target_platform" in
        linux_amd64) docker_platform="linux/amd64" ;;
        linux_arm64) docker_platform="linux/arm64" ;;
        *) err "Docker builds only support linux targets, got: $target_platform"; return 1 ;;
    esac

    log "Building $target_platform (Docker $docker_platform)..."

    if ! command -v docker &>/dev/null; then
        err "Docker is required for $target_platform builds. Install Docker Desktop."
        return 1
    fi

    cd "$PROJECT_DIR"

    docker run --rm \
        --platform "$docker_platform" \
        -v "$PROJECT_DIR:/workspace" \
        -w /workspace \
        -e VCPKG_ROOT=/opt/vcpkg \
        -e VCPKG_TOOLCHAIN_PATH=/opt/vcpkg/scripts/buildsystems/vcpkg.cmake \
        "$DOCKER_IMAGE" \
        bash -c '
            set -e
            echo "=== Installing build dependencies ==="
            apt-get update -qq
            apt-get install -y -qq build-essential cmake git curl zip unzip tar pkg-config ninja-build python3 > /dev/null 2>&1

            echo "=== Setting up vcpkg ==="
            if [ ! -d /opt/vcpkg ]; then
                git clone --depth 1 https://github.com/microsoft/vcpkg.git /opt/vcpkg
                /opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics > /dev/null 2>&1
            fi

            echo "=== Cleaning build directory ==="
            rm -rf build/release

            echo "=== Building ==="
            make -j$(nproc) 2>&1 | tail -10

            echo "=== Done ==="
        '

    local ext="build/release/extension/$EXTENSION_NAME/$EXTENSION_NAME.duckdb_extension"
    mkdir -p "$OUTPUT_DIR/$target_platform"
    compress_extension "$ext" "$OUTPUT_DIR/$target_platform/$EXTENSION_NAME.duckdb_extension.gz"
}

# ---------------------------------------------------------------------------
# Decide how to build a given platform
# ---------------------------------------------------------------------------
build_platform() {
    local target="$1"

    case "$target" in
        osx_arm64|osx_amd64)
            if [[ "$HOST_PLATFORM" == osx_* ]]; then
                build_native "$target"
            else
                err "$target requires a macOS host (detected: $HOST_PLATFORM). Skipping."
                return 1
            fi
            ;;
        linux_amd64|linux_arm64)
            # Linux targets: native if matching host, otherwise Docker
            if [ "$HOST_PLATFORM" = "$target" ]; then
                build_native "$target"
            else
                build_docker "$target"
            fi
            ;;
        *)
            err "Unknown platform: $target"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Upload to GCS
# ---------------------------------------------------------------------------
upload_to_gcs() {
    log "Uploading to gs://$GCS_BUCKET/..."

    if ! command -v gsutil &>/dev/null; then
        err "gsutil is required for upload. Install Google Cloud SDK."
        return 1
    fi

    # Show what we're uploading
    echo ""
    log "Repository structure:"
    find "$OUTPUT_DIR" -name "*.gz" -type f | sort | while read -r f; do
        echo "  $(echo "$f" | sed "s|$PROJECT_DIR/dist/||") ($(du -h "$f" | cut -f1))"
    done
    echo ""

    gsutil -m rsync -r "$PROJECT_DIR/dist/" "gs://$GCS_BUCKET/"
    gsutil -m acl ch -r -u AllUsers:R "gs://$GCS_BUCKET/"

    ok "Upload complete!"
    echo ""
    log "Install in DuckDB with:"
    echo "  SET custom_extension_repository='https://storage.googleapis.com/$GCS_BUCKET';"
    echo "  INSTALL gcs;"
    echo "  LOAD gcs;"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo ""
log "DuckDB GCS Extension Builder"
log "DuckDB version: $DUCKDB_VERSION"
log "Host platform:  $HOST_PLATFORM"
log "Platforms:      ${PLATFORMS[*]}"
log "Upload:         $DO_UPLOAD"
echo ""

FAILED=()

for platform in "${PLATFORMS[@]}"; do
    build_platform "$platform" || FAILED+=("$platform")
    echo ""
done

# Summary
echo ""
log "Build summary:"
for platform in "${PLATFORMS[@]}"; do
    local_dir="$OUTPUT_DIR/$platform"
    if [ -f "$local_dir/$EXTENSION_NAME.duckdb_extension.gz" ]; then
        ok "$platform"
    else
        err "$platform (FAILED)"
    fi
done

if [ ${#FAILED[@]} -gt 0 ]; then
    echo ""
    warn "Failed platforms: ${FAILED[*]}"
fi

# Upload successful builds
if $DO_UPLOAD; then
    echo ""
    upload_to_gcs
fi
