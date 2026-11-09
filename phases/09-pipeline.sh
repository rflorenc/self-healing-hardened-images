#!/usr/bin/env bash
# Phase 9: demo namespaces, registry and API credentials, ACS integration, tasks, pipelines and the Conforma policy
cd "$(dirname "$0")/.." && . lib/env.sh
require_cluster

say "demo namespaces and Quay robot secrets"
oc apply -f manifests/10-gitops/namespaces.yaml >/dev/null
copy() {  # copy <secret> <namespace>
  oc get secret "$1" -n "$QUAY_NS" -o json | python3 -c '
import sys,json
s=json.load(sys.stdin); m=s["metadata"]
s["metadata"]={"name":m["name"],"namespace":sys.argv[1],"labels":{"app.kubernetes.io/part-of":"cve-demo"}}
print(json.dumps(s))' "$2" | oc apply -f - >/dev/null
}
copy quay-robot-pipeline cve-demo-ci
oc secrets link pipeline quay-robot-pipeline -n cve-demo-ci --for=pull,mount
for ns in cve-demo-stage cve-demo-prod; do
  copy quay-robot-puller "$ns"
  oc secrets link default quay-robot-puller -n "$ns" --for=pull
done
ok "Quay robots: push for cve-demo-ci/pipeline, pull for stage and prod"

if oc get secret tpa-cli-client -n "$TPA_NS" >/dev/null 2>&1; then
  oc get secret tpa-cli-client -n "$TPA_NS" -o json | python3 -c '
import sys,json
s=json.load(sys.stdin); s["metadata"]={"name":"tpa-cli-client","namespace":"cve-demo-ci"}; print(json.dumps(s))' | oc apply -f - >/dev/null
  ok "Trusted Profile Analyzer client secret in cve-demo-ci"
fi

say "ACS: CI token, delegated scanning, registry integration"
CLUSTER_ID=$(acs "$ACS_URL/v1/clusters" | python3 -c "
import sys,json
c=json.load(sys.stdin)['clusters']; print(next((x['id'] for x in c if x['name']=='$ACS_CLUSTER'), ''))")
[ -n "$CLUSTER_ID" ] || die "ACS has no secured cluster named '$ACS_CLUSTER': set ACS_CLUSTER in .env (oc get securedcluster -A)"

acs -X PUT "$ACS_URL/v1/delegatedregistryconfig" -d "{\"enabledFor\":\"SPECIFIC\",\"defaultClusterId\":\"$CLUSTER_ID\",
  \"registries\":[{\"path\":\"$QUAY_HOST\",\"clusterId\":\"$CLUSTER_ID\"}]}" -o /dev/null

PU=$(oc get secret quay-robot-puller -n "$QUAY_NS" -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d \
  | python3 -c 'import sys,json; a=list(json.load(sys.stdin)["auths"].values())[0]; print(a["username"]+"\n"+a["password"])')
body=$(python3 -c '
import json,sys; u,p=sys.argv[3].split("\n")
print(json.dumps({"name":"cve-demo-quay","type":"docker","categories":["REGISTRY"],
  "docker":{"endpoint":sys.argv[1],"username":u,"password":p,"insecure":False},"clusterIds":[sys.argv[2]]}))' "$QUAY_HOST" "$CLUSTER_ID" "$PU")
iid=$(acs "$ACS_URL/v1/imageintegrations" | python3 -c '
import sys,json; print(next((i["id"] for i in json.load(sys.stdin)["integrations"] if i["name"]=="cve-demo-quay"),""))')
if [ -z "$iid" ]; then code=$(acs -X POST "$ACS_URL/v1/imageintegrations" -d "$body" -o /tmp/cve-demo-acs.json -w '%{http_code}')
else code=$(acs -X PUT "$ACS_URL/v1/imageintegrations/$iid" -o /tmp/cve-demo-acs.json -w '%{http_code}' \
  -d "$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); d['id']='$iid'; print(json.dumps(d))")"); fi
[ "$code" = 200 ] || die "ACS registry integration for $QUAY_HOST failed (HTTP $code): $(head -c 300 /tmp/cve-demo-acs.json)"
rm -f /tmp/cve-demo-acs.json

if ! oc get secret acs-ci-token -n cve-demo-ci >/dev/null 2>&1; then
  TOKEN=$(acs -X POST "$ACS_URL/v1/apitokens/generate" \
      -d '{"name":"cve-demo-pipeline","roles":["Continuous Integration"]}' \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')
  # internal service endpoint, verified against Central's own CA
  oc create secret generic acs-ci-token -n cve-demo-ci --from-literal=token="$TOKEN" \
     --from-literal=endpoint="central.$ACS_NS.svc:443" --from-literal=cluster="$ACS_CLUSTER" \
     --from-literal=ca.pem="$(oc get secret central-tls -n "$ACS_NS" -o jsonpath='{.data.ca\.pem}' | base64 -d)"
fi
oc patch secret acs-ci-token -n cve-demo-ci --type merge -p "{\"stringData\":{\"endpoint\":\"central.$ACS_NS.svc:443\",\"cluster\":\"$ACS_CLUSTER\"}}" >/dev/null
ok "ACS: CI token in cve-demo-ci/acs-ci-token, delegated scanning and registry integration for $QUAY_HOST"

say "tasks, pipelines, triggers and the Conforma policy"
KC_ISSUER="https://keycloak-$KC_NS.$DOMAIN/realms/tas-chains"
render manifests/09-pipeline/tasks.yaml GITEA_INTERNAL_URL APP_IMAGE BASE_REPO BASE_STREAM KC_ISSUER TAS_NS TPA_NS KC_NS DOMAIN | oc apply -f - >/dev/null
oc create cm conforma-policy -n cve-demo-ci --from-file=manifests/09-pipeline/conforma/policy.yaml \
   --from-file=manifests/09-pipeline/conforma/cve_demo.rego \
   --dry-run=client -o yaml | oc apply -f - >/dev/null
render manifests/09-pipeline/pipelines.yaml GITEA_INTERNAL_URL APP_IMAGE BASE_REPO BASE_STREAM | oc apply -f - >/dev/null
ok "pipelines installed (EventListener: http://el-app-push.cve-demo-ci.svc:8080, in-cluster only)"
