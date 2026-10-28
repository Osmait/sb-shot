#!/bin/bash
# Prints the CHANGELOG.md section for a version, for the release notes.
#
#   scripts/changelog.sh 0.2.0
set -euo pipefail

VERSION="${1:?Usage: scripts/changelog.sh <version>}"
VERSION="${VERSION#v}"

awk -v version="$VERSION" '
    /^## \[/ { printing = ($0 ~ "^## \\[" version "\\]") ; next }
    printing
' "$(dirname "$0")/../CHANGELOG.md" | sed -e '/./,$!d'
