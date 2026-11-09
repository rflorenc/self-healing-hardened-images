#!/usr/bin/env python3
"""Generates demo-overview.drawio; PNG: drawio -x -f png -s 2 -o demo-overview.png demo-overview.drawio"""
from pathlib import Path
from xml.sax.saxutils import escape

FONT = 'fontFamily=Helvetica;fontColor=#333333;'
S = {
    'cluster': f'rounded=1;arcSize=1;whiteSpace=wrap;html=1;fillColor=none;strokeColor=#4D4D4D;strokeWidth=2;verticalAlign=top;align=left;spacingLeft=12;spacingTop=6;fontSize=16;fontStyle=1;{FONT}',
    'band': f'rounded=1;arcSize=4;whiteSpace=wrap;html=1;fillColor=#F2F2F2;strokeColor=#BFBFBF;verticalAlign=top;align=left;spacingLeft=10;spacingTop=4;fontSize=12;fontStyle=1;{FONT}',
    'ns': f'rounded=1;arcSize=3;whiteSpace=wrap;html=1;fillColor=#FAFAFA;strokeColor=#999999;dashed=1;dashPattern=6 3;verticalAlign=top;align=left;spacingLeft=10;spacingTop=4;fontSize=12;fontStyle=1;{FONT}',
    'op': f'rounded=1;arcSize=10;whiteSpace=wrap;html=1;fillColor=#E6E6E6;strokeColor=#808080;fontSize=11;{FONT}',
    'comp': f'rounded=1;arcSize=8;whiteSpace=wrap;html=1;fillColor=#FFFFFF;strokeColor=#666666;fontSize=11;{FONT}',
    'comp_dark': 'rounded=1;arcSize=8;whiteSpace=wrap;html=1;fillColor=#595959;strokeColor=#404040;fontSize=11;fontFamily=Helvetica;fontColor=#FFFFFF;',
    'task': f'rounded=0;whiteSpace=wrap;html=1;fillColor=#F2F2F2;strokeColor=#808080;fontSize=10;{FONT}',
    'ext': f'rounded=1;arcSize=8;whiteSpace=wrap;html=1;fillColor=#EDEDED;strokeColor=#808080;fontSize=11;{FONT}',
    'actor': f'shape=umlActor;verticalLabelPosition=bottom;verticalAlign=top;html=1;outlineConnect=0;fillColor=#FFFFFF;strokeColor=#666666;fontSize=11;{FONT}',
    'title': f'text;html=1;align=left;verticalAlign=top;fontSize=20;fontStyle=1;{FONT}',
    'note': f'text;html=1;align=left;verticalAlign=top;whiteSpace=wrap;fontSize=11;{FONT}',
    'flow': 'edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;strokeColor=#404040;strokeWidth=1.5;endArrow=blockThin;endFill=1;fontSize=11;fontStyle=1;fontFamily=Helvetica;fontColor=#FFFFFF;labelBackgroundColor=#404040;',
    'data': 'edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;strokeColor=#A6A6A6;strokeWidth=1.2;dashed=1;endArrow=open;endFill=0;fontSize=10;fontFamily=Helvetica;fontColor=#666666;labelBackgroundColor=#FFFFFF;',
}

cells = []


