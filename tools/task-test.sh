#!/usr/bin/env bash
# task-test.sh task [image]: run one demo task once against an image, default the prod image
cd "$(dirname "$0")/.." && . lib/env.sh
task=${1:?usage: task-test.sh <task> [image]}
img=${2:-$(oc get deploy app -n cve-demo-prod -o jsonpath='{.spec.template.spec.containers[0].image}')}
tr=$(oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: tekton.dev/v1
kind: TaskRun
metadata: {generateName: $task-test-, namespace: cve-demo-ci}
spec:
  taskRef: {name: $task}
  params: [{name: IMAGE, value: "$img"}]
  taskRunTemplate: {serviceAccountName: pipeline}
EOF
)
say "$task on ${img##*/} ($tr)"
st=""
for _ in $(seq 1 60); do
  st=$(oc get taskrun "$tr" -n cve-demo-ci -o jsonpath='{.status.conditions[0].status}')
  [ "$st" = True ] || [ "$st" = False ] && break; sleep 5
done
oc logs -n cve-demo-ci -l "tekton.dev/taskRun=$tr" --tail=60 2>/dev/null | grep -vE '^\s*$' || true
summary=$(oc get taskrun "$tr" -n cve-demo-ci -o jsonpath='{.status.results[?(@.name=="SUMMARY")].value}')
[ "$st" = True ] && ok "${summary:-$task passed}" || die "${summary:-$task failed} ($tr)"
