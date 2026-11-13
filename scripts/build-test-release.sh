#!/bin/sh
# A release binary with the test-only POST /control, in its own build folder so that it never mixes with
# the published build (scripts/bundle.sh). For CPU measures and the demo video, on a dev instance.
#   scripts/build-test-release.sh   →   .build/test-control/release/ClaudePet
set -e
cd "$(dirname "$0")/.."
swift build -c release -Xswiftc -DTEST_CONTROL --build-path .build/test-control
