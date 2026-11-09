#!/usr/bin/env bash
# Demo actions shared by phase 10 and demo/cve-fire-drill; sourced through lib/env.sh
# shellcheck shell=bash

pin_base() {  # pin_base <digest> <message>: pin the base image of cve-demo/app; returns 3 if already pinned
  local digest=$1 msg=$2 token tmp current
  token=$(oc get secret gitea-token -n cve-demo-ci -o jsonpath='{.data.token}' | base64 -d)
  tmp=$(mktemp -d)
  git clone -q "https://pipeline-bot:$token@${GITEA_URL#https://}/$GITEA_ORG/app.git" "$tmp/app"
  current=$(grep -oE 'sha256:[a-f0-9]{64}' "$tmp/app/Containerfile" | head -1)
  if [ "$current" = "$digest" ]; then rm -rf "$tmp"; ok "base image already pinned to ${digest:0:19}…"; return 3; fi
  sed -i.bak "s#$current#$digest#g" "$tmp/app/Containerfile" && rm -f "$tmp/app/Containerfile.bak"
  git -C "$tmp/app" -c user.name="cve-demo setup" -c user.email="setup@cve-demo.local" commit -qam "$msg" \
    -m "Base image ${BASE_REPO}:${BASE_STREAM}@${digest} (was ${current})."
  git -C "$tmp/app" push -q origin HEAD:main
  rm -rf "$tmp"
  ok "pinned base image ${digest:0:19}… ($msg)"
}

run_build() {  # run_build [revision]: start build-and-stage without a push
  cat <<PR | oc create -f - -o name
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata: {generateName: build-and-stage-, namespace: cve-demo-ci}
spec:
  pipelineRef: {name: build-and-stage}
  params: [{name: REVISION, value: "${1:-main}"}]
  taskRunTemplate: {serviceAccountName: pipeline}
  workspaces:
    - name: source
      volumeClaimTemplate:
        spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}
PR
}

wait_build() {  # wait_build [since]: follow the newest build-and-stage run created after an ISO-8601 UTC time
  local since=${1:-1970-01-01T00:00:00Z} run="" status="" task v
  for _ in $(seq 1 30); do
    run=$(oc get pipelineruns.tekton.dev -n cve-demo-ci -l tekton.dev/pipeline=build-and-stage -o json | python3 -c "
import sys,json
r=[x for x in json.load(sys.stdin)['items'] if x['metadata']['creationTimestamp']>='$since']
r.sort(key=lambda x: x['metadata']['creationTimestamp']); print(r[-1]['metadata']['name'] if r else '')")
    [ -n "$run" ] && break; sleep 5
  done
  [ -n "$run" ] || die "no build-and-stage run started after $since (check the Gitea webhook and EventListener logs)"
  say "following $run"
  for _ in $(seq 1 120); do
    status=$(oc get pipelineruns.tekton.dev "$run" -n cve-demo-ci -o jsonpath='{.status.conditions[0].status}')
    [ "$status" = True ] || [ "$status" = False ] && break; sleep 10
  done
  oc get taskrun -n cve-demo-ci -l "tekton.dev/pipelineRun=$run" --sort-by=.status.startTime \
    -o custom-columns='  TASK:.metadata.labels.tekton\.dev/pipelineTask,RESULT:.status.conditions[0].reason' --no-headers
  for task in acs-check conforma sbom; do
    v=$(oc get taskrun -n cve-demo-ci -l "tekton.dev/pipelineRun=$run,tekton.dev/pipelineTask=$task" \
      -o jsonpath='{.items[0].status.results[?(@.name=="SUMMARY")].value}' 2>/dev/null || true)
    [ -n "$v" ] && printf '  %s\n' "$v"
  done
  [ "$status" = True ] && ok "$run succeeded" || die "$run failed: oc get pipelineruns.tekton.dev $run -n cve-demo-ci"
}

approve_pr() {  # approve_pr [number]: approve and merge a prod pull request as user approver
  local u p r n title code
  u=$(oc get secret gitea-approver -n cve-demo-ci -o jsonpath='{.data.username}' | base64 -d)
  p=$(oc get secret gitea-approver -n cve-demo-ci -o jsonpath='{.data.password}' | base64 -d)
  r="$GITEA_URL/api/v1/repos/$GITEA_ORG/gitops"
  n=${1:-$(curl -sS -u "$u:$p" "$r/pulls?state=open&sort=newest" | python3 -c '
import sys,json; p=[x for x in json.load(sys.stdin) if x["base"]["ref"]=="prod"]; print(p[0]["number"] if p else "")')}
  [ -n "$n" ] || die "no open pull request against prod"
  title=$(curl -sS -u "$u:$p" "$r/pulls/$n" | python3 -c 'import sys,json; print(json.load(sys.stdin)["title"])')
  say "approving and merging #$n: $title"
  curl -sS -u "$u:$p" -H 'Content-Type: application/json' -X POST "$r/pulls/$n/reviews" \
    -d '{"event":"APPROVED","body":"Approved for production: rebuilt, scanned and signed by the pipeline; verified in stage."}' -o /dev/null
  code=$(curl -sS -u "$u:$p" -H 'Content-Type: application/json' -X POST "$r/pulls/$n/merge" -o /dev/null -w '%{http_code}' \
    -d "{\"Do\":\"merge\",\"merge_message_field\":\"Approve #$n: $title\",\"delete_branch_after_merge\":true}")
  [ "$code" = 200 ] || die "merge of #$n failed (HTTP $code)"
  ok "#$n merged into prod by $u"
}
