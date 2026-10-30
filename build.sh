#!/bin/bash
# Builds the Reticulum fork for the iOS simulator on a Mac and writes everything to a log file.
#
#   ./build.sh                 full simulator build (debug_sim_arm64), log under build-output/
#   RUN_TESTS=1 ./build.sh     also run the TelegramApi and TelegramCore test targets
#   RUN_RUST_TESTS=1 ./build.sh   also run the Rust crate's own tests first (needs cargo)
#   REPIN=1 ./build.sh         force a re-resolution of the Reticulum crates (done once automatically)
#
# No Telegram codesigning repository is needed: the build uses the fake profiles in
# build-system/fake-codesigning and --disableProvisioningProfiles, which a simulator build allows.
# Paste build-output/errors.txt (and the end of the log) back to get the failures fixed.

set -uo pipefail
cd "$(dirname "$0")"

CONFIGURATION_PATH="build-system/reticulum-development-configuration.json"
CACHE_DIR="${CACHE_DIR:-$HOME/telegram-bazel-cache}"
OUTPUT_DIR="build-output"
mkdir -p "$OUTPUT_DIR"
LOG="$OUTPUT_DIR/build-$(date +%Y%m%d-%H%M%S).log"
ERRORS="$OUTPUT_DIR/errors.txt"
REPIN_MARKER="$OUTPUT_DIR/.reticulum-crates-repinned"

log() {
    echo "$@" | tee -a "$LOG"
}

run_step() {
    # run_step <name> <command...>: runs the command with its output appended to the log.
    local name="$1"
    shift
    log ""
    log "===== $name: $(date '+%Y-%m-%d %H:%M:%S') ====="
    log "\$ $*"
    "$@" 2>&1 | tee -a "$LOG"
    local status=${PIPESTATUS[0]}
    log "===== $name finished with exit code $status: $(date '+%Y-%m-%d %H:%M:%S') ====="
    return "$status"
}

log "Telegram-iOS-Reticulum build log: $LOG"
log "----- environment -----"
{
    sw_vers 2>/dev/null
    echo "xcode-select: $(xcode-select -p 2>/dev/null)"
    xcodebuild -version 2>/dev/null
    echo "python3: $(python3 --version 2>&1)"
    echo "cargo: $(cargo --version 2>/dev/null || echo 'not installed')"
    echo "git: $(git rev-parse --abbrev-ref HEAD 2>/dev/null) @ $(git rev-parse --short HEAD 2>/dev/null)"
    echo "working tree:"
    git status --short 2>/dev/null | head -20
    echo "disk: $(df -h . | tail -1)"
    echo "configuration: $CONFIGURATION_PATH"
    cat "$CONFIGURATION_PATH"
} 2>&1 | tee -a "$LOG"

RUST_STATUS="skipped"
BUILD_STATUS="not run"
TESTS_STATUS="skipped"

if [ "${RUN_RUST_TESTS:-0}" = "1" ]; then
    if command -v cargo >/dev/null 2>&1; then
        run_step "rust tests" cargo test --manifest-path third-party/reticulum/telegram-reticulum-ffi/Cargo.toml
        RUST_STATUS=$?
    else
        log "cargo is not installed; skipping the Rust tests (install rustup to run them)"
    fi
fi

# The Reticulum crates' Bazel lockfile was seeded off-platform: resolve it once on this Mac.
# Make.py copies the environment it runs Bazel with, so the variables reach crate_universe.
if [ "${REPIN:-0}" = "1" ] || [ ! -f "$REPIN_MARKER" ]; then
    log "Re-resolving the Reticulum crates (CARGO_BAZEL_REPIN_ONLY=reticulum_crates)"
    export CARGO_BAZEL_REPIN=1
    export CARGO_BAZEL_REPIN_ONLY=reticulum_crates
fi

run_step "simulator build" python3 build-system/Make/Make.py --overrideXcodeVersion --cacheDir "$CACHE_DIR" \
    build \
    --configurationPath "$CONFIGURATION_PATH" \
    --codesigningInformationPath build-system/fake-codesigning \
    --disableProvisioningProfiles \
    --buildNumber=1 \
    --configuration=debug_sim_arm64 \
    --continueOnError
BUILD_STATUS=$?
# The repin happens while Bazel resolves the module graph, before compilation, so it is done
# whether or not the compile step succeeded; a repeat run only wastes a lockfile rewrite.
touch "$REPIN_MARKER"
unset CARGO_BAZEL_REPIN CARGO_BAZEL_REPIN_ONLY

if [ "${RUN_TESTS:-0}" = "1" ]; then
    TESTS_STATUS=0
    for target in //submodules/TelegramApi:TelegramApiTests //submodules/TelegramCore:TelegramCoreTests; do
        run_step "test $target" python3 build-system/Make/Make.py --overrideXcodeVersion --cacheDir "$CACHE_DIR" \
            test \
            --configurationPath "$CONFIGURATION_PATH" \
            --codesigningInformationPath build-system/fake-codesigning \
            --disableProvisioningProfiles \
            --target "$target"
        status=$?
        if [ "$status" -ne 0 ]; then
            TESTS_STATUS=$status
        fi
    done
fi

# An error digest: the lines that name a failure, with a little context, deduplicated.
{
    echo "Error digest of $LOG"
    echo "build: exit $BUILD_STATUS; rust tests: $RUST_STATUS; tests: $TESTS_STATUS"
    echo
    grep -n -E -A2 "(^|[^a-zA-Z])(error|ERROR)[: ]|FAILED|fatal error|panicked at|Traceback|No such|cannot find|undefined symbol|Could not|Unresolved" "$LOG" \
        | grep -v -E "warning:|errors\.txt|Error digest|exit [0-9]+;" \
        | awk '!seen[$0]++' \
        | head -400
} > "$ERRORS"

log ""
log "===== summary ====="
log "build: exit $BUILD_STATUS"
log "rust tests: $RUST_STATUS"
log "tests: $TESTS_STATUS"
log "full log: $LOG"
log "error digest: $ERRORS ($(wc -l < "$ERRORS" | tr -d ' ') lines)"
if [ "$BUILD_STATUS" -eq 0 ]; then
    log "The app is at bazel-bin/Telegram/Telegram.ipa (unzip it and copy Payload/Telegram.app into a simulator)."
else
    log "Paste $ERRORS and the last ~200 lines of $LOG into the chat."
fi
exit "$BUILD_STATUS"
