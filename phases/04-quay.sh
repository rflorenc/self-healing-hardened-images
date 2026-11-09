#!/usr/bin/env bash
# Phase 4: Quay on NooBaa, organisation cve-demo and robot accounts
cd "$(dirname "$0")/.." && . lib/env.sh
require_cluster

say "Quay in namespace $QUAY_NS"
mkns "$QUAY_NS"
if ! oc get secret quay-config-bundle -n "$QUAY_NS" >/dev/null 2>&1; then
  # FEATURE_USER_INITIALIZE lets the API create the first user once
  oc create secret generic quay-config-bundle -n "$QUAY_NS" --from-literal=config.yaml='FEATURE_USER_INITIALIZE: true
SUPER_USERS: [quayadmin]
FEATURE_USER_CREATION: false
BROWSER_API_CALLS_XHR_ONLY: false
CREATE_PRIVATE_REPO_ON_PUSH: true
TAG_EXPIRATION_OPTIONS: [2w, 4w]
' >/dev/null
fi
render manifests/04-quay/quay.yaml QUAY_NS | oc apply -f - >/dev/null
# after a change the old Quay pods still answer
for _ in $(seq 1 30); do oc get deploy registry-quay-app -n "$QUAY_NS" >/dev/null 2>&1 && break; sleep 10; done
for d in registry-quay-database registry-quay-app; do
  oc rollout status "deploy/$d" -n "$QUAY_NS" --timeout=600s >/dev/null 2>&1 || true
done
host=""
for _ in $(seq 1 90); do
  host=$(oc get quayregistry registry -n "$QUAY_NS" -o jsonpath='{.status.registryEndpoint}' 2>/dev/null | sed 's#^https://##')
  [ -n "$host" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://$host/health/instance")" = 200 ] && break; sleep 10
done
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://${host:-none}/health/instance")" = 200 ] \
  || die "Quay not healthy after 15 minutes: oc get quayregistry registry -n $QUAY_NS -o yaml; oc get pods -n $QUAY_NS"
ok "Quay ready: https://$host"

if ! oc get secret quay-admin -n "$QUAY_NS" >/dev/null 2>&1; then
  say "first Quay user: quayadmin (superuser)"
  pw=$(openssl rand -base64 18 | tr -d '/+=')
  token=$(curl -sS -m 30 -H 'Content-Type: application/json' -X POST "https://$host/api/v1/user/initialize" \
    -d "{\"username\":\"quayadmin\",\"password\":\"$pw\",\"email\":\"quayadmin@cve-demo.local\",\"access_token\":true}" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))')
  [ -n "$token" ] || die "Quay user initialisation failed (only possible on an empty Quay): https://$host/api/v1/user/initialize"
  oc create secret generic quay-admin -n "$QUAY_NS" --from-literal=username=quayadmin \
     --from-literal=password="$pw" --from-literal=token="$token" >/dev/null
fi
if oc get secret quay-robot-pipeline -n "$QUAY_NS" >/dev/null 2>&1 && oc get secret quay-robot-puller -n "$QUAY_NS" >/dev/null 2>&1; then
  # the first-user token expires; with the robots in place no API calls are needed
  ok "organisation $QUAY_ORG and robot accounts already set up (secrets quay-robot-pipeline, quay-robot-puller)"
  exit 0
fi
T=$(oc get secret quay-admin -n "$QUAY_NS" -o jsonpath='{.data.token}' | base64 -d)
q() { curl -sS -m 30 -H "Authorization: Bearer $T" -H 'Content-Type: application/json' "$@"; }
A="https://$host/api/v1"

say "organisation $QUAY_ORG, repository app, robot accounts"
[ "$(q -o /dev/null -w '%{http_code}' "$A/organization/$QUAY_ORG")" = 200 ] \
  || q -X POST "$A/organization/" -d "{\"name\":\"$QUAY_ORG\",\"email\":\"$QUAY_ORG@cve-demo.local\"}" -o /dev/null
[ "$(q -o /dev/null -w '%{http_code}' "$A/repository/$QUAY_ORG/app")" = 200 ] \
  || q -X POST "$A/repository" -d "{\"namespace\":\"$QUAY_ORG\",\"repository\":\"app\",\"visibility\":\"private\",
       \"description\":\"BO1122 demo app: rebuilt on every new Red Hat Hardened Images base, signed by the pipeline\"}" -o /dev/null
robot() {  # robot <name> <read|write>: robot account with that role on app, docker config secret quay-robot-<name>
  local r="$1" role="$2" tok
  [ "$(q -o /dev/null -w '%{http_code}' "$A/organization/$QUAY_ORG/robots/$r")" = 200 ] \
    || q -X PUT "$A/organization/$QUAY_ORG/robots/$r" -d "{\"description\":\"cve-demo $r\"}" -o /dev/null
  q -X PUT "$A/repository/$QUAY_ORG/app/permissions/user/$QUAY_ORG+$r" -d "{\"role\":\"$role\"}" -o /dev/null
  tok=$(q "$A/organization/$QUAY_ORG/robots/$r" | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')
  oc create secret docker-registry "quay-robot-$r" -n "$QUAY_NS" --docker-server="$host" \
     --docker-username="$QUAY_ORG+$r" --docker-password="$tok" --dry-run=client -o yaml | oc apply -f - >/dev/null
  ok "robot $QUAY_ORG+$r ($role on $QUAY_ORG/app) -> secret $QUAY_NS/quay-robot-$r"
}
robot pipeline write
robot puller read
ok "Quay ready for the demo: $host/$QUAY_ORG/app"
