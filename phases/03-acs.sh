#!/usr/bin/env bash
# Phase 3: ACS Central and secured cluster, demo-sized, ready to scan
cd "$(dirname "$0")/.." && . lib/env.sh
require_cluster

existing=$(oc get central -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | head -1 || true)
if [ -n "$existing" ] && [ "$existing" != "$ACS_NS" ]; then
  die "Central already runs in namespace '$existing': set ACS_NS=$existing in .env and re-run"
fi

say "Central in namespace $ACS_NS"
mkns "$ACS_NS"
if ! oc get secret central-admin-password -n "$ACS_NS" >/dev/null 2>&1; then
  oc create secret generic central-admin-password -n "$ACS_NS" \
     --from-literal=password="$(openssl rand -base64 18 | tr -d '/+=')" >/dev/null
fi
if [ -z "$existing" ]; then render manifests/03-acs/central.yaml ACS_NS ACS_CLUSTER | oc apply -f - >/dev/null
else
  say "Central exists: Scanner V4 matcher at 8 GiB , demo resource sizes"
  # resources and scaling only: volume sizes cannot change on an existing install
  oc patch central -n "$ACS_NS" "$(oc get central -n "$ACS_NS" -o name | head -1 | cut -d/ -f2)" --type merge -p '{"spec":{
    "central":{"resources":{"requests":{"cpu":"1","memory":"2Gi"},"limits":{"memory":"4Gi"}},
               "db":{"resources":{"requests":{"cpu":"1","memory":"2Gi"},"limits":{"memory":"8Gi"}}}},
    "scannerV4":{"indexer":{"scaling":{"autoScaling":"Disabled","replicas":1},
                            "resources":{"requests":{"cpu":"500m","memory":"1Gi"},"limits":{"memory":"4Gi"}}},
                 "matcher":{"scaling":{"autoScaling":"Disabled","replicas":1},
                            "resources":{"requests":{"cpu":"1","memory":"4Gi"},"limits":{"cpu":"4","memory":"8Gi"}}}}}}' >/dev/null
fi
for _ in $(seq 1 60); do
  [ "$(oc get deploy central -n "$ACS_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 1 ] && break; sleep 10
done
# after a resize the old pods still report ready
for d in central-db central scanner-v4-indexer scanner-v4-matcher; do
  oc rollout status "deploy/$d" -n "$ACS_NS" --timeout=600s >/dev/null 2>&1 || true
done
[ "$(oc get deploy central -n "$ACS_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 1 ] \
  || die "Central not ready after 10 minutes: oc get pods -n $ACS_NS"
ok "Central ready"
. lib/env.sh   # Central's route and admin password exist now

say "Secured cluster '$ACS_CLUSTER' in Central's namespace"
if ! oc get secret sensor-tls -n "$ACS_NS" >/dev/null 2>&1; then
  # the operator does not create an init bundle itself, so ask Central for one
  resp=$(curl -sSk -m 60 -u "admin:$ACS_PASS" -H 'Content-Type: application/json' -X POST "$ACS_URL/v1/cluster-init/init-bundles" \
    -d "{\"name\":\"$ACS_CLUSTER-$(date +%s)\"}")
  python3 -c 'import sys,json,base64; print(base64.b64decode(json.loads(sys.argv[1])["kubectlBundle"]).decode())' "$resp" \
    | oc apply -n "$ACS_NS" -f - >/dev/null || die "init bundle from Central failed: ${resp:0:300}"
  oc annotate securedcluster --all -n "$ACS_NS" cve-demo/init-bundle="$(date +%s)" --overwrite >/dev/null   # an existing one retries now
  ok "init bundle applied"
fi
if [ -z "$(oc get securedcluster -n "$ACS_NS" -o name 2>/dev/null)" ]; then
  render manifests/03-acs/securedcluster.yaml ACS_NS ACS_CLUSTER | oc apply -f - >/dev/null
else
  oc patch securedcluster -n "$ACS_NS" "$(oc get securedcluster -n "$ACS_NS" -o name | head -1 | cut -d/ -f2)" --type merge \
    -p '{"spec":{"sensor":{"resources":{"requests":{"cpu":"500m","memory":"1Gi"},"limits":{"memory":"4Gi"}}}}}' >/dev/null
fi
for _ in $(seq 1 60); do
  [ "$(oc get deploy sensor -n "$ACS_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 1 ] \
    && [ -n "$(oc get validatingwebhookconfiguration stackrox -o name 2>/dev/null)" ] && break; sleep 10
done
[ "$(oc get deploy sensor -n "$ACS_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 1 ] \
  || die "Sensor not ready after 10 minutes: oc get pods -n $ACS_NS; oc logs deploy/sensor -n $ACS_NS"
ok "secured cluster connected, admission controller registered"
ok "ACS up; the first vulnerability load continues in the background, phase 10 waits for it"
