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
