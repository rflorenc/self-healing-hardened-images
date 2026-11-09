"""footprint.py: CPU and memory the demo components request, from oc get pods -A -o json."""
import collections, json, sys

NS = {"rhacs-operator": "ACS", "openshift-storage": "ODF/NooBaa", "quay": "Quay", "keycloak": "Keycloak",
      "trusted-artifact-signer": "Trusted Artifact Signer", "trusted-profile-analyzer": "Trusted Profile Analyzer",
      "gitea": "Gitea", "cve-demo-ci": "demo namespaces", "cve-demo-gitops": "demo namespaces",
      "cve-demo-stage": "demo namespaces", "cve-demo-prod": "demo namespaces", "openshift-pipelines": "Pipelines"}
UNITS = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "m": 1e-3}


def q(v):
    for k, f in UNITS.items():
        if v.endswith(k):
            return float(v[:-len(k)]) * f
    return float(v or 0)


use = collections.defaultdict(lambda: [0.0, 0.0])
for p in json.load(sys.stdin)["items"]:
    ns = p["metadata"]["namespace"]
    if ns not in NS or p["status"].get("phase") not in ("Running", "Pending"):
        continue
    for c in p["spec"]["containers"]:
        r = c.get("resources", {}).get("requests", {})
        use[NS[ns]][0] += q(r.get("cpu", "0"))
        use[NS[ns]][1] += q(r.get("memory", "0"))
tc = tm = 0.0
for k, (cpu, mem) in sorted(use.items()):
    print(f"{k:26} {cpu:5.2f} cores {mem / 2**30:6.1f} GiB")
    tc += cpu
    tm += mem
print(f"{'TOTAL requested':26} {tc:5.2f} cores {tm / 2**30:6.1f} GiB")
