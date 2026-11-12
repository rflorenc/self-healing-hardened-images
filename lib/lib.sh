#!/usr/bin/env bash
# Shared helpers; sourced through lib/env.sh
# shellcheck shell=bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
OWNER_LABEL=app.kubernetes.io/managed-by=cve-demo-setup

say()  { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

load_env() {
  if [[ -f "${REPO_ROOT}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/.env"
    set +a
  fi
}

need() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
  done
}

require_cluster() {
  need oc
  oc whoami >/dev/null 2>&1 || die "not logged in: run 'oc login' first"
}

render() {  # render <file> <VAR>...: the file with only the named ${VAR} placeholders filled in
  local f=$1 v; shift
  local args=()
  for v in "$@"; do args+=("$v=${!v}"); done
  python3 -c '
import sys
s=open(sys.argv[1]).read()
for kv in sys.argv[2:]:
    k,v=kv.split("=",1); s=s.replace("${"+k+"}",v)
sys.stdout.write(s)' "$f" ${args[@]+"${args[@]}"}
}

mkns() {  # mkns <namespace>: create it labelled as ours, leave an existing one untouched
  oc get ns "$1" >/dev/null 2>&1 && return 0
  oc create ns "$1" >/dev/null && oc label ns "$1" "$OWNER_LABEL" >/dev/null
}

ours() {  # ours <kind> <name> [-n ns]: true if setup created it
  [ "$(oc get "$@" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)" = cve-demo-setup ]
}

wait_until() {  # wait_until <seconds> <command...>: poll every 10 s
  local end=$(( $(date +%s) + $1 )); shift
  until "$@"; do [ "$(date +%s)" -ge "$end" ] && return 1; sleep 10; done
}

http_code() { curl -sk -o /dev/null -w '%{http_code}' -m 10 "$@"; }

# installed CSV phase of an operator, looked up through its Subscription
csv_phase() {  # csv_phase <package>
  local ns csv
  read -r ns csv < <(oc get subscriptions.operators.coreos.com -A \
    -o jsonpath="{range .items[?(@.spec.name=='$1')]}{.metadata.namespace} {.status.installedCSV}{\"\\n\"}{end}" 2>/dev/null | head -1) || true
  [ -n "${csv:-}" ] && oc get csv "$csv" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true
}

acs() { curl -sSk -m 90 -u "admin:$ACS_PASS" -H 'Content-Type: application/json' "$@"; }
gitea() { curl -sS -u "$GITEA_USER:$GITEA_PASS" -H 'Content-Type: application/json' "$@"; }

tpa_api() {  # tpa_api <METHOD> <path> [curl args]: TPA API as client cli of realm tpa
  local m=$1 p=$2 s t; shift 2
  s=$(oc get secret tpa-cli-client -n "$TPA_NS" -o jsonpath='{.data.client-secret}' | base64 -d)
  t=$(curl -s -m 30 -d grant_type=client_credentials -d client_id=cli --data-urlencode "client_secret=$s" \
    "https://keycloak-$KC_NS.$DOMAIN/realms/tpa/protocol/openid-connect/token" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])') || die "no token for client cli (realm tpa)"
  curl -sS -m 120 -X "$m" -H "Authorization: Bearer $t" "https://server-$TPA_NS.$DOMAIN$p" "$@"
}

acs_scanner_ready() {  # wait for Scanner V4's first vulnerability load, refresh its statistics, smoke-test a scan
  local start l restarts pw code pf
  say "ACS Scanner V4: waiting for the first vulnerability load, about 45 minutes after install"
  start=$(date +%s)
  until l=$(oc logs -n "$ACS_NS" -l app=scanner-v4-matcher --tail=-1 2>/dev/null || true); [[ $l == *"setting to initialized"* ]]; do
    restarts=$(oc get pods -n "$ACS_NS" -l app=scanner-v4-matcher -o jsonpath='{range .items[*]}{.status.containerStatuses[0].lastState.terminated.reason}{" "}{end}')
    case "$restarts" in *OOMKilled*) warn "matcher was OOM-killed: check its memory limit, oc get central -n $ACS_NS -o yaml";; esac
    [ $(( $(date +%s) - start )) -gt 5400 ] && die "matcher not initialized after 90 minutes: oc logs -n $ACS_NS -l app=scanner-v4-matcher"
    printf '    %s min, still loading\n' $(( ($(date +%s) - start) / 60 )); sleep 60
  done
  ok "vulnerability data loaded"
  # first scans otherwise take minutes
  pw=$(oc get secret scanner-v4-db-password -n "$ACS_NS" -o jsonpath='{.data.password}' | base64 -d)
  oc exec -n "$ACS_NS" deploy/scanner-v4-db -c db -- env PGPASSWORD="$pw" psql -h 127.0.0.1 -U postgres -q \
    -c "ANALYZE vulnerability_alias" -c "ANALYZE vulnerability_self" -c "ANALYZE uo_enrich" >/dev/null
  oc port-forward -n "$ACS_NS" svc/central 18443:443 >/dev/null 2>&1 & pf=$!
  sleep 3
  code=$(curl -sk -m 170 -o /tmp/cve-demo-smoke.json -w '%{http_code}' -u "admin:$ACS_PASS" \
    -X POST https://127.0.0.1:18443/v1/images/scan -d "{\"imageName\":\"${BASE_REPO}:${BASE_STREAM}\",\"force\":true}" || true)
  kill "$pf" 2>/dev/null || true
  [ "$code" = 200 ] || die "ACS smoke-test scan failed, HTTP $code: $(head -c 300 /tmp/cve-demo-smoke.json 2>/dev/null)"
  ok "ACS scans images: $(python3 -c 'import json; d=json.load(open("/tmp/cve-demo-smoke.json")); print(len(d["scan"]["components"]), "components")')"
  rm -f /tmp/cve-demo-smoke.json
}

# file:package for every operator the demo needs, in install order
DEMO_OPERATORS="pipelines:openshift-pipelines-operator-rh gitops:openshift-gitops-operator acs:rhacs-operator
  gitea:gitea-operator odf:odf-operator quay:quay-operator rhbk:rhbk-operator rhtas:rhtas-operator rhtpa:rhtpa-operator"
RHBK_CHANNEL=stable-v26.6

odf_channel() { echo "stable-$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1,2)"; }

installed() {  # installed <package>: rhbk counts only in our namespace, another Keycloak operator may run elsewhere
  if [ "$1" = rhbk-operator ]; then oc get subscriptions.operators.coreos.com rhbk-operator -n "$KC_NS" >/dev/null 2>&1; return; fi
  local subs; subs=$(oc get subscriptions.operators.coreos.com -A -o jsonpath='{range .items[*]}{.spec.name}{"\n"}{end}')
  grep -qx "$1" <<<"$subs"
}
subns() {  # subns <package>: namespace of its subscription
  if [ "$1" = rhbk-operator ]; then echo "$KC_NS"; return; fi
  oc get subscriptions.operators.coreos.com -A -o jsonpath="{range .items[?(@.spec.name=='$1')]}{.metadata.namespace}{end}"
}
subname() {  # subname <package>: name of its subscription, which need not match the package
  oc get subscriptions.operators.coreos.com -n "$(subns "$1")" -o jsonpath="{range .items[?(@.spec.name=='$1')]}{.metadata.name}{end}"
}
pinned_csv() { sed -n 's/^  startingCSV: \([^ ]*\).*/\1/p' "$REPO_ROOT/manifests/01-operators/$1.yaml"; }
pinned_channel() { render "$REPO_ROOT/manifests/01-operators/$1.yaml" ODF_CHANNEL | sed -n 's/^  channel: \([^ ]*\).*/\1/p'; }

og_conflict() {  # og_conflict <file>: prints another OperatorGroup in the namespace we would install into
  local ns og o
  ns=$(sed -n '/^kind: OperatorGroup/,/^---/s/^  namespace: //p' "$REPO_ROOT/manifests/01-operators/$1.yaml" | head -1)
  og=$(sed -n '/^kind: OperatorGroup/,/^---/s/^  name: //p' "$REPO_ROOT/manifests/01-operators/$1.yaml" | head -1)
  [ -n "$ns" ] || return 0
  ns=${ns//\$\{KC_NS\}/$KC_NS}; og=${og//\$\{KC_NS\}/$KC_NS}
  for o in $(oc get operatorgroups -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    [ "$o" = "$og" ] || { echo "$ns/$o"; return 0; }
  done
}
other_rhbk() {  # prints namespace=channel of every Keycloak operator outside our namespace
  local o
  for o in $(oc get subscriptions.operators.coreos.com -A -o jsonpath="{range .items[?(@.spec.name=='rhbk-operator')]}{.metadata.namespace}={.spec.channel} {end}"); do
    [ "${o%%=*}" = "$KC_NS" ] || echo "$o"
  done
}

console_plugin() {  # console_plugin enable|disable <name>: the console loads a plugin only once it is listed here
  local have
  oc get consoleplugin "$2" >/dev/null 2>&1 || [ "$1" = disable ] || return 0
  have=$(oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}')
  python3 - "$1" "$2" "$have" <<'PY' | oc patch consoles.operator.openshift.io cluster --type merge --patch-file /dev/stdin >/dev/null
import json, sys
mode, name, have = sys.argv[1], sys.argv[2], json.loads(sys.argv[3] or "[]")
want = have + [name] if mode == "enable" and name not in have else [p for p in have if p != name] if mode == "disable" else have
print(json.dumps({"spec": {"plugins": want}}))
PY
}
