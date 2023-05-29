#!/bin/sh
#
# Usage:
#   ./tst-filter.sh filter < input-source
#
set -euf -o pipefail

t=$(mktemp -d)
trap 'exit 1' INT
trap 'rm -rf $t' EXIT

cat > "$t/source"
"$@" < "$t/source" > "$t/dest"
( cd $t ; diff --color -u source dest )