def node(id, label, x, y, w, h, style, parent='1'):
    cells.append(f'<mxCell id="{id}" value="{escape(label, {chr(34): "&quot;"})}" style="{S[style]}" vertex="1" parent="{parent}">'
                 f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')
    return id


def edge(id, src, dst, label='', style='flow', exit=None, entry=None, points=()):
    st = S[style]
    if exit:
        st += f'exitX={exit[0]};exitY={exit[1]};exitDx=0;exitDy=0;'
    if entry:
        st += f'entryX={entry[0]};entryY={entry[1]};entryDx=0;entryDy=0;'
    pts = ''.join(f'<mxPoint x="{px}" y="{py}"/>' for px, py in points)
    geo = f'<mxGeometry relative="1" as="geometry">{"<Array as=\"points\">" + pts + "</Array>" if pts else ""}</mxGeometry>'
    lab = escape(f"&nbsp;{label}&nbsp;" if label and style == "flow" else label, {chr(34): "&quot;"})
    cells.append(f'<mxCell id="{id}" value="{lab}" style="{st}" edge="1" parent="1" source="{src}" target="{dst}">{geo}</mxCell>')


B = '<b>{}</b>'.format  # bold helper for HTML labels

# ------------------------------------------------------------------ frame and title
node('title', 'Self-healing hardened images on OpenShift', 20, 0, 1200, 30, 'title')
node('cluster', 'Red Hat OpenShift 4.20 to 4.22', 260, 60, 1840, 1080, 'cluster')

# ------------------------------------------------------------------ outside the cluster
node('hi', f'{B("Red Hat Hardened Images")}<br>registry.access.redhat.com/hi/python:3.11<br>signature · attestation · SBOM per digest', 20, 80, 225, 80, 'ext')
node('dev', 'Developer', 105, 330, 30, 50, 'actor')
node('approver', 'Approver<br>the one human step', 105, 640, 30, 50, 'actor')
node('secdata', f'{B("Red Hat security data")}<br>VEX in CSAF, vulnerability bundles', 2125, 640, 200, 60, 'ext')

# ------------------------------------------------------------------ row A
node('ns_gitea', 'gitea', 280, 100, 250, 360, 'ns')
node('gitea', B('Gitea'), 300, 135, 210, 36, 'comp')
node('repo_app', f'{B("cve-demo/app")}<br>app.py · Containerfile<br>base image digest', 300, 200, 210, 70, 'comp')
node('repo_gitops', f'{B("cve-demo/gitops")}<br>overlays/stage · overlays/prod<br>digest + scan summary', 300, 295, 210, 70, 'comp')
node('pr', 'Pull request into protected prod<br>ACS · Conforma · SBOM lines', 300, 390, 210, 50, 'comp_dark')

node('ns_ci', 'cve-demo-ci', 560, 100, 760, 360, 'ns')
node('cron', f'{B("CronJob base-watch")}<br>schedule', 580, 135, 200, 50, 'comp')
node('pl_watch', f'{B("Pipeline base-watch")}<br>bump-base-image, skopeo', 830, 135, 200, 50, 'comp')
node('el', f'{B("EventListener app-push")}<br>CEL filter, [skip ci]', 1090, 135, 210, 50, 'comp')
node('pl_build', 'Pipeline build-and-stage', 580, 210, 720, 100, 'band')
tasks = ['git-clone', 'buildah', 'acs-image-check<br>roxctl', 'conforma-check<br>ec', 'sbom-upload<br>Red Hat SBOM', 'gitops-promote']
for i, t in enumerate(tasks):
    node(f't{i}', t, 595 + i * 117, 245, 105, 50, 'task')
node('secrets', f'{B("Secrets")}<br>gitea-token · acs-ci-token<br>quay-robot-pipeline · tpa-cli-client', 580, 340, 230, 66, 'comp')
node('policy', f'{B("ConfigMap conforma-policy")}<br>policy.yaml · cve_demo.rego', 830, 340, 200, 50, 'comp')
node('cicaption', 'Checks run in parallel after the build; promote waits for all three.', 1050, 340, 250, 50, 'note')

node('ns_tekton', 'openshift-pipelines', 1340, 100, 230, 360, 'ns')
node('chains', f'{B("Tekton Chains")}<br>keyless signature + SLSA<br>provenance, in-toto', 1355, 135, 200, 70, 'comp')
node('refresher', f'{B("Token refresher")}<br>Keycloak token for Chains<br>every 2 minutes', 1355, 245, 200, 66, 'comp')

node('ns_quay', 'quay', 1590, 100, 240, 360, 'ns')
node('quay', f'{B("Red Hat Quay")}<br>cve-demo/app<br>image · .sig · .att', 1605, 135, 210, 70, 'comp')
node('robots', f'{B("Robot accounts")}<br>pipeline: write · puller: read', 1605, 245, 210, 50, 'comp')

node('ns_tas', 'trusted-artifact-signer', 1850, 100, 230, 360, 'ns')
node('fulcio', f'{B("Fulcio")}<br>10-minute certificates for<br>the Keycloak identity', 1865, 135, 200, 66, 'comp')
node('rekor', f'{B("Rekor")}<br>transparency log', 1865, 235, 200, 50, 'comp')
node('tuf', f'{B("TUF · CT log · Trillian")}<br>trust root', 1865, 320, 200, 50, 'comp')

# ------------------------------------------------------------------ row B
node('ns_gitops', 'cve-demo-gitops', 280, 500, 250, 300, 'ns')
node('argocd', f'{B("Argo CD")}<br>dedicated instance, polls every 30 s', 300, 535, 210, 50, 'comp')
node('app_stage', 'Application app-stage<br>main, auto-sync', 300, 615, 210, 44, 'comp')
node('app_prod', 'Application app-prod<br>prod branch, auto-sync', 300, 685, 210, 44, 'comp')

node('ns_stage', 'cve-demo-stage', 560, 500, 170, 300, 'ns')
node('d_stage', f'{B("Deployment app")}<br>Service · Route', 570, 615, 150, 50, 'comp')
node('ns_prod', 'cve-demo-prod', 750, 500, 170, 300, 'ns')
node('d_prod', f'{B("Deployment app")}<br>Service · Route', 760, 685, 150, 50, 'comp')

node('ns_acs', 'stackrox', 940, 500, 430, 370, 'ns')
L, R, W = 955, 1170, 185
node('collector', f'{B("Collector")}<br>runtime data, every node', L, 535, W, 50, 'comp')
node('central', f'{B("Central")}<br>API · UI · policies', R, 535, W, 56, 'comp')
node('admission', f'{B("Admission controller")}<br>enforces deploy policies', L, 615, W, 60, 'comp')
node('sensor', f'{B("Sensor")}<br>delegated scanning<br>of Quay', R, 615, W, 60, 'comp')
node('pol_fix', f'{B("Policy")}: fixable CVE,<br>Important or Critical<br>build gate', L, 700, W, 66, 'comp')
node('scanner', f'{B("Scanner V4")}<br>indexer · matcher · DB', R, 700, W, 56, 'comp')
node('pol_sig', f'{B("Policy")}: signed by the<br>pipeline only, cve-demo-prod', L, 790, W, 50, 'comp')
node('sigint', f'{B("Signature integration")}<br>Fulcio identity · Rekor', R, 790, W, 50, 'comp')

node('ns_kc', 'demo-keycloak', 1390, 500, 210, 300, 'ns')
node('keycloak', f'{B("Red Hat build of Keycloak")}<br>PostgreSQL', 1400, 535, 190, 50, 'comp')
node('realm_tas', f'{B("realm tas-chains")}<br>chains@cve-demo.local', 1400, 615, 190, 50, 'comp')
node('realm_tpa', f'{B("realm tpa")}<br>UI: auditor · API: pipeline', 1400, 695, 190, 50, 'comp')

node('ns_tpa', 'trusted-profile-analyzer', 1620, 500, 230, 300, 'ns')
node('tpa', f'{B("Trusted Profile Analyzer")}<br>SBOMs, advisories, VEX<br>PostgreSQL', 1635, 535, 200, 66, 'comp')
node('importer', f'{B("Importer")}<br>Red Hat VEX for the<br>scanned CVEs, daily', 1635, 640, 200, 66, 'comp')

node('ns_storage', 'openshift-storage', 1870, 500, 210, 300, 'ns')
node('noobaa', f'{B("NooBaa, S3")}<br>Multicloud Object Gateway', 1880, 535, 190, 66, 'comp')
node('buckets', 'buckets: Quay images,<br>TPA documents', 1880, 640, 190, 44, 'comp')

# ------------------------------------------------------------------ operators band (bottom)
node('ops', 'Operators', 280, 905, 1800, 215, 'band')
ops = ['OpenShift Pipelines 1.24<br>Pipelines · Triggers · Chains', 'OpenShift GitOps 1.22<br>Argo CD',
       'Advanced Cluster Security 5.0<br>Central · Secured cluster', 'Red Hat Quay 3.18', 'OpenShift Data Foundation<br>NooBaa',
       'Red Hat build of Keycloak 26.6', 'Trusted Artifact Signer 1.5', 'Trusted Profile Analyzer 3.1', 'Gitea operator']
for i, lab in enumerate(ops):
    row, col = divmod(i, 5)
    node(f'op{i}', lab, 300 + col * 355, 940 + row * 85, 335, 60, 'op')

# ------------------------------------------------------------------ demo flow edges
edge('e1', 'pl_watch', 'hi', '1', exit=(0.5, 0), entry=(0.5, 0), points=[(930, 50), (132, 50)])
edge('e2', 'pl_watch', 'repo_app', '2', exit=(0, 1), entry=(1, 0.5), points=[(840, 195), (545, 195), (545, 235)])
edge('e3', 'repo_app', 'el', '3', exit=(1, 0.2), entry=(0.5, 0), points=[(552, 214), (552, 122), (1195, 122)])
edge('e3b', 'el', 't0', style='data', exit=(0.5, 1), entry=(0.5, 0), points=[(1195, 200), (647, 200)])
edge('e4', 't1', 'quay', '4', exit=(0.5, 1), entry=(0.25, 1), points=[(764, 325), (1657, 325)])
edge('e5', 'chains', 'fulcio', '5', exit=(1, 0.2), entry=(0, 0.3), points=[(1580, 149), (1580, 115), (1845, 115), (1845, 155)])
edge('e5b', 'chains', 'quay', 'sig · att', style='data', exit=(1, 0.6), entry=(0, 0.6))
edge('e5c', 'chains', 'rekor', 'log entry', style='data', exit=(1, 0.9), entry=(0, 0.5), points=[(1585, 198), (1585, 228), (1840, 228), (1840, 260)])
edge('e6', 't2', 'central', '6', exit=(0.5, 1), entry=(0.5, 0), points=[(881, 480), (1262, 480)])
edge('e6b', 't4', 'tpa', '6', exit=(0.5, 1), entry=(0.5, 0), points=[(1115, 470), (1735, 470)])
edge('e6c', 't3', 'tuf', 'verify keyless', style='data', exit=(0.5, 1), entry=(0, 0.5), points=[(998, 318), (1835, 318), (1835, 345)])
edge('e7', 't5', 'repo_gitops', '7', exit=(0.5, 1), entry=(1, 0.5), points=[(1232, 488), (540, 488), (540, 330)])
edge('e8', 'app_stage', 'd_stage', '8', exit=(1, 0.5), entry=(0, 0.5))
edge('e9a', 'approver', 'pr', '9', exit=(1, 0.3), entry=(0, 0.5), points=[(272, 655), (272, 415)])
edge('e9', 'app_prod', 'd_prod', '9', exit=(1, 0.5), entry=(0, 0.5))
edge('e10', 'admission', 'd_prod', '10', exit=(0, 0.5), entry=(1, 0.5), points=[(930, 645), (930, 710)])

# ------------------------------------------------------------------ supporting data edges
edge('d_dev', 'dev', 'repo_app', 'code changes', style='data', exit=(1, 0.5), entry=(0, 0.5))
edge('d_cron', 'cron', 'pl_watch', 'starts', style='data', exit=(1, 0.5), entry=(0, 0.5))
edge('d_chains', 'chains', 'pl_build', 'watches TaskRuns', style='data', exit=(0, 0.8), entry=(1, 0.5), points=[(1330, 191), (1330, 260)])
edge('d_token', 'realm_tas', 'refresher', 'token', style='data', exit=(0.5, 0), entry=(0.5, 1), points=[(1495, 480), (1455, 480)])
edge('d_token2', 'refresher', 'chains', style='data', exit=(0.5, 0), entry=(0.5, 1))
edge('d_fulcio_kc', 'fulcio', 'realm_tas', 'trusts issuer', style='data', exit=(0, 0.8), entry=(1, 0.5), points=[(1845, 188), (1845, 490), (1610, 490), (1610, 640)])
edge('d_sbom', 'hi', 't4', 'Red Hat SBOM', style='data', exit=(1, 0.7), entry=(0.5, 0), points=[(255, 136), (255, 90), (1115, 90), (1115, 245)])
edge('d_vex_scan', 'secdata', 'scanner', 'vulnerability data', style='data', exit=(0, 0.3), entry=(1, 0.5), points=[(2110, 658), (2110, 880), (1385, 880), (1385, 728)])
edge('d_vex_tpa', 'secdata', 'importer', 'VEX', style='data', exit=(0, 0.7), entry=(1, 0.5), points=[(2100, 682), (2100, 820), (1860, 820), (1860, 673)])
edge('d_sensor', 'sensor', 'quay', 'pulls image to scan', style='data', exit=(1, 0.5), entry=(0.75, 1), points=[(1380, 645), (1380, 476), (1762, 476)])
edge('d_quay_s3', 'quay', 'noobaa', 'storage', style='data', exit=(1, 0.5), entry=(0.5, 0), points=[(1840, 170), (1840, 470), (1975, 470)])
edge('d_tpa_s3', 'tpa', 'buckets', 'storage', style='data', exit=(1, 0.8), entry=(0, 0.5), points=[(1860, 588), (1860, 662)])
edge('d_tpa_kc', 'tpa', 'realm_tpa', style='data', exit=(0, 0.5), entry=(1, 0.5))
edge('d_gitops_argo', 'repo_gitops', 'argocd', '', style='data', exit=(0, 0.5), entry=(0, 0.5), points=[(288, 330), (288, 560)])
edge('d_sigint', 'sigint', 'pol_sig', style='data', exit=(0, 0.5), entry=(1, 0.5))
edge('d_sig_rekor', 'sigint', 'rekor', 'Rekor online', style='data', exit=(1, 0.8), entry=(0.5, 1), points=[(1378, 830), (1378, 890), (1965, 890), (1965, 285)])

xml = ('<mxfile host="Electron" type="device"><diagram id="overview" name="Setup overview">'
       '<mxGraphModel dx="1600" dy="1200" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" '
       'fold="1" page="1" pageScale="1" pageWidth="2360" pageHeight="1160" math="0" shadow="0" background="#FFFFFF">'
       '<root><mxCell id="0"/><mxCell id="1" parent="0"/>' + ''.join(cells) + '</root></mxGraphModel></diagram></mxfile>')
out = Path(__file__).with_name('demo-overview.drawio')
out.write_text(xml)
print(out)
