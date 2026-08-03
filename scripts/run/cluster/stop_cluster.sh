#!/usr/bin/env bash

# Find the directory where this script is located
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Call the main script with the stop argument
if [ -f "$DIR/launch_cluster.sh" ]; then
    "$DIR/launch_cluster.sh" stop
else
    echo "❌ Error: launch_cluster.sh not found in $DIR"
    exit 1
fi
