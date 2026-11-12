#!/usr/bin/env bash
# cleanup.sh [--platform]: the demo layer; --platform also every product setup.sh installed
cd "$(dirname "$0")" && . lib/env.sh
require_cluster
level=demo
for a in "$@"; do
  case $a in --platform) level=platform ;; *) die "unknown option $a" ;; esac
done
say "cleanup ($level) on $(oc whoami --show-server)"

if [ "$ACS_URL" != https:// ]; then
say "ACS: demo policies, signature and registry integrations, pipeline API token"
acs "$ACS_URL/v1/policies" | python3 -c '
import sys,json; [print(p["id"]) for p in json.load(sys.stdin)["policies"] if p["name"].startswith("Self-healing demo")]' \
  | while read -r id; do acs -X DELETE "$ACS_URL/v1/policies/$id" -o /dev/null && ok "deleted policy $id"; done
acs "$ACS_URL/v1/signatureintegrations" | python3 -c '
import sys,json; [print(i["id"]) for i in json.load(sys.stdin).get("integrations",[]) if i["name"]=="cve-demo-chains"]' \
  | while read -r id; do acs -X DELETE "$ACS_URL/v1/signatureintegrations/$id" -o /dev/null && ok "deleted signature integration"; done
acs "$ACS_URL/v1/imageintegrations" | python3 -c '
import sys,json; [print(i["id"]) for i in json.load(sys.stdin)["integrations"] if i["name"]=="cve-demo-quay"]' \
  | while read -r id; do acs -X DELETE "$ACS_URL/v1/imageintegrations/$id" -o /dev/null && ok "deleted registry integration cve-demo-quay"; done
acs "$ACS_URL/v1/apitokens?revoked=false" | python3 -c '
import sys,json; [print(t["id"]) for t in json.load(sys.stdin).get("tokens",[]) if t["name"]=="cve-demo-pipeline"]' \
  | while read -r id; do acs -X PATCH "$ACS_URL/v1/apitokens/revoke/$id" -o /dev/null && ok "revoked API token cve-demo-pipeline"; done
fi

if [ "$GITEA_URL" != https:// ]; then
say "Gitea: organisation $GITEA_ORG, users pipeline-bot and approver"
for r in app gitops; do
  [ "$(gitea -o /dev/null -w '%{http_code}' -X DELETE "$GITEA_URL/api/v1/repos/$GITEA_ORG/$r")" = 204 ] && ok "deleted repository $GITEA_ORG/$r"
done
[ "$(gitea -o /dev/null -w '%{http_code}' -X DELETE "$GITEA_URL/api/v1/orgs/$GITEA_ORG")" = 204 ] && ok "deleted organisation $GITEA_ORG"
for u in pipeline-bot approver; do
  [ "$(gitea -o /dev/null -w '%{http_code}' -X DELETE "$GITEA_URL/api/v1/admin/users/$u?purge=true")" = 204 ] && ok "deleted user $u"
done
fi

gone() {  # gone <namespace>...: delete and wait up to 10 minutes
  oc delete ns "$@" --ignore-not-found --wait=false >/dev/null
  for _ in $(seq 1 120); do [ -z "$(oc get ns "$@" -o name 2>/dev/null)" ] && return 0; sleep 5; done
  warn "still terminating: $*"
}
say "demo namespaces with the demo's Argo CD instance, pipelines, secrets and apps"
gone cve-demo-ci cve-demo-gitops cve-demo-stage cve-demo-prod && ok "demo namespaces deleted"
oc delete clusterrolebinding cve-demo-triggers --ignore-not-found >/dev/null
if [ "$level" = demo ]; then ok "cleanup done: ./setup.sh --from 9 rebuilds the demo layer"; exit 0; fi

unsub() {  # unsub <namespace> <package>: subscription and CSV, only if setup created the subscription
  local name csv
  name=$(oc get subscriptions.operators.coreos.com -n "$1" -o jsonpath="{range .items[?(@.spec.name=='$2')]}{.metadata.name}{end}" 2>/dev/null)
  [ -n "$name" ] || return 0
  if ! ours subscriptions.operators.coreos.com "$name" -n "$1"; then ok "operator $2 was already there: kept"; return 0; fi
  csv=$(oc get subscriptions.operators.coreos.com "$name" -n "$1" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  oc delete subscriptions.operators.coreos.com "$name" -n "$1" --ignore-not-found >/dev/null
  [ -n "$csv" ] && oc delete csv "$csv" -n "$1" --ignore-not-found >/dev/null
  ok "operator $2 removed"
}
product() {  # product <namespace> <kinds>: delete the instances and the namespace, only if setup created the namespace
  if ! ours ns "$1"; then oc get ns "$1" >/dev/null 2>&1 && ok "namespace $1 was already there: kept"; return 0; fi
  oc delete "$2" --all -n "$1" --ignore-not-found --wait=true --timeout=600s >/dev/null 2>&1 || true
  gone "$1"
}

say "Tekton Chains back to signing without Trusted Artifact Signer"
for k in signers.x509.fulcio.enabled signers.x509.fulcio.address signers.x509.fulcio.issuer signers.x509.fulcio.provider \
         signers.x509.identity.token.file signers.x509.tuf.mirror.url transparency.url options/deployments/tekton-chains-controller; do
  oc patch tektonconfig config --type json -p "[{\"op\":\"remove\",\"path\":\"/spec/chain/$k\"}]" >/dev/null 2>&1 || true
done
oc patch tektonconfig config --type merge -p '{"spec":{"chain":{"transparency.enabled":"false"}}}' >/dev/null 2>&1 || true
oc delete deploy,sa,role,rolebinding cve-demo-oidc-refresher -n openshift-pipelines --ignore-not-found >/dev/null 2>&1 || true
oc delete secret chains-oidc-token tas-chains-client tpa-cli-client -n openshift-pipelines --ignore-not-found >/dev/null 2>&1 || true

say "Trusted Profile Analyzer, Trusted Artifact Signer, Keycloak"
ours ns "$TPA_NS" && oc delete obc --all -n "$TPA_NS" --ignore-not-found >/dev/null 2>&1
product "$TPA_NS" trustedprofileanalyzer; unsub "$TPA_NS" rhtpa-operator
product "$TAS_NS" securesign; unsub openshift-operators rhtas-operator
product "$KC_NS" keycloakrealmimport,keycloak; unsub "$KC_NS" rhbk-operator

say "Quay, Gitea, ACS"
product "$QUAY_NS" quayregistry; unsub openshift-operators quay-operator
product "$GITEA_NS" gitea; unsub gitea-operator gitea-operator
ours ns gitea-operator && gone gitea-operator
ours catalogsource redhat-rhpds-gitea -n openshift-marketplace && oc delete catalogsource redhat-rhpds-gitea -n openshift-marketplace >/dev/null
if ours ns "$ACS_NS"; then
  oc delete securedcluster,central --all -n "$ACS_NS" --ignore-not-found --wait=true --timeout=600s >/dev/null 2>&1 || true
  oc delete validatingwebhookconfiguration stackrox --ignore-not-found >/dev/null
  gone "$ACS_NS"
fi
unsub rhacs-operator rhacs-operator; ours ns rhacs-operator && gone rhacs-operator
installed rhacs-operator || console_plugin disable advanced-cluster-security

say "OpenShift Data Foundation and NooBaa"
if ours storagecluster ocs-storagecluster -n openshift-storage; then
  oc delete storagecluster ocs-storagecluster -n openshift-storage --wait=true --timeout=600s >/dev/null 2>&1 || true
else
  ok "StorageCluster was already there or is absent: kept"
fi
unsub openshift-storage odf-operator
ours ns openshift-storage && gone openshift-storage

say "OpenShift Pipelines and OpenShift GitOps"
if ours subscriptions.operators.coreos.com openshift-pipelines-operator-rh -n openshift-operators; then
  oc delete tektonconfig config --ignore-not-found --wait=true --timeout=600s >/dev/null 2>&1 || true
fi
unsub openshift-operators openshift-pipelines-operator-rh
installed openshift-pipelines-operator-rh || console_plugin disable pipelines-console-plugin
unsub openshift-gitops-operator openshift-gitops-operator
ours ns openshift-gitops-operator && gone openshift-gitops-operator
oc delete validatingadmissionpolicybinding,validatingadmissionpolicy cve-demo-operator-pins --ignore-not-found >/dev/null
ok "cleanup done ($level): ./setup.sh"
