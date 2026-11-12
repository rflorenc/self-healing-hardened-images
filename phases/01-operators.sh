#!/usr/bin/env bash
# Phase 1: operators pinned to validated versions with manual install-plan approval
cd "$(dirname "$0")/.." && . lib/env.sh
require_cluster

approve_first() {  # approve_first <namespace> <subscription>: approves the initial InstallPlan if it holds only pinned versions
  local ip c op want
  for _ in $(seq 1 30); do
    ip=$(oc get subscriptions.operators.coreos.com "$2" -n "$1" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || true)
    [ -n "$ip" ] && break; sleep 5
  done
  [ -n "$ip" ] || die "no InstallPlan for $2 in $1: oc get subscription $2 -n $1 -o yaml"
  # OLM puts every pending change of a namespace into one plan, upgrades of other operators included
  for c in $(oc get installplan "$ip" -n "$1" -o jsonpath='{.spec.clusterServiceVersionNames[*]}'); do
    for op in $OPS; do
      want=$(pinned_csv "${op%%:*}")
      case $c in "${op#*:}".v*) [ -z "$want" ] || [ "$c" = "$want" ] \
        || die "install plan $ip in $1 also carries $c, the demo is validated on $want: not approved" ;; esac
    done
  done
  oc patch installplan "$ip" -n "$1" --type merge -p '{"spec":{"approved":true}}' >/dev/null
  ok "approved the first install of $2 ($ip)"
}

og_guard() {  # refuse to add a second OperatorGroup: OLM then fails every CSV in that namespace
  local c; c=$(og_conflict "$1")
  [ -z "$c" ] || die "OperatorGroup $c already exists where $2 would go; install $2 there by hand or remove it"
}
rhbk_guard() {  # a second Keycloak operator copy must use the same channel: both share the cluster-wide CRDs
  local o
  for o in $(other_rhbk); do
    [ "${o#*=}" = "$RHBK_CHANNEL" ] || die "another rhbk-operator in ${o%%=*} uses channel ${o#*=}; ours needs $RHBK_CHANNEL"
    ok "another Keycloak operator runs in ${o%%=*} on the same channel: installing our own copy in $KC_NS"
  done
}

wait_csv() {  # wait_csv <package>  until its CSV reports Succeeded (up to 10 minutes)
  for _ in $(seq 1 60); do
    phase=$(csv_phase "$1")
    [ "$phase" = Succeeded ] && { ok "$1 ready"; return 0; }
    sleep 10
  done
  die "$1 did not become ready within 10 minutes: oc get csv -A | grep $1"
}

ODF_CHANNEL=$(odf_channel)
OPS=$DEMO_OPERATORS
oc apply -f manifests/01-operators/pin-guard.yaml >/dev/null
ok "pin guard: warns on any of our subscriptions without Manual approval and a pinned startingCSV"
pending=""
for op in $OPS; do
  file=${op%%:*}; pkg=${op#*:}
  if installed "$pkg"; then
    if [ -z "$(oc get subscriptions.operators.coreos.com "$(subname "$pkg")" -n "$(subns "$pkg")" -o jsonpath='{.status.installedCSV}' 2>/dev/null)" ]; then
      pending="$pending $pkg"   # subscribed, first install still waiting: an interrupted earlier run
    else
      ok "$pkg already installed: leaving its configuration unchanged"
    fi
  else
    [ "$pkg" = rhbk-operator ] && rhbk_guard
    og_guard "$file" "$pkg"
    say "subscribing $pkg"; render "manifests/01-operators/$file.yaml" ODF_CHANNEL KC_NS | oc apply -f - >/dev/null
    pending="$pending $pkg"
  fi
  ap=$(oc get subscriptions.operators.coreos.com "$(subname "$pkg")" -n "$(subns "$pkg")" -o jsonpath='{.spec.installPlanApproval}' 2>/dev/null || true)
  [ "$ap" = Manual ] || warn "$pkg was installed by someone else with automatic upgrades: left as it is, it may change version under the demo"
done
# approve only once every subscription exists, so a shared namespace gets one plan with the pinned versions
for pkg in $pending; do
  approve_first "$(subns "$pkg")" "$(subname "$pkg")"
done
for op in $OPS; do
  wait_csv "${op#*:}"
done
for op in $OPS; do
  want=$(pinned_csv "${op%%:*}")
  have=$(oc get subscriptions.operators.coreos.com -n "$(subns "${op#*:}")" -o jsonpath="{range .items[?(@.spec.name=='${op#*:}')]}{.status.installedCSV}{end}")
  [ -z "$want" ] || [ "$want" = "$have" ] || warn "${op#*:} runs $have, the demo is validated on $want"
done
ok "operators ready"
