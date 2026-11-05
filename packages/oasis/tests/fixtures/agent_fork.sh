#!/bin/sh
# Forks a long-lived child (like gemini's re-exec'd node process), records
# its pid in $1, then hangs so the watchdog has to fire.
sleep 60 &
echo $! > "$1"
sleep 60
