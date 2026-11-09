#!/usr/bin/env bash
# setup.sh [--from N] [--only N] [--dry-run]: phases 00 to 10 on an OpenShift cluster, then verify.sh
set -euo pipefail
cd "$(dirname "$0")"
from=0; only=""; dry=0
while [ $# -gt 0 ]; do
  case $1 in
    --from) from=$((10#$2)); shift 2 ;;
    --only) only=$((10#$2)); shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) echo "usage: setup.sh [--from N] [--only N] [--dry-run]" >&2; exit 2 ;;
  esac
done
for phase in phases/[0-9][0-9]-*.sh; do
  n=$((10#$(basename "$phase" | cut -c1-2)))
  if [ -n "$only" ]; then [ "$n" = "$only" ] || continue; else [ "$n" -ge "$from" ] || continue; fi
  printf '\n\033[1m=== %s\033[0m\n' "$phase"
  [ "$dry" = 1 ] || "$phase"
done
[ -n "$only" ] || [ "$dry" = 1 ] || { printf '\n\033[1m=== verify.sh\033[0m\n'; ./verify.sh; }
