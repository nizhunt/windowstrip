#!/bin/bash
# Builds the test app and the runner (only when their sources changed), then
# runs the WindowStrip tests. Arguments go to the runner:
#   tests/run-tests.sh                   all tests
#   tests/run-tests.sh --only T04,T07    some tests
#   tests/run-tests.sh --no-mouse        everything except the tests that click and hover (T09-T12, T20, T21, T25, T26)
#   tests/run-tests.sh --json out.json   also write a machine-readable result
#   tests/run-tests.sh --dump            print what the runner reads from state.json and the log
#   tests/run-tests.sh --smoke           check the test app alone
# Run it from a terminal that has the Accessibility permission.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
FLAGS=(-O -swift-version 5 -target arm64-apple-macos14.0)
APP="$BUILD/WSTestApp.app"
APP_BIN="$APP/Contents/MacOS/WSTestApp"
RUNNER="$BUILD/wstest"

mkdir -p "$APP/Contents/MacOS"

if [[ ! -x "$APP_BIN" || "$DIR/TestApp/main.swift" -nt "$APP_BIN" || "$DIR/TestApp/Info.plist" -nt "$APP_BIN" ]]; then
  cp "$DIR/TestApp/Info.plist" "$APP/Contents/Info.plist"
  swiftc "${FLAGS[@]}" -o "$APP_BIN" "$DIR/TestApp/main.swift"
  codesign --force --sign - --identifier dev.windowstrip.testapp "$APP"
  echo "built $APP" >&2
fi

if [[ ! -x "$RUNNER" || -n "$(find "$DIR/Runner" -name '*.swift' -newer "$RUNNER")" ]]; then
  swiftc "${FLAGS[@]}" -o "$RUNNER" "$DIR"/Runner/*.swift
  echo "built $RUNNER" >&2
fi

# Desktop switching through Mission Control, for T19.
SPACES="$BUILD/spaces"
if [[ ! -x "$SPACES" || "$DIR/Spaces/main.swift" -nt "$SPACES" ]]; then
  swiftc "${FLAGS[@]}" -o "$SPACES" "$DIR/Spaces/main.swift"
  echo "built $SPACES" >&2
fi

exec "$RUNNER" "$@"
