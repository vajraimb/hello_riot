#!/bin/sh
echo "HOME=$HOME"
echo "KEY=${DEEPSEEK_API_KEY:-unset}"
echo "PASS=${OASIS_PASS_TEST:-unset}"
echo "PATHSET=${PATH:+yes}"
echo "PWD=$(pwd)"
exit 0
