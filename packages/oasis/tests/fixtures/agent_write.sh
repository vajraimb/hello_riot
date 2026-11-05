#!/bin/sh
# writes a file into its working directory and reports where it ran
echo "turn" >> notes.txt
mkdir -p src && echo "let x = 1" > src/main.ml
echo "cwd=$(pwd)"
