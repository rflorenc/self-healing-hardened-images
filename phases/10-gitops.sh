#!/usr/bin/env bash
# Phase 10: Argo CD, the Gitea repositories, the bootstrap build, the baseline in prod, policies enforced
cd "$(dirname "$0")/.." && . lib/env.sh
require_cluster

push_repo() {  # push_repo app|gitops [base-digest]: initial content of a Gitea repository from demo/repos
  local repo=$1 digest=${2:-} token tmp f
  token=$(oc get secret gitea-token -n cve-demo-ci -o jsonpath='{.data.token}' | base64 -d)
  tmp=$(mktemp -d)
  cp -R "demo/repos/$repo/." "$tmp/"
  if [ "$repo" = app ]; then
    [ -n "$digest" ] || die "push_repo app needs the base digest"
    sed -i.bak "s#sha256:PINNED_DIGEST#$digest#g" "$tmp/Containerfile" && rm -f "$tmp/Containerfile.bak"   # GNU and BSD sed
  fi
  if [ "$repo" = gitops ]; then
    for f in "$tmp"/overlays/*/kustomization.yaml; do
      sed -i.bak "s#\${APP_IMAGE}#$APP_IMAGE#g" "$f" && rm -f "$f.bak"
    done
  fi
  git -C "$tmp" init -q -b main && git -C "$tmp" add -A
  git -C "$tmp" -c user.name="cve-demo setup" -c user.email="setup@cve-demo.local" commit -qm "Initial $repo"
  git -C "$tmp" push -q -f "https://$GITEA_USER:$token@${GITEA_URL#https://}/$GITEA_ORG/$repo.git" main
  rm -rf "$tmp"
  ok "pushed $repo"
}

acs_policy() {  # acs_policy inform|enforce: the demo's fixable-CVE build policy
  local mode=$1 body name id
  acs -X POST "$ACS_URL/v1/policycategories" -d '{"name":"Self-Healing Demo"}' -o /dev/null || true
  body=$(python3 - "$mode" <<'PY'
import json,sys
p=json.load(open('manifests/03-acs/policy-fixable.json'))
p['enforcementActions']=['FAIL_BUILD_ENFORCEMENT'] if sys.argv[1]=='enforce' else []
print(json.dumps(p))
PY
  )
  name=$(python3 -c 'import json; print(json.load(open("manifests/03-acs/policy-fixable.json"))["name"])')
  id=$(acs "$ACS_URL/v1/policies?query=Policy:$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$name")" \
       | python3 -c 'import sys,json; p=json.load(sys.stdin).get("policies",[]); print(p[0]["id"] if p else "")')
  if [ -z "$id" ]; then
    acs -X POST "$ACS_URL/v1/policies" -d "$body" -o /dev/null
  else
    acs -X PUT "$ACS_URL/v1/policies/$id" -d "$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); d['id']='$id'; print(json.dumps(d))")" -o /dev/null
  fi
  ok "ACS fixable-CVE build policy: $mode"
}

acs_signature() {  # acs_signature inform|enforce: keyless signature integration and the prod admission policy
  local mode=$1 ca TUF trust body SIG_ID code policy name id
  ca=$(mktemp)
  oc get cm kube-root-ca.crt -n "$TAS_NS" -o jsonpath='{.data.ca\.crt}' > "$ca"
  TUF="https://$(oc get route -n "$TAS_NS" -l app.kubernetes.io/component=tuf -o jsonpath='{.items[0].spec.host}')"
  trust=$(python3 -I lib/tas-trust.py "$TUF" "$ca") || die "could not read the trust root from $TUF"
  body=$(python3 -c '
import json,sys
t=json.loads(sys.argv[1]); issuer, rekor = sys.argv[2], sys.argv[3]
print(json.dumps({"name":"cve-demo-chains",
  "cosignCertificates":[{"certificateChainPemEnc":t["fulcio_chain"],"certificateOidcIssuer":issuer,
    "certificateIdentity":"chains@cve-demo.local",
    "certificateTransparencyLog":{"enabled":True,"publicKeyPemEnc":t["ctlog_key"]}}],
  "transparencyLog":{"enabled":True,"url":rekor,"validateOffline":False,"publicKeyPemEnc":t["rekor_key"]}}))' \
    "$trust" "https://keycloak-$KC_NS.$DOMAIN/realms/tas-chains" "http://rekor-server.$TAS_NS.svc")
  SIG_ID=$(acs "$ACS_URL/v1/signatureintegrations" | python3 -c '
import sys,json
print(next((i["id"] for i in json.load(sys.stdin).get("integrations",[]) if i["name"]=="cve-demo-chains"),""))')
  if [ -z "$SIG_ID" ]; then
    SIG_ID=$(acs -X POST "$ACS_URL/v1/signatureintegrations" -d "$body" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
  else
    code=$(acs -X PUT "$ACS_URL/v1/signatureintegrations/$SIG_ID" -o /tmp/cve-demo-sig.json -w '%{http_code}' \
      -d "$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); d['id']='$SIG_ID'; print(json.dumps(d))")")
    [ "$code" = 200 ] || die "updating the signature integration failed (HTTP $code): $(head -c 300 /tmp/cve-demo-sig.json)"
    rm -f /tmp/cve-demo-sig.json
  fi
  policy=$(python3 - "$SIG_ID" "$mode" <<'PY'
import json,sys
sig,mode=sys.argv[1:]
print(json.dumps({
 "name":"Self-healing demo: production runs signed images only",
 "description":"Images in cve-demo-prod must carry a keyless signature from the pipeline (Tekton Chains, Fulcio certificate for chains@cve-demo.local, logged in Rekor).",
 "rationale":"Only images built, scanned and signed by the trusted pipeline may run in production.",
 "remediation":"Build the image through the build-and-stage pipeline.",
 "categories":["Self-Healing Demo"],"lifecycleStages":["DEPLOY"],"severity":"CRITICAL_SEVERITY",
 "enforcementActions":["SCALE_TO_ZERO_ENFORCEMENT"] if mode=="enforce" else [],
 "scope":[{"namespace":"cve-demo-prod"}],
 "policySections":[{"sectionName":"not signed by the pipeline","policyGroups":[
   {"fieldName":"Image Signature Verified By","values":[{"value":sig}]}]}]}))
PY
  )
  name="Self-healing demo: production runs signed images only"
  id=$(acs "$ACS_URL/v1/policies" | python3 -c "import sys,json; print(next((p['id'] for p in json.load(sys.stdin)['policies'] if p['name']=='$name'),''))")
  if [ -z "$id" ]; then
    echo "$policy" | acs -X POST "$ACS_URL/v1/policies" -d @- -o /dev/null
  else
    echo "$policy" | python3 -c "import sys,json; d=json.load(sys.stdin); d['id']='$id'; print(json.dumps(d))" \
      | acs -X PUT "$ACS_URL/v1/policies/$id" -d @- -o /dev/null
  fi
  rm -f "$ca"
  ok "ACS keyless signature integration $SIG_ID, prod admission policy: $mode"
}

base_sbom() {  # base_sbom <digest> <label>: Red Hat's SBOM of the base image's linux/amd64 image into TPA
  local digest=$1 label=$2 repo R amd64 layer tmp
  repo=${BASE_REPO#registry.access.redhat.com/}; R="https://registry.access.redhat.com/v2/$repo"
  amd64=$(curl -s -m 30 -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' \
    "$R/manifests/$digest" | python3 -c '
import sys,json; d=json.load(sys.stdin)
ms=d.get("manifests")
print(next((m["digest"] for m in ms if m.get("platform",{}).get("architecture")=="amd64"), "") if ms else sys.argv[1])' "$digest")
  [ -n "$amd64" ] || die "no linux/amd64 image in $BASE_REPO@$digest"
  layer=$(curl -s -m 30 -H 'Accept: application/vnd.oci.image.manifest.v1+json' "$R/manifests/${amd64/:/-}.sbom" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["layers"][0]["digest"])') || die "no Red Hat SBOM for $amd64"
  tmp=$(mktemp)
  curl -sL -m 60 "$R/blobs/$layer" -o "$tmp"
  tpa_api POST "/api/v3/sbom?labels.source=redhat-hardened-images&labels.sbomBy=Red%20Hat&labels.demo=$label&labels.baseImage=$BASE_REPO&labels.baseDigest=$amd64" \
    -H 'Content-Type: application/octet-stream' --data-binary @"$tmp" -o /dev/null
  rm -f "$tmp"
}

say "namespaces and the demo's Argo CD instance"
oc apply -f manifests/10-gitops/namespaces.yaml -f manifests/10-gitops/argocd.yaml >/dev/null
for _ in $(seq 1 60); do
  [ "$(oc get deploy argocd-server -n cve-demo-gitops -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 1 ] && break; sleep 10
done
ok "Argo CD ready"

apps() { render manifests/10-gitops/applications.yaml GITEA_INTERNAL_URL APP_IMAGE | oc apply -f - >/dev/null; }
app_sum() { shasum -a 256 demo/repos/app/app.py | cut -c1-12; }
app_changed() {  # the baseline was built from another demo/repos/app/app.py
  [ "$(oc get cm demo-baseline -n cve-demo-ci -o jsonpath='{.data.app}' 2>/dev/null)" != "$(app_sum)" ]
}
update_app() {  # push demo/repos/app/app.py on the baseline base image; the push starts a build
  local token tmp current
  token=$(oc get secret gitea-token -n cve-demo-ci -o jsonpath='{.data.token}' | base64 -d)
  tmp=$(mktemp -d)
  git clone -q "https://pipeline-bot:$token@${GITEA_URL#https://}/$GITEA_ORG/app.git" "$tmp/app"
  cp demo/repos/app/app.py "$tmp/app/app.py"
  current=$(grep -oE 'sha256:[a-f0-9]{64}' "$tmp/app/Containerfile" | head -1)
  sed -i.bak "s#$current#$BASELINE_DIGEST#g" "$tmp/app/Containerfile" && rm -f "$tmp/app/Containerfile.bak"
  if git -C "$tmp/app" diff --quiet; then   # already pushed by an interrupted run: build it again
    rm -rf "$tmp"; run_build main >/dev/null; ok "app already up to date in Gitea: rebuilding it"; return 0
  fi
  git -C "$tmp/app" -c user.name="cve-demo setup" -c user.email="setup@cve-demo.local" commit -qam "Update the app" \
    -m "Rebuilt on the baseline base image ${BASE_REPO}:${BASE_STREAM}@${BASELINE_DIGEST}."
  git -C "$tmp/app" push -q origin HEAD:main
  rm -rf "$tmp"
  ok "pushed the updated app on the baseline base image"
}
baseline=$(oc get cm demo-baseline -n cve-demo-ci -o jsonpath='{.data.digest}' 2>/dev/null || true)
rebuild=0
if [ -n "$baseline" ] && app_changed; then rebuild=1; fi
if [ -z "$baseline" ] || [ "$rebuild" = 1 ]; then acs_policy inform; acs_signature inform; fi

say "Gitea: gitops content, protected prod branch, webhooks"
# the repository's own empty flag: newer Gitea lists the branches of an empty repository as null
empty() { [ "$(curl -s -u "$GITEA_USER:$GITEA_PASS" "$GITEA_URL/api/v1/repos/$GITEA_ORG/$1" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("empty"))')" = True ]; }
if empty gitops; then push_repo gitops; fi
R="$GITEA_URL/api/v1/repos/$GITEA_ORG/gitops"
if [ "$(curl -s -o /dev/null -w '%{http_code}' -u "$GITEA_USER:$GITEA_PASS" "$R/branches/prod")" != 200 ]; then
  # a rule left from an earlier run blocks creating the branch: drop it, it is re-applied below
  gitea -X DELETE "$R/branch_protections/prod" -o /dev/null || true
  code=$(gitea -X POST "$R/branches" -d '{"new_branch_name":"prod","old_branch_name":"main"}' -o /dev/null -w '%{http_code}')
  [ "$code" = 201 ] || die "could not create branch prod in $GITEA_ORG/gitops (HTTP $code): is main pushed?"
  ok "branch prod created from main"
fi
rule='{"rule_name":"prod","enable_push":false,"enable_merge_whitelist":true,"merge_whitelist_usernames":["approver"],
  "required_approvals":1,"enable_approvals_whitelist":true,"approvals_whitelist_username":["approver"],
  "block_on_rejected_reviews":true,"dismiss_stale_approvals":true}'
if grep -q '"rule_name":"prod"' <<<"$(gitea "$R/branch_protections")"; then
  gitea -X PATCH "$R/branch_protections/prod" -d "$rule" -o /dev/null
else
  gitea -X POST "$R/branch_protections" -d "$rule" -o /dev/null
fi
ok "prod branch protected: no direct pushes; merge needs approval by approver"
EL="http://el-app-push.cve-demo-ci.svc:8080"
if grep -qiE '^SKIP_TLS_VERIFY *= *true' <<<"$(oc get cm gitea-config -n "$GITEA_NS" -o jsonpath='{.data.app\.ini}')"; then
  ARGO="https://argocd-server.cve-demo-gitops.svc/api/webhook"
else
  ARGO="https://$(oc get route argocd-server -n cve-demo-gitops -o jsonpath='{.spec.host}')/api/webhook"
fi
hook() {  # hook <repo> <url>: exactly one push hook, pointing at <url>
  gitea "$GITEA_URL/api/v1/repos/$GITEA_ORG/$1/hooks" | python3 -c "import sys,json; [print(h['id']) for h in json.load(sys.stdin) if h['config']['url']!='$2']" \
    | while read -r id; do gitea -X DELETE "$GITEA_URL/api/v1/repos/$GITEA_ORG/$1/hooks/$id" -o /dev/null; done
  if ! grep -q "\"$2\"" <<<"$(gitea "$GITEA_URL/api/v1/repos/$GITEA_ORG/$1/hooks")"; then
    gitea -X POST "$GITEA_URL/api/v1/repos/$GITEA_ORG/$1/hooks" -d "{\"type\":\"gitea\",\"active\":true,
      \"events\":[\"push\"],\"config\":{\"url\":\"$2\",\"content_type\":\"json\"}}" -o /dev/null
  fi
  ok "$1 webhook -> $2"
}
hook app "$EL"
hook gitops "$ARGO"

if [ -n "$baseline" ] && [ "$rebuild" = 0 ]; then
  apps
  ok "baseline already recorded (prod image $baseline): skipping the bootstrap build"
elif [ "$rebuild" = 1 ]; then
  apps
  say "the app changed: rebuilding the baseline with it"
  for n in $(gitea "$GITEA_URL/api/v1/repos/$GITEA_ORG/gitops/pulls?state=open" \
      | python3 -c 'import sys,json; print(" ".join(str(p["number"]) for p in json.load(sys.stdin) if p["base"]["ref"]=="prod"))'); do
    gitea -X PATCH "$GITEA_URL/api/v1/repos/$GITEA_ORG/gitops/pulls/$n" -d '{"state":"closed"}' -o /dev/null && ok "closed pull request #$n"
  done
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  update_app
  wait_build "$since"
else
  acs_scanner_ready
  apps   # only now: before the first build the overlays hold a placeholder digest
  say "bootstrap build on the baseline base image ${BASE_REPO}:${BASE_STREAM}@${BASELINE_DIGEST:0:19}…"
  open_prs=$(curl -s -u "$GITEA_USER:$GITEA_PASS" "$GITEA_URL/api/v1/repos/$GITEA_ORG/gitops/pulls?state=open" \
    | python3 -c 'import sys,json; print(sum(1 for p in json.load(sys.stdin) if p["base"]["ref"]=="prod"))')
  if [ "$open_prs" -gt 0 ]; then
    ok "a prod pull request is already open: approving it (resuming an earlier run)"
  else
    since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if empty app; then
      push_repo app "$BASELINE_DIGEST"   # the push starts the build
    else
      rc=0; pin_base "$BASELINE_DIGEST" "Bootstrap: start from the baseline base image" || rc=$?
      [ "$rc" = 3 ] && run_build main >/dev/null   # already pinned: build it anyway
      [ "$rc" = 0 ] || [ "$rc" = 3 ] || die "could not pin the baseline base image"
    fi
    wait_build "$since"
  fi
fi
if [ -z "$baseline" ] || [ "$rebuild" = 1 ]; then
  approve_pr
  # wait for exactly the digest the merged pull request put on the prod branch
  want=$(curl -s -u "$GITEA_USER:$GITEA_PASS" "$GITEA_URL/api/v1/repos/$GITEA_ORG/gitops/raw/overlays/prod/kustomization.yaml?ref=prod" \
    | grep -oE 'sha256:[a-f0-9]{64}' | head -1)
  [ -n "$want" ] || die "could not read the prod digest from $GITEA_ORG/gitops (branch prod)"
  say "waiting for Argo CD to roll out ${want:0:19}… to prod"
  img=""
  for _ in $(seq 1 30); do
    img=$(oc get deploy app -n cve-demo-prod -o jsonpath='{.spec.template.spec.containers[0].image}')
    [ "${img#*@}" = "$want" ] && [ "$(oc get deploy app -n cve-demo-prod -o jsonpath='{.status.updatedReplicas}/{.status.readyReplicas}')" = 1/1 ] && break
    sleep 10
  done
  [ "${img#*@}" = "$want" ] \
    || die "prod did not roll out ${want:0:19}… within 5 minutes: oc get applications.argoproj.io app-prod -n cve-demo-gitops -o yaml (look for an ACS admission denial)"
  cm=$(oc get deploy app -n cve-demo-prod -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].configMapRef.name}')
  summary=$(oc get cm "$cm" -n cve-demo-prod -o jsonpath='{.data.SCAN_SUMMARY}')
  oc create cm demo-baseline -n cve-demo-ci --from-literal=digest="${img#*@}" --from-literal=summary="$summary" \
     --from-literal=base="$BASELINE_DIGEST" --from-literal=app="$(app_sum)" --dry-run=client -o yaml | oc apply -f - >/dev/null
  ok "baseline recorded: prod runs ${img#*@} ($summary)"
fi

acs_policy enforce
acs_signature enforce

say "Trusted Profile Analyzer: Red Hat VEX importer for the demo CVEs, baseline base SBOM"
base=$(oc get cm demo-baseline -n cve-demo-ci -o jsonpath='{.data.digest}')
basebase=$(oc get cm demo-baseline -n cve-demo-ci -o jsonpath='{.data.base}')
stage=$(oc get deploy app -n cve-demo-stage -o jsonpath='{.spec.template.spec.containers[0].image}')

cves=$(for img in "$QUAY_HOST/$QUAY_ORG/app@$base" "$stage"; do
  acs -X POST "$ACS_URL/v1/images/scan" -d "{\"imageName\":\"$img\"}" \
    | python3 -c 'import sys,json; [print(v["cve"].lower()) for c in json.load(sys.stdin).get("scan",{}).get("components",[]) for v in c.get("vulns",[])]'
done | sort -u)
n=$(printf '%s\n' "$cves" | grep -c . || true)
[ "$n" -gt 0 ] || die "ACS returned no CVEs for the demo images"
patterns=$(printf '%s\n' "$cves" | python3 -c 'import sys,json,re; print(json.dumps([re.escape(c.strip())+r"\.json$" for c in sys.stdin if c.strip()]))')
sum=$(printf '%s' "$patterns" | shasum -a 256 | cut -c1-8)
name="redhat-vex-demo-$sum"

existing=$(tpa_api GET /api/v3/importer | python3 -c 'import sys,json; [print(i["name"]) for i in json.load(sys.stdin)]')
if grep -qx "$name" <<<"$existing"; then
  ok "importer $name already covers these $n CVEs"
else
  for old in $(printf '%s\n' "$existing" | grep '^redhat-vex-demo-' || true); do
    tpa_api PUT "/api/v3/importer/$old/enabled" -H 'Content-Type: application/json' -d false -o /dev/null
  done
  body=$(python3 -c '
import json,sys
print(json.dumps({"csaf":{"source":"redhat.com","period":"1d","onlyPatterns":json.loads(sys.argv[1]),
  "description":"Red Hat VEX for the CVEs ACS reports on the demo images, demo-sized"}}))' "$patterns")
  code=$(tpa_api POST "/api/v3/importer/$name" -H 'Content-Type: application/json' -d "$body" -o /dev/null -w '%{http_code}')
  [ "$code" = 201 ] || die "creating importer $name failed (HTTP $code)"
  ok "importer $name: Red Hat VEX for $n CVEs (runs now, then daily)"
fi

say "Red Hat SBOM of the baseline base image into Trusted Profile Analyzer"
base_sbom "$basebase" baseline && ok "baseline base SBOM uploaded (or already present)"
ok "demo ready: run demo/cve-fire-drill/run.sh when the advisory should arrive"
