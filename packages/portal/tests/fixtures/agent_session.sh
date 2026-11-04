#!/bin/sh
# announces a CLI session like claude/cursor-agent do, then echoes its argv
echo '{"type":"system","subtype":"init","session_id":"sess-42"}'
echo "args: $*"
