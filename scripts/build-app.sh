#!/bin/zsh

set -euo pipefail

# Every dependency in this project is public. Prevent Git from consulting a
# configured macOS Keychain credential helper during anonymous package fetches.
export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.helper
export GIT_CONFIG_VALUE_0=

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_NAME="Wordmate"
EXECUTABLE_NAME="LocalTranscriber"
OUTPUT_DIR="$PROJECT_DIR/build"
APP_PATH="$OUTPUT_DIR/$APP_NAME.app"
ENTITLEMENTS_PATH="$PROJECT_DIR/Config/Wordmate.entitlements"
SWIFTPM_WORK_DIR="$PROJECT_DIR/.build/local-swiftpm"
MLX_METAL_SOURCE_DIR="$PROJECT_DIR/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
MLX_METAL_BUILD_DIR="$OUTPUT_DIR/mlx-metal"
BUNDLE_IDENTIFIER="${WORDMATE_BUNDLE_IDENTIFIER:-sh.wordmate.app}"
SIGNING_IDENTITY="${WORDMATE_SIGNING_IDENTITY:--}"
RELEASE_VERSION="${WORDMATE_VERSION:-}"
RELEASE_BUILD_NUMBER="${WORDMATE_BUILD_NUMBER:-}"

mkdir -p "$SWIFTPM_WORK_DIR/cache"
mkdir -p "$SWIFTPM_WORK_DIR/config"
mkdir -p "$SWIFTPM_WORK_DIR/security"
mkdir -p "$SWIFTPM_WORK_DIR/clang-modules"
export CLANG_MODULE_CACHE_PATH="$SWIFTPM_WORK_DIR/clang-modules"

SWIFT_FLAGS=(
    # Xcode 27 defaults to the swiftbuild engine, which tries to compile MLX's
    # Metal sources itself. This script builds that shader library below.
    --build-system native
    --disable-sandbox
    --disable-keychain
    --cache-path "$SWIFTPM_WORK_DIR/cache"
    --config-path "$SWIFTPM_WORK_DIR/config"
    --security-path "$SWIFTPM_WORK_DIR/security"
)

swift build --package-path "$PROJECT_DIR" "${SWIFT_FLAGS[@]}" -c release 1>&2
BIN_PATH="$(swift build --package-path "$PROJECT_DIR" "${SWIFT_FLAGS[@]}" -c release --show-bin-path)"

# SwiftPM's command-line builder deliberately skips MLX's Metal sources. Build
# the same shader library Xcode emits so MLX can initialize its GPU runtime in
# the packaged app. Without this file MLX terminates the process before Swift
# can surface a recoverable error.
if [[ ! -d "$MLX_METAL_SOURCE_DIR" ]]; then
    echo "MLX Metal sources were not found at $MLX_METAL_SOURCE_DIR" >&2
    exit 1
fi

mkdir -p "$MLX_METAL_BUILD_DIR"
mkdir -p "$SWIFTPM_WORK_DIR/metal-modules"

MLX_AIR_FILES=()
for source in "$MLX_METAL_SOURCE_DIR"/**/*.metal(N); do
    relative_path="${source#$MLX_METAL_SOURCE_DIR/}"
    output_name="${relative_path//\//_}"
    output_path="$MLX_METAL_BUILD_DIR/${output_name%.metal}.air"

    xcrun -sdk macosx metal \
        -Wall \
        -Wextra \
        -ffast-math \
        -Wno-c++17-extensions \
        -Wno-c++20-extensions \
        -fmodules-cache-path="$SWIFTPM_WORK_DIR/metal-modules" \
        -mmacosx-version-min=14.0 \
        -I "$MLX_METAL_SOURCE_DIR" \
        -c "$source" \
        -o "$output_path"

    MLX_AIR_FILES+=("$output_path")
done

if (( ${#MLX_AIR_FILES[@]} == 0 )); then
    echo "No MLX Metal shaders were found at $MLX_METAL_SOURCE_DIR" >&2
    exit 1
fi

xcrun -sdk macosx metallib \
    "${MLX_AIR_FILES[@]}" \
    -o "$MLX_METAL_BUILD_DIR/mlx.metallib"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"
mkdir -p "$APP_PATH/Contents/Frameworks"
mkdir -p "$APP_PATH/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources"

cp "$BIN_PATH/$EXECUTABLE_NAME" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
cp "$PROJECT_DIR/Config/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$PROJECT_DIR/Assets/Wordmate.icns" "$APP_PATH/Contents/Resources/Wordmate.icns"
cp "$PROJECT_DIR/Assets/WordmateMenuBarTemplate.png" \
    "$APP_PATH/Contents/Resources/WordmateMenuBarTemplate.png"
cp "$PROJECT_DIR/Config/MLXMetalBundleInfo.plist" \
    "$APP_PATH/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Info.plist"
cp "$MLX_METAL_BUILD_DIR/mlx.metallib" \
    "$APP_PATH/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"

/usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier $BUNDLE_IDENTIFIER" \
    "$APP_PATH/Contents/Info.plist"

if [[ -n "$RELEASE_VERSION" ]]; then
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleShortVersionString $RELEASE_VERSION" \
        "$APP_PATH/Contents/Info.plist"
fi

if [[ -n "$RELEASE_BUILD_NUMBER" ]]; then
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleVersion $RELEASE_BUILD_NUMBER" \
        "$APP_PATH/Contents/Info.plist"
fi

for bundle in "$BIN_PATH"/*.bundle(N); do
    cp -R "$bundle" "$APP_PATH/Contents/Resources/"
done

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    SIGNING_ARGS=(
        --force
        --sign -
        --timestamp=none
    )
else
    SIGNING_ARGS=(
        --force
        --sign "$SIGNING_IDENTITY"
        --options runtime
        --timestamp
    )
fi

for framework in "$BIN_PATH"/*.framework(N); do
    # Old local build directories can still contain the removed Whisper binary.
    # Never carry that stale framework into a new Wordmate bundle.
    if [[ "${framework:t}" == "whisper.framework" ]]; then
        continue
    fi
    cp -R "$framework" "$APP_PATH/Contents/Frameworks/"
    codesign --deep "${SIGNING_ARGS[@]}" "$APP_PATH/Contents/Frameworks/${framework:t}"
done

if ! otool -l "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
fi

# Give local rebuilds one stable designated requirement. Developer ID builds
# derive a stronger designated requirement from Apple's signing certificate.
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign \
        "${SIGNING_ARGS[@]}" \
        --entitlements "$ENTITLEMENTS_PATH" \
        --requirements "=designated => identifier \"$BUNDLE_IDENTIFIER\"" \
        "$APP_PATH"
else
    codesign \
        --deep \
        "${SIGNING_ARGS[@]}" \
        --entitlements "$ENTITLEMENTS_PATH" \
        "$APP_PATH"
fi

codesign --verify --deep --strict "$APP_PATH"

echo "$APP_PATH"
