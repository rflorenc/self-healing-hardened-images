#!/usr/bin/env bash
# Phase 6: Trusted Artifact Signer, the Chains token refresher, Chains switched to keyless
cd "$(dirname "$0")/.." && . lib/env.sh
require_cluster

say "Trusted Artifact Signer in namespace $TAS_NS"
mkns "$TAS_NS"
for _ in $(seq 1 30); do oc get cm kube-root-ca.crt -n "$TAS_NS" >/dev/null 2>&1 && break; sleep 2; done
oc create cm cluster-ca -n "$TAS_NS" \
   --from-literal=ca-bundle.crt="$(oc get cm kube-root-ca.crt -n "$TAS_NS" -o jsonpath='{.data.ca\.crt}')" \
   --dry-run=client -o yaml | oc apply -f - >/dev/null
KC_HOST="keycloak-$KC_NS.$DOMAIN"
render manifests/06-tas/securesign.yaml TAS_NS KC_HOST | oc apply -f - >/dev/null
for _ in $(seq 1 90); do
  [ "$(oc get securesign securesign -n "$TAS_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && break
  sleep 10
done
[ "$(oc get securesign securesign -n "$TAS_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] \
  || die "Securesign not ready after 15 minutes: oc get securesign securesign -n $TAS_NS -o yaml; oc get pods -n $TAS_NS"
ok "Securesign ready"

say "Keycloak token for Tekton Chains (refreshed every 2 minutes)"
oc get secret tas-chains-client -n "$KC_NS" -o json | python3 -c '
import sys,json
s=json.load(sys.stdin); s["metadata"]={"name":"tas-chains-client","namespace":"openshift-pipelines"}; print(json.dumps(s))' \
  | oc apply -f - >/dev/null
oc get secret chains-oidc-token -n openshift-pipelines >/dev/null 2>&1 \
  || oc create secret generic chains-oidc-token -n openshift-pipelines --from-literal=oidc-token= >/dev/null
render manifests/06-tas/chains-oidc-refresher.yaml KC_NS | oc apply -f - >/dev/null
for _ in $(seq 1 30); do
  [ -n "$(oc get secret chains-oidc-token -n openshift-pipelines -o jsonpath='{.data.oidc-token}' 2>/dev/null)" ] && break; sleep 5
done
[ -n "$(oc get secret chains-oidc-token -n openshift-pipelines -o jsonpath='{.data.oidc-token}' 2>/dev/null)" ] \
  || die "no token yet: oc logs deploy/cve-demo-oidc-refresher -n openshift-pipelines"
ok "token refresher running"

say "Tekton Chains: in-toto attestations, keyless signing through Fulcio, transparency log in Rekor"
oc patch tektonconfig config --type merge --patch-file manifests/06-tas/tektonconfig-chains.yaml >/dev/null
oc patch tektonconfig config --type merge --patch-file /dev/stdin >/dev/null \
  < <(render manifests/06-tas/tektonconfig-chains-keyless.yaml TAS_NS KC_HOST)
for _ in $(seq 1 30); do
  grep -qw keycloak-token <<<"$(oc get deploy tekton-chains-controller -n openshift-pipelines -o jsonpath='{.spec.template.spec.volumes[*].name}')" && break
  sleep 5
done
oc rollout status deploy/tekton-chains-controller -n openshift-pipelines --timeout=180s >/dev/null \
  || die "Chains controller did not roll out: oc get pods -n openshift-pipelines -l app=tekton-chains-controller"
ok "Chains signs keyless as chains@cve-demo.local (Fulcio $TAS_NS), entries in Rekor"
