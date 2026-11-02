#!/bin/sh
# Run from a normal Mac Terminal; uses synthetic frames and never opens a camera.
set -eu
cd "$(dirname "$0")"
./build.sh --development
python3 -B Tests/check_stream.py --self-test
sender="$(pwd)/build/MagerCam Sender Dev.app/Contents/MacOS/MagerCamSender"
"$sender" --self-test
test_dir="$(mktemp -d "${TMPDIR:-/tmp/}magercam-test.XXXXXX")"
test_key="$(python3 -c 'import secrets; print("%06d" % secrets.randbelow(1000000))')"
test_port="${MAGERCAM_TEST_PORT:-14848}"
test_discovery_port="${MAGERCAM_TEST_DISCOVERY_PORT:-14849}"
"$sender" --test-pattern --key "$test_key" --port "$test_port" \
    --discovery-port "$test_discovery_port" --width 1920 --height 1080 \
    --duration 45 >"$test_dir/sender.log" 2>&1 &
sender_pid=$!
cleanup() {
    kill "$sender_pid" 2>/dev/null || true
    wait "$sender_pid" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
attempt=0
while ! grep -q 'Synthetic sender ready' "$test_dir/sender.log"; do
    if ! kill -0 "$sender_pid" 2>/dev/null; then
        cat "$test_dir/sender.log"
        exit 1
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 100 ]; then
        cat "$test_dir/sender.log"
        printf '\nSender did not become ready within 20 seconds.\n' >&2
        exit 1
    fi
    sleep 0.2
done
MG_KEY="$test_key" python3 Tests/check_stream.py 127.0.0.1 --port "$test_port" \
    --discovery-port "$test_discovery_port" \
    --frames 60 --expect-size 1920x1080 --expect-bitrate 16000 --require-high-profile \
    --output-h264 "$test_dir/sample.h264"
printf '\nIntegration checks passed. H.264 sample and server log: %s\n' "$test_dir"
