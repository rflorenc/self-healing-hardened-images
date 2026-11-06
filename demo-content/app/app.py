"""Demo app: shows the Python version, base image and ACS scan summary."""
import logging
import os
import platform
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

ENV = os.environ.get('APP_ENV', 'unknown')
BASE = os.environ.get('BASE_IMAGE', 'unknown')
SCAN = os.environ.get('SCAN_SUMMARY', 'not scanned')  # written by the pipeline next to the image digest

logging.basicConfig(stream=sys.stdout, level=logging.INFO,
                    format='%(asctime)s %(levelname)s %(message)s')
log = logging.getLogger('app')

PAGE = """<html><head><title>CVE fire drill demo</title></head>
<body style="font-family: 'Red Hat Display', sans-serif; margin: 3em">
<h1>Hello from {env}</h1>
<p style="font-size: 1.4em"><b>{scan}</b></p>
<p>Python {py}</p>
<p>Base image: <code>{base}</code></p>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE.format(env=ENV, py=platform.python_version(), base=BASE, scan=SCAN).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
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
