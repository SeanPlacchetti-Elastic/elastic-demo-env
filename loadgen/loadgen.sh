#!/bin/sh
# ─── Traffic generator for the Elastic Observability demo ─────────────────────
set -eu

DEV_GW="${DEV_GATEWAY_URL:-https://east-gateway:8000}"
PROD_GW="${PROD_GATEWAY_URL:-https://prod-gateway:8000}"
WEST_APP="${WEST_WEBAPP_URL:-https://west-webapp:8000}"
INTERVAL="${LOADGEN_INTERVAL:-3}"
CA_CERT="/usr/share/certs/ca/ca.crt"

echo "[loadgen] Starting traffic generator"
echo "[loadgen]   dev gateway:  $DEV_GW"
echo "[loadgen]   prod gateway: $PROD_GW"
echo "[loadgen]   west webapp:  $WEST_APP"
echo "[loadgen]   interval:     ${INTERVAL}s"

C="curl -sf --cacert $CA_CERT --max-time 8"

cycle=0
while true; do
    cycle=$((cycle + 1))

    # ── Aircraft registry search queries (rotated by cycle) ──────────────
    # These drive traffic through all three search modes against the aircraft
    # index so APM captures search spans and ML has latency data to train on.
    SEARCH_TERMS="KC-135 tanker boom Pegasus Stratotanker F-16 striker B-52 bomber Extender receiver"
    TERM=$(echo $SEARCH_TERMS | tr ' ' '\n' | sed -n "$((cycle % 10 + 1))p")
    SEARCH_MODE=$((cycle % 3))
    if [ "$SEARCH_MODE" -eq 0 ]; then
        $C "$DEV_GW/search?q=$(echo "$TERM" | sed 's/ /%20/g')"           -o /dev/null 2>/dev/null &
        $C "$PROD_GW/search?q=$(echo "$TERM" | sed 's/ /%20/g')"          -o /dev/null 2>/dev/null &
    elif [ "$SEARCH_MODE" -eq 1 ]; then
        $C "$DEV_GW/search/asyoutype?q=$(echo "$TERM" | sed 's/ /%20/g')" -o /dev/null 2>/dev/null &
        $C "$PROD_GW/search/asyoutype?q=$(echo "$TERM" | sed 's/ /%20/g')" -o /dev/null 2>/dev/null &
    else
        $C "$DEV_GW/search/typeahead?q=$(echo "$TERM" | sed 's/ /%20/g')" -o /dev/null 2>/dev/null &
        $C "$PROD_GW/search/typeahead?q=$(echo "$TERM" | sed 's/ /%20/g')" -o /dev/null 2>/dev/null &
    fi

    # ── Development gateway (anomalies enabled) ───────────────────────────
    $C "$DEV_GW/catalog"         -o /dev/null 2>/dev/null &
    $C "$DEV_GW/inventory"       -o /dev/null 2>/dev/null &
    $C "$DEV_GW/pricing"         -o /dev/null 2>/dev/null &
    $C "$DEV_GW/reviews"         -o /dev/null 2>/dev/null &
    $C "$DEV_GW/orders"          -o /dev/null 2>/dev/null &
    $C "$DEV_GW/recommendations" -o /dev/null 2>/dev/null &

    # ── Production gateway (stable) ───────────────────────────────────────
    $C "$PROD_GW/catalog"         -o /dev/null 2>/dev/null &
    $C "$PROD_GW/inventory"       -o /dev/null 2>/dev/null &
    $C "$PROD_GW/pricing"         -o /dev/null 2>/dev/null &
    $C "$PROD_GW/reviews"         -o /dev/null 2>/dev/null &
    $C "$PROD_GW/orders"          -o /dev/null 2>/dev/null &
    $C "$PROD_GW/recommendations" -o /dev/null 2>/dev/null &

    # ── West webapp ───────────────────────────────────────────────────────
    $C "$WEST_APP/"               -o /dev/null 2>/dev/null &

    # Every 20th cycle, trigger error + custom message on dev only
    if [ $((cycle % 20)) -eq 0 ]; then
        $C "$DEV_GW/error"       -o /dev/null 2>/dev/null &
        $C "$WEST_APP/error"     -o /dev/null 2>/dev/null &
    fi

    # Every 5th cycle, burst traffic on both
    if [ $((cycle % 5)) -eq 0 ]; then
        for _ in 1 2 3; do
            $C "$DEV_GW/catalog"   -o /dev/null 2>/dev/null &
            $C "$PROD_GW/catalog"  -o /dev/null 2>/dev/null &
        done
    fi

    wait
    sleep "$INTERVAL"
done
