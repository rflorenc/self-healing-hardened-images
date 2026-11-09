#!/usr/bin/env bash
# Phase 0: read-only checks of the laptop and the cluster
cd "$(dirname "$0")/.." && . lib/env.sh
fail=0
bad() { warn "$1"; printf '    fix: %s\n' "$2" >&2; fail=1; }

say "Local tools"
for t in oc git curl python3 openssl; do
  command -v "$t" >/dev/null 2>&1 || bad "missing local tool: $t" "install $t"
done

say "Cluster login and version"
oc whoami >/dev/null 2>&1 || die "not logged in: run 'oc login' as a cluster-admin first"
[ "$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null)" = yes ] \
  || bad "$(oc whoami) is not cluster-admin" "log in as a cluster-admin user"
ver=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
case "$ver" in 4.20.*|4.21.*|4.22.*) ok "OpenShift $ver" ;; *) warn "OpenShift $ver: the demo targets 4.20 to 4.22" ;; esac

say "Route certificates (nodes pull the demo images from Quay's route)"
host="console-openshift-console.$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')"
if curl -s -o /dev/null -m 15 "https://$host/"; then
  ok "the cluster's route certificate is publicly trusted"
else
  warn "the route certificate ($host) is not publicly trusted: nodes will not pull images from Quay's route"
  printf '    fix: add the ingress CA to the image trust, for example:\n' >&2
  printf '      oc create configmap quay-ca -n openshift-config --from-file=<quay route host>=<ingress CA file>\n' >&2
  printf '      oc patch image.config.openshift.io/cluster --type merge -p %s\n' \
    "'{\"spec\":{\"additionalTrustedCA\":{\"name\":\"quay-ca\"}}}'" >&2
fi

say "Storage"
sc=$(oc get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}')
[ -n "$sc" ] && ok "default StorageClass: $sc" \
  || bad "no default StorageClass" "mark one StorageClass as default (the demo claims about 300 GiB of volumes)"

say "Worker capacity"
read -r cpu mem < <(oc get nodes -l node-role.kubernetes.io/worker -o json | python3 -c '
import sys,json
def q(v):
    u={"Ki":2**10,"Mi":2**20,"Gi":2**30,"m":1e-3}
    for k,f in u.items():
        if v.endswith(k): return float(v[:-len(k)])*f
    return float(v)
n=json.load(sys.stdin)["items"]
print(int(sum(q(i["status"]["allocatable"]["cpu"]) for i in n)), int(sum(q(i["status"]["allocatable"]["memory"]) for i in n)/2**30))')
if [ "$cpu" -lt 16 ] || [ "$mem" -lt 48 ]; then
  bad "workers have ${cpu} cores / ${mem} GiB allocatable" "the demo needs at least 16 cores and 48 GiB on workers (it requests about 13 cores / 36 GiB)"
else ok "workers: ${cpu} cores, ${mem} GiB allocatable"; fi

say "Outbound access from the cluster"
# read the logs after the pod ends: oc run -i attaches late and drops early lines
oc delete pod cve-demo-egress-test -n default --ignore-not-found >/dev/null
oc run cve-demo-egress-test -n default --restart=Never --quiet \
  --image=registry.access.redhat.com/ubi9/ubi-minimal:latest -- sh -c '
  for u in https://quay.io/v2/ https://registry.access.redhat.com/v2/ https://registry.redhat.io/v2/ \
           https://security.access.redhat.com/data/csaf/v2/provider-metadata.json; do
    printf "%s %s\n" "$u" "$(curl -s -o /dev/null -m 15 -w %{http_code} "$u")"; done' >/dev/null
oc wait pod/cve-demo-egress-test -n default --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s >/dev/null 2>&1 || true
out=$(oc logs cve-demo-egress-test -n default 2>&1 || true)
oc delete pod cve-demo-egress-test -n default --ignore-not-found --wait=false >/dev/null
echo "$out" | grep '^https://' | while read -r u code; do
  case "$code" in 200|401) ok "reachable: $u" ;; *) warn "not reachable: $u ($code)" ;; esac
done
grep -qE 'quay.io/v2/ (200|401)' <<<"$out" \
  || bad "quay.io not reachable from the cluster" "allow egress to quay.io: the Gitea operator catalog and the Gitea images come from there"
grep -qE 'registry.access.redhat.com/v2/ (200|401)' <<<"$out" \
  || bad "registry.access.redhat.com not reachable" "allow egress: Red Hat Hardened Images (and their SBOMs) come from there"
grep -qE 'security.access.redhat.com/\S+ 200' <<<"$out" \
  || bad "security.access.redhat.com not reachable" "allow egress: Trusted Profile Analyzer imports Red Hat's VEX from there"

