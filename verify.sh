#!/usr/bin/env bash
# Read-only status, one line per check; exit 1 if anything is not ready
cd "$(dirname "$0")" && . lib/env.sh
fail=0
row() { if [ "$2" = ok ]; then ok "$1"; else warn "$1: $2"; fail=1; fi; }


for p in openshift-pipelines-operator-rh openshift-gitops-operator rhacs-operator gitea-operator \
         odf-operator quay-operator rhbk-operator rhtas-operator rhtpa-operator; do
  ph=$(csv_phase "$p"); row "operator $p" "$([ "$ph" = Succeeded ] && echo ok || echo "${ph:-not installed}")"
done
row "operator pin guard" "$(oc get validatingadmissionpolicybinding cve-demo-operator-pins -o name >/dev/null 2>&1 && echo ok || echo 'missing: ./setup.sh --only 1')"
row "ACS Central ($ACS_NS)" "$([ "$(oc get deploy central -n "$ACS_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 1 ] && echo ok || echo 'not ready')"
mlog=$(oc logs -n "$ACS_NS" -l app=scanner-v4-matcher --tail=-1 2>/dev/null || true)
row "ACS Scanner V4 matcher initialized" "$([[ $mlog == *"setting to initialized"* ]] && echo ok || echo 'still loading or restarted')"
row "ACS admission controller" "$(oc get validatingwebhookconfiguration stackrox -o name >/dev/null 2>&1 && echo ok || echo missing)"
row "NooBaa object storage" "$([ "$(oc get noobaa noobaa -n openshift-storage -o jsonpath='{.status.phase}' 2>/dev/null)" = Ready ] && echo ok || echo 'not ready')"
row "Quay ${QUAY_HOST:-(not installed)}" "$([ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://${QUAY_HOST:-none}/health/instance")" = 200 ] && echo ok || echo unhealthy)"
row "Quay robots in demo namespaces" "$(oc get secret quay-robot-pipeline -n cve-demo-ci >/dev/null 2>&1 && oc get secret quay-robot-puller -n cve-demo-prod >/dev/null 2>&1 && echo ok || echo 'missing: ./setup.sh --only 9')"
row "Gitea $GITEA_URL" "$([ "$(curl -sk -o /dev/null -w '%{http_code}' -m 10 "$GITEA_URL/api/v1/version")" = 200 ] && echo ok || echo unreachable)"
bp=$(curl -s -u "$GITEA_USER:$GITEA_PASS" "$GITEA_URL/api/v1/repos/$GITEA_ORG/gitops/branch_protections" || true)
row "Gitea prod branch protected" "$([[ $bp == *'"rule_name":"prod"'* ]] && echo ok || echo 'no rule')"
for a in app-stage app-prod; do
  s=$(oc get applications.argoproj.io "$a" -n cve-demo-gitops -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
  row "Argo CD $a" "$([ "$s" = Synced/Healthy ] && echo ok || echo "${s:-missing}")"
done
# the list endpoint omits enforcementActions: read each demo policy by id
ids=$(curl -sSk -m 30 -u "admin:$ACS_PASS" "$ACS_URL/v1/policies" 2>/dev/null | python3 -c '
import sys,json
try: print(" ".join(x["id"] for x in json.load(sys.stdin)["policies"] if x["name"].startswith("Self-healing demo")))
except Exception: pass' 2>/dev/null || true)
found=0; enf=0
for id in $ids; do
  found=$((found+1))
  grep -q '"enforcementActions":\["[A-Z_]' <<<"$(curl -sSk -m 30 -u "admin:$ACS_PASS" "$ACS_URL/v1/policies/$id" 2>/dev/null)" && enf=$((enf+1))
done
pol="$found $enf"
row "ACS demo policies enforcing" "$([ "$pol" = '2 2' ] && echo ok || echo "found/enforcing: $pol")"
row "Keycloak realm tas-chains" "$([ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://keycloak-$KC_NS.$DOMAIN/realms/tas-chains/.well-known/openid-configuration")" = 200 ] && echo ok || echo unreachable)"
row "Trusted Artifact Signer ready" "$([ "$(oc get securesign securesign -n "$TAS_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && echo ok || echo 'not ready')"
row "Chains keyless (Fulcio + Rekor)" "$([ "$(oc get tektonconfig config -o jsonpath='{.spec.chain.signers\.x509\.fulcio\.enabled}/{.spec.chain.transparency\.enabled}' 2>/dev/null)" = true/true ] && echo ok || echo 'not configured: ./setup.sh --only 6')"
age=$(oc logs deploy/cve-demo-oidc-refresher -n openshift-pipelines --tail=1 2>/dev/null || true)
row "Chains token refresher" "$([[ $age == *"token refreshed"* ]] && echo ok || echo "${age:-not running}")"
b=$(oc get cm demo-baseline -n cve-demo-ci -o jsonpath='{.data.digest}' 2>/dev/null || true)
row "Trusted Profile Analyzer" "$([ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://server-$TPA_NS.$DOMAIN/")" = 200 ] && echo ok || echo unreachable)"
row "TPA API for the pipeline (client cli)" "$([ "$(tpa_api GET '/api/v3/sbom?limit=1' -o /dev/null -w '%{http_code}' 2>/dev/null)" = 200 ] && echo ok || echo 'token rejected: tools/keycloak-reimport.sh tpa?')"
imp=$(tpa_api GET /api/v3/importer 2>/dev/null | python3 -c 'import sys,json; print(sum(1 for i in json.load(sys.stdin) if i["name"].startswith("redhat-vex-demo-") and not i.get("configuration",{}).get("csaf",{}).get("disabled")))' 2>/dev/null || echo 0)
row "TPA importer (Red Hat VEX for the demo CVEs)" "$([ "${imp:-0}" -ge 1 ] && echo ok || echo 'missing: ./setup.sh --only 10')"
row "baseline recorded" "$([ -n "$b" ] && echo ok || echo missing)"
p=$(oc get deploy app -n cve-demo-prod -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*@//' || true)
if [ -n "$b" ]; then
  [ "$p" = "$b" ] && ok "prod on the baseline image: ready to run the demo" || ok "prod on ${p:0:19}… (not the baseline: run demo/cve-fire-drill/reset.sh before the demo)"
fi
[ "$fail" = 0 ] && ok "all checks passed" || { warn "some checks failed"; exit 1; }
