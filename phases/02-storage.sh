#!/usr/bin/env bash
# Phase 2: NooBaa object storage, the S3 backend for Quay and Trusted Profile Analyzer
cd "$(dirname "$0")/.." && . lib/env.sh
require_cluster

say "NooBaa object storage (OpenShift Data Foundation, standalone Multicloud Object Gateway)"
if [ -z "$(oc get storagecluster -n openshift-storage -o name 2>/dev/null)" ] || ours storagecluster ocs-storagecluster -n openshift-storage; then
  oc apply -f manifests/02-storage/mcg.yaml >/dev/null
else
  ok "a StorageCluster already exists (not ours): leaving it unchanged"
fi
for _ in $(seq 1 90); do
  [ "$(oc get noobaa noobaa -n openshift-storage -o jsonpath='{.status.phase}' 2>/dev/null)" = Ready ] && break; sleep 10
done
[ "$(oc get noobaa noobaa -n openshift-storage -o jsonpath='{.status.phase}' 2>/dev/null)" = Ready ] \
  || die "NooBaa not ready after 15 minutes: oc get noobaa,pods -n openshift-storage"
ok "NooBaa ready"
