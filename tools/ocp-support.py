"""ocp-support.py <ocp version> [<ocp version> ...]"""
import json, sys, urllib.parse, urllib.request

PACKAGES = ["openshift-pipelines-operator-rh", "openshift-gitops-operator", "rhacs-operator", "odf-operator",
            "quay-operator", "rhbk-operator", "rhtas-operator", "rhtpa-operator"]
API = "https://catalog.redhat.com/api/containers/v1/operators/bundles"


def newest(package, ocp):
    q = urllib.parse.urlencode({
        "filter": f"package=={package};organization==redhat-operators;ocp_version=={ocp}",
        "page_size": 200, "include": "data.channel_name,data.version,data.csv_name"})
    data = json.load(urllib.request.urlopen(f"{API}?{q}", timeout=60)).get("data", [])
    if not data:
        return "not published"
    def key(b):
        return [int(p) if p.isdigit() else 0 for p in b.get("version", "0").replace("-", ".").split(".")[:4]]
    best = max(data, key=key)
    return f"{best.get('version')} on {best.get('channel_name')}"


versions = sys.argv[1:] or ["4.20", "4.22"]
print(f"{'operator':34}" + "".join(f"{v:>28}" for v in versions))
for p in PACKAGES:
    print(f"{p:34}" + "".join(f"{newest(p, v):>28}" for v in versions))
