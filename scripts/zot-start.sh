#!/bin/sh
#
# Supervise zot and exit non-zero when it dies or stops answering.
#
# Talos extension services have no health check of their own: `restart: always`
# only reacts to the entrypoint exiting, so a zot that hangs while still running
# would stay marked healthy forever. Exiting here is what triggers the restart.
#
# Tunable via the extension service environment:
#   ZOT_HEALTH_PORT      port to probe (default: read from the zot config)
#   ZOT_HEALTH_SCHEME    http or https (default: https if the config enables TLS)
#   ZOT_HEALTH_INTERVAL  seconds between checks (default 30)
#   ZOT_HEALTH_TIMEOUT   seconds to wait for a response (default 5)

set -u

INTERVAL="${ZOT_HEALTH_INTERVAL:-30}"
TIMEOUT="${ZOT_HEALTH_TIMEOUT:-5}"

# Default to 'serve /etc/zot/config.json' if no arguments are provided
if [ $# -eq 0 ]; then
    set -- serve /etc/zot/config.json
fi

/bin/zot "$@" &
ZOT_PID=$!

# Stop zot with us rather than leaving it orphaned when Talos stops the service
trap 'kill "$ZOT_PID" 2>/dev/null; exit 0' TERM INT

echo "zot started in background with PID $ZOT_PID"

# Find the config file among the arguments to read the port and scheme from
CONFIG_FILE=""
for arg in "$@"; do
    if [ -f "$arg" ]; then
        CONFIG_FILE="$arg"
    fi
done

# zot writes the port either quoted ("port": "5000") or bare ("port": 5000)
PORT="${ZOT_HEALTH_PORT:-}"
if [ -z "$PORT" ] && [ -n "$CONFIG_FILE" ]; then
    PORT=$(grep '"port"' "$CONFIG_FILE" |
        sed -n 's/.*"port"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9]\{1,\}\)"\{0,1\}.*/\1/p' |
        head -n 1)
fi
PORT="${PORT:-5000}"

SCHEME="${ZOT_HEALTH_SCHEME:-}"
if [ -z "$SCHEME" ]; then
    SCHEME=http
    if [ -n "$CONFIG_FILE" ] && grep -q '"tls"' "$CONFIG_FILE"; then
        SCHEME=https
    fi
fi

WGET_OPTS=""
if [ "$SCHEME" = "https" ]; then
    WGET_OPTS="--no-check-certificate"
fi

echo "monitoring zot at $SCHEME://127.0.0.1:$PORT/v2/ every ${INTERVAL}s"

while true; do
    sleep "$INTERVAL"

    # Did zot crash or exit on its own?
    if ! kill -0 "$ZOT_PID" 2>/dev/null; then
        echo "CRITICAL: zot process died unexpectedly. Exiting."
        exit 1
    fi

    # Is it still answering? Any HTTP status means zot accepted the connection
    # and replied, so a 401 from a registry with auth enabled is as healthy as a
    # 200. Only a timeout or a refused connection is a failure -- that is what
    # separates a hung zot from a running one, and why this is not a port check.
    if ! wget -T "$TIMEOUT" -S $WGET_OPTS -O /dev/null \
        "$SCHEME://127.0.0.1:$PORT/v2/" 2>&1 | grep -q "HTTP/"; then
        echo "CRITICAL: zot stopped answering on port $PORT. Killing it and exiting."
        kill -9 "$ZOT_PID" 2>/dev/null
        exit 1
    fi
done
