#!/bin/bash
# Generates every character that has a Meshy prompt but no model yet. Double-click this file.
cd "$(dirname "$0")" || exit 1
python3 tools/make_character.py "${1:---all}" 2>&1 | tee meshy.log
