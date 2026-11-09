#!/usr/bin/env bash
# Phase 7: realm tpa, PostgreSQL, NooBaa bucket and Trusted Profile Analyzer
cd "$(dirname "$0")/.." && . lib/env.sh
require_cluster
KC_HOST="keycloak-$KC_NS.$DOMAIN"
TPA_HOST="server-$TPA_NS.$DOMAIN"
gen() {  # gen <namespace> <secret> <key>: random value, created once
  oc get secret "$2" -n "$1" >/dev/null 2>&1 || oc create secret generic "$2" -n "$1" \
    --from-literal="$3"="$(openssl rand -hex 24)" >/dev/null
}

say "Keycloak realm tpa"
gen "$KC_NS" tpa-cli-client client-secret
gen "$KC_NS" tpa-auditor password
render manifests/07-tpa/realm-tpa.yaml KC_NS TPA_HOST | oc apply -f - >/dev/null
for _ in $(seq 1 30); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://$KC_HOST/realms/tpa/.well-known/openid-configuration")" = 200 ] && break; sleep 10
done
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://$KC_HOST/realms/tpa/.well-known/openid-configuration")" = 200 ] \
  || die "realm tpa not imported: oc get keycloakrealmimport tpa -n $KC_NS -o yaml"
mkns "$TPA_NS"
oc get secret tpa-cli-client -n "$KC_NS" -o json | python3 -c '
import sys,json
s=json.load(sys.stdin); s["metadata"]={"name":"tpa-cli-client","namespace":sys.argv[1]}; print(json.dumps(s))' "$TPA_NS" \
  | oc apply -f - >/dev/null
ok "realm tpa: https://$KC_HOST/realms/tpa"

say "PostgreSQL and NooBaa bucket for Trusted Profile Analyzer"
oc get secret postgres -n "$TPA_NS" >/dev/null 2>&1 || oc create secret generic postgres -n "$TPA_NS" \
  --from-literal=username=trustify --from-literal=password="$(openssl rand -hex 24)" >/dev/null
PG_NS=$TPA_NS; PG_DB=trustify
render manifests/common/postgres.yaml PG_NS PG_DB | oc apply -f - >/dev/null
cat <<EOF | oc apply -f - >/dev/null
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata: {name: tpa-storage, namespace: $TPA_NS}
spec: {generateBucketName: tpa, storageClassName: openshift-storage.noobaa.io}
EOF
oc rollout status statefulset/postgres -n "$TPA_NS" --timeout=300s >/dev/null || die "PostgreSQL not ready: oc get pods -n $TPA_NS"
for _ in $(seq 1 30); do
  [ "$(oc get obc tpa-storage -n "$TPA_NS" -o jsonpath='{.status.phase}' 2>/dev/null)" = Bound ] && break; sleep 5
done
TPA_BUCKET=$(oc get cm tpa-storage -n "$TPA_NS" -o jsonpath='{.data.BUCKET_NAME}' 2>/dev/null)
[ -n "$TPA_BUCKET" ] || die "bucket claim tpa-storage not bound: oc get obc tpa-storage -n $TPA_NS -o yaml"
ok "PostgreSQL ready, bucket $TPA_BUCKET on NooBaa"

say "Trusted Profile Analyzer at https://$TPA_HOST"
render manifests/07-tpa/tpa.yaml TPA_NS DOMAIN KC_HOST TPA_BUCKET | oc apply -f - >/dev/null
for _ in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://$TPA_HOST/")" = 200 ] && break; sleep 10
done
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://$TPA_HOST/")" = 200 ] \
  || die "Trusted Profile Analyzer not reachable after 10 minutes: oc get pods,jobs -n $TPA_NS; oc get trustedprofileanalyzer tpa -n $TPA_NS -o yaml"
ok "Trusted Profile Analyzer ready: https://$TPA_HOST (user auditor)"
