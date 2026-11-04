#!/bin/sh
# Answers, then exits while a background helper keeps stdout open
# (like cursor-agent's daemonized worker-server).
sleep 30 &
echo "answer from lingering agent"
exit 0
