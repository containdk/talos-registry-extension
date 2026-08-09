#!/bin/sh

# Start zot in the background
# Default to 'serve /etc/zot/config.json' if no arguments are provided
if [ $# -eq 0 ]; then
    /bin/zot serve /etc/zot/config.json &
    CONFIG_FILE="/etc/zot/config.json"
else
    /bin/zot "$@" &
    # Try to find the config file in the arguments
    for arg in "$@"; do
        if [ -f "$arg" ]; then
            CONFIG_FILE="$arg"
        fi
    done
fi
ZOT_PID=$!

echo "Zot registry started in background with PID $ZOT_PID"

# Default port
PORT=5000
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    # Extract port from config file using sed
    EXTRACTED_PORT=$(grep '"port"' "$CONFIG_FILE" | sed -n 's/.*"port":\s*"\([0-9]*\)".*/\1/p' | head -n 1)
    if [ -n "$EXTRACTED_PORT" ]; then
        PORT=$EXTRACTED_PORT
    fi
fi

echo "Monitoring Zot on port $PORT..."

# Infinite loop to monitor health
while true; do
  # Wait 30 seconds between checks
  sleep 30
  
  # Check 1: Did the Zot process crash or exit on its own?
  if ! kill -0 $ZOT_PID 2>/dev/null; then
    echo "CRITICAL: Zot process died unexpectedly. Exiting."
    exit 1
  fi

  # Check 2: Is the API actually responding? (Prevents silent deadlocks/hangs)
  # We try both http and https just in case
  if ! wget -q -O- "http://127.0.0.1:$PORT/v2/" > /dev/null 2>&1; then
    if ! wget -q -O- --no-check-certificate "https://127.0.0.1:$PORT/v2/" > /dev/null 2>&1; then
      echo "CRITICAL: Zot API health check failed on port $PORT!"
      echo "Killing Zot and forcing exit..."
      kill -9 $ZOT_PID
      exit 1
    fi
  fi
done
