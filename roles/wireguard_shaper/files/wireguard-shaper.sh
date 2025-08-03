#!/bin/bash

# --- Configuration ---
WG_INTERFACE="wg0"
SHAPER_PERCENTAGE=90
IPERF_STREAMS=10

# --- Script Logic ---
echo "Starting WireGuard shaping run on $WG_INTERFACE..."

# Use the improved command to get active client IPs
CLIENT_IPS=$(sudo wg show $WG_INTERFACE dump | awk '$4!="off"{print $4}' | sed 's#/[^ ]*##g')

if [ -z "$CLIENT_IPS" ]; then
    echo "No clients connected."
    exit 0
fi

for CLIENT_IP in $CLIENT_IPS; do
    CLASS_SUFFIX=$(echo $CLIENT_IP | cut -d . -f 4)
    FILTER_PRIO=$CLASS_SUFFIX

    echo "--- Processing Client: $CLIENT_IP ---"

    # --- REMOVE EXISTING SHAPER BEFORE TESTING ---
    echo "Removing any old shaping rule for $CLIENT_IP..."
    sudo tc filter del dev $WG_INTERFACE parent 1:0 protocol ip prio $FILTER_PRIO u32 > /dev/null 2>&1
    sudo tc class del dev $WG_INTERFACE parent 1: classid 1:1$CLASS_SUFFIX > /dev/null 2>&1
    
    # --- RUN THE TEST ---
    IPERF_RESULT=$(iperf -M 1200 -c $CLIENT_IP -P $IPERF_STREAMS -t 5 -f m)
    
    RATE=$(echo "$IPERF_RESULT" | grep "SUM" | tail -1 | awk '{print $6}')

    # --- APPLY NEW SHAPER IF TEST SUCCEEDED ---
    if [[ -n "$RATE" && "$RATE" =~ ^[0-9.]+$ ]]; then
        SHAPER_RATE=$(echo "$RATE * $SHAPER_PERCENTAGE / 100" | bc -l | xargs printf "%.0f")
        [ "$SHAPER_RATE" -eq 0 ] && SHAPER_RATE=1
        
        echo "Measured speed: $RATE Mbps. Applying new shaper at $SHAPER_RATE Mbit/s."

        sudo tc class replace dev $WG_INTERFACE parent 1: classid 1:1$CLASS_SUFFIX htb rate ${SHAPER_RATE}mbit
        sudo tc qdisc replace dev $WG_INTERFACE parent 1:1$CLASS_SUFFIX cake
        sudo tc filter replace dev $WG_INTERFACE protocol ip parent 1:0 prio $FILTER_PRIO u32 match ip dst $CLIENT_IP/32 flowid 1:1$CLASS_SUFFIX
    else
        echo "iperf test failed for $CLIENT_IP. Client remains un-shaped."
    fi
done

echo "--- Run Complete ---"