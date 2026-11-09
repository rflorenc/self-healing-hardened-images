#!/usr/bin/env bash
# tpa-api.sh METHOD path [curl args]: call the Trusted Profile Analyzer API as client cli of realm tpa
cd "$(dirname "$0")/.." && . lib/env.sh
tpa_api "$@"
