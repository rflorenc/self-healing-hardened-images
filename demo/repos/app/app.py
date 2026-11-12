"""Demo app: a status page with the ACS result at build, the base image and links to the evidence."""
import html
import logging
import os
import platform
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

ENV = os.environ.get('APP_ENV', 'unknown')
BASE = os.environ.get('BASE_IMAGE', 'unknown')
SCAN = os.environ.get('SCAN_SUMMARY', 'not scanned')  # written by the pipeline next to the image digest

logging.basicConfig(stream=sys.stdout, level=logging.INFO,
                    format='%(asctime)s %(levelname)s %(message)s')
log = logging.getLogger('app')

STYLE = """
body{margin:0;font-family:'Red Hat Display','Red Hat Text',Helvetica,Arial,sans-serif;color:#151515;background:#f2f2f2}
.band{padding:18px 40px;color:#fff;font-size:22px;font-weight:700;letter-spacing:.08em}
.stage{background:#0066cc}.prod{background:#151515}.unknown{background:#6a6e73}
main{max-width:880px;margin:32px auto;padding:0 24px}
.card{background:#fff;border-radius:8px;padding:28px 32px;margin-bottom:20px;box-shadow:0 1px 3px rgba(0,0,0,.12)}
.hero{display:flex;align-items:center;gap:28px}
.num{font-size:96px;font-weight:700;line-height:1}
.bad{color:#ee0000}.good{color:#3e8635}
.label{font-size:22px;font-weight:600}.sub{color:#6a6e73;margin-top:6px}
.facts{display:grid;grid-template-columns:max-content 1fr;gap:8px 20px;font-size:17px}
.facts span{color:#6a6e73}
code{font-family:'Red Hat Mono',Menlo,monospace;font-size:15px}
h2{font-size:18px;margin:0 0 14px}
ul{list-style:none;margin:0;padding:0}
li{padding:8px 0;border-top:1px solid #e0e0e0;font-size:17px}
li:first-child{border-top:none}
.ok{color:#3e8635;font-weight:700;margin-right:10px}
li a{float:right;color:#0066cc;text-decoration:none;margin-left:16px}
footer{color:#6a6e73;font-size:13px;text-align:center;margin-top:8px}
"""


def links(host):
    """URLs of the product UIs, derived from this app's route host app-<namespace>.<apps domain>."""
    host = host.split(':')[0]
    if not host.startswith('app-') or '.' not in host:
        return {}
    domain = host.split('.', 1)[1]
    return {
        'quay': f'https://registry-quay-quay.{domain}/repository/cve-demo/app?tab=tags',
        'rekor': f'https://rekor-server-trusted-artifact-signer.{domain}/api/v1/log',
        'acs': f'https://central-stackrox.{domain}/',
        'runs': f'https://console-openshift-console.{domain}/k8s/ns/cve-demo-ci/tekton.dev~v1~PipelineRun',
        'tpa': f'https://server-trusted-profile-analyzer.{domain}/sboms',
        'pulls': f'https://gitea-gitea.{domain}/cve-demo/gitops/pulls',
    }


def page(host):
    m = re.search(r'(\d+) fixable.*?\((\d+) known', SCAN)
    if m:
        fixable, known = int(m.group(1)), m.group(2)
        hero = (f'<div class="num {"bad" if fixable else "good"}">{fixable}</div>'
                f'<div><div class="label">fixable Important or Critical CVEs at build</div>'
                f'<div class="sub">{known} known in total, scanned by Advanced Cluster Security</div></div>')
    else:
        hero = f'<div class="label">{html.escape(SCAN)}</div>'
    repo, _, digest = BASE.partition('@')
    short = digest[:19] + '…' if digest else ''
    url = links(host)

    def item(text, *refs):
        a = ''.join(f'<a href="{url[k]}" target="_blank">{name}</a>' for name, k in refs if k in url)
        return f'<li><span class="ok">✔</span>{text}{a}</li>'

    approval = (item('Promoted to production only after a person approved', ('Pull requests', 'pulls')) if ENV == 'prod'
                else item('Reaches production only after one approval', ('Pull requests', 'pulls')))
    trust = ''.join([
        item('Signed keyless by the pipeline, logged in Rekor', ('Rekor', 'rekor'), ('Quay', 'quay')),
        item('Scanned at build by Advanced Cluster Security', ('ACS', 'acs')),
        item('Release policy checked by Conforma', ('Pipeline runs', 'runs')),
        item("Red Hat's SBOM of the base in Trusted Profile Analyzer", ('SBOMs', 'tpa')),
        approval,
    ])
    env = html.escape(ENV)
    cls = env if env in ('stage', 'prod') else 'unknown'
    return f"""<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="5">
<title>{env.upper()}: CVE fire drill</title><style>{STYLE}</style></head><body>
<div class="band {cls}">{env.upper()}</div>
<main>
<div class="card hero">{hero}</div>
<div class="card facts">
<span>Python</span><b>{platform.python_version()}</b>
<span>Base image</span><code title="{html.escape(BASE)}">{html.escape(repo)} @ {html.escape(short)}</code>
</div>
<div class="card"><h2>Why you can trust this image</h2><ul>{trust}</ul></div>
<footer>Refreshes every 5 seconds</footer>
</main></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = page(self.headers.get('Host', '')).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # skip the kubelet readiness probe
        if self.headers.get('User-Agent', '').startswith('kube-probe'):
            return
        log.info('%s %s', self.address_string(), fmt % args)


if __name__ == '__main__':
    log.info('starting: env=%s python=%s base_image=%s', ENV, platform.python_version(), BASE)
    log.info('%s', SCAN)
    log.info('listening on :8080')
    HTTPServer(('', 8080), Handler).serve_forever()
