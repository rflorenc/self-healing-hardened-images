"""tas-trust.py tuf-url cafile: print the Trusted Artifact Signer trust root as PEM."""
import base64, json, ssl, sys, textwrap, urllib.request

tuf, cafile = sys.argv[1].rstrip('/'), sys.argv[2]
ctx = ssl.create_default_context(cafile=cafile)


def get(path):
    return urllib.request.urlopen(f'{tuf}/{path}', context=ctx, timeout=30).read()


def pem(kind, b64der):
    body = '\n'.join(textwrap.wrap(b64der, 64))
    return f'-----BEGIN {kind}-----\n{body}\n-----END {kind}-----\n'


snap_v = json.loads(get('timestamp.json'))['signed']['meta']['snapshot.json']['version']
targets_v = json.loads(get(f'{snap_v}.snapshot.json'))['signed']['meta']['targets.json']['version']
target = json.loads(get(f'{targets_v}.targets.json'))['signed']['targets']['trusted_root.json']
root = json.loads(get(f"targets/{target['hashes']['sha256']}.trusted_root.json"))

chain = ''.join(pem('CERTIFICATE', c['rawBytes'])
                for c in root['certificateAuthorities'][-1]['certChain']['certificates'])
print(json.dumps({
    'fulcio_chain': chain,
    'rekor_key': pem('PUBLIC KEY', root['tlogs'][-1]['publicKey']['rawBytes']),
    'ctlog_key': pem('PUBLIC KEY', root['ctlogs'][-1]['publicKey']['rawBytes']),
}))