say "Operators: present ones are reused as they are, missing ones are installed at the validated version"
plan() { printf '\033[1;34m→ %s\033[0m\n' "$*"; }
ODF_CHANNEL=$(odf_channel)
for op in $DEMO_OPERATORS; do
  file=${op%%:*}; pkg=${op#*:}; want=$(pinned_csv "$file"); channel=$(pinned_channel "$file")
  if installed "$pkg"; then
    ns=$(subns "$pkg"); name=$(subname "$pkg")
    csv=$(oc get subscriptions.operators.coreos.com "$name" -n "$ns" -o jsonpath='{.status.installedCSV}' 2>/dev/null)
    phase=$(oc get csv "$csv" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if ours subscriptions.operators.coreos.com "$name" -n "$ns"; then who="installed by this setup"; else who="already on the cluster, reused as it is"; fi
    if [ -z "$csv" ]; then warn "$pkg is subscribed in $ns but not installed yet: phase 01 approves its first install"
    elif [ "$phase" != Succeeded ]; then bad "$pkg $csv in $ns is $phase" "repair it first: oc get csv $csv -n $ns -o yaml"
    else
      ok "$pkg $csv: $who"
      [ -z "$want" ] || [ "$csv" = "$want" ] || warn "$pkg: the demo is validated on $want; $csv may behave differently"
    fi
    continue
  fi
  if [ "$pkg" = rhbk-operator ]; then
    for o in $(other_rhbk); do
      if [ "${o#*=}" = "$RHBK_CHANNEL" ]; then ok "rhbk-operator: another copy in ${o%%=*} on $RHBK_CHANNEL, ours goes to $KC_NS"
      else bad "another rhbk-operator in ${o%%=*} uses channel ${o#*=}" "both copies share the Keycloak CRDs: ours needs $RHBK_CHANNEL; move the other one to it or remove it"; fi
    done
  fi
  c=$(og_conflict "$file")
  [ -z "$c" ] || bad "OperatorGroup $c is in the way of $pkg" "a second OperatorGroup would fail every operator in that namespace: install $pkg there yourself or remove $c"
  if [ "$pkg" != gitea-operator ]; then   # the Gitea catalog is added by phase 01
    if ! oc get packagemanifest "$pkg" -n openshift-marketplace >/dev/null 2>&1; then
      bad "$pkg is not in the cluster's operator catalogs" "check the redhat-operators CatalogSource in openshift-marketplace"; continue
    fi
    entries=$(oc get packagemanifest "$pkg" -n openshift-marketplace -o jsonpath="{range .status.channels[?(@.name=='$channel')]}{range .entries[*]}{.name}{\"\\n\"}{end}{end}")
    if [ -z "$entries" ]; then bad "$pkg has no channel $channel in the catalog" "pick a channel the catalog offers and re-validate"; continue; fi
    if [ -n "$want" ] && ! grep -qx "$want" <<<"$entries"; then
      bad "$pkg: the catalog no longer offers $want in $channel" "raise the pin in manifests/01-operators/$file.yaml after validating the newer version"; continue
    fi
  fi
  plan "$pkg: will install ${want:-the newest in $channel}"
done

say "Products already on the cluster"
central=$(oc get central -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | head -1)
if [ -n "$central" ] && [ "$central" != "$ACS_NS" ]; then bad "ACS Central already runs in namespace $central" "set ACS_NS=$central in .env"
elif [ -n "$central" ]; then ok "ACS Central in $central: reused; phase 03 sets demo resource sizes"
else plan "ACS Central: will be created in $ACS_NS"; fi
stc=$(oc get storagecluster -n openshift-storage -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$stc" ]; then plan "NooBaa: a standalone Multicloud Object Gateway will be created"
elif [ "$(oc get noobaa noobaa -n openshift-storage -o jsonpath='{.status.phase}' 2>/dev/null)" = Ready ]; then ok "NooBaa ready in StorageCluster $stc: reused"
elif ours storagecluster "$stc" -n openshift-storage; then ok "StorageCluster $stc from an earlier run: NooBaa still starting"
else bad "StorageCluster $stc exists but NooBaa is not ready" "enable the Multicloud Object Gateway in $stc, or remove it so setup can create a standalone one"; fi
gns=$(subns openshift-gitops-operator)
if [ -n "$gns" ]; then
  targets=$(oc get operatorgroups -n "$gns" -o jsonpath='{.items[0].spec.targetNamespaces}' 2>/dev/null)
  [ -z "$targets" ] && ok "OpenShift GitOps watches all namespaces: the demo's own Argo CD instance can run in cve-demo-gitops" \
    || bad "OpenShift GitOps only watches $targets" "the demo creates its own Argo CD instance in cve-demo-gitops: the GitOps operator must watch all namespaces"
fi
if installed openshift-cert-manager-operator; then ok "cert-manager present: not used by the demo"; fi
kc=$(oc get keycloak -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}' 2>/dev/null)
for k in $kc; do [ "${k%%/*}" = "$KC_NS" ] || ok "Keycloak $k present: not used, the demo runs its own in $KC_NS"; done

[ "$fail" = 0 ] && ok "preflight passed" || die "preflight failed: fix the items above and re-run"
