#!/bin/bash
# MTU Discovery Script
# Usage: ./mtu-discover.sh <target_ip>
# Author: David Nemecek | Feb 2026

TARGET=${1:-"8.8.8.8"}
MIN=1200
MAX=1500
TIMEOUT=2
COUNT=2

echo "MTU Discovery for $TARGET"
echo "========================="
echo ""

# Binary search for optimal MTU
while [ $((MAX - MIN)) -gt 1 ]; do
    MID=$(( (MIN + MAX) / 2 ))
    
    if ping -D -s $MID -c $COUNT -t $TIMEOUT $TARGET >/dev/null 2>&1; then
        echo "Payload $MID: OK"
        MIN=$MID
    else
        echo "Payload $MID: FAIL"
        MAX=$MID
    fi
done

# Final verification
echo ""
echo "Final verification..."
if ping -D -s $MIN -c 3 -t $TIMEOUT $TARGET >/dev/null 2>&1; then
    OPTIMAL_MTU=$((MIN + 28))
    echo ""
    echo "========================="
    echo "Results:"
    echo "  Max payload: $MIN bytes"
    echo "  Optimal MTU: $OPTIMAL_MTU bytes"
    echo "========================="
else
    echo "ERROR: Could not determine MTU"
    exit 1
fi