#!/usr/bin/env bash
# fulcio-test.sh: request a Fulcio certificate with Chains' Keycloak identity
cd "$(dirname "$0")/.." && . lib/env.sh
S=$(oc get secret tas-chains-client -n "$KC_NS" -o jsonpath='{.data.client-secret}' | base64 -d)
KC_HOST="keycloak-$KC_NS.$DOMAIN"
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
curl -s -m 30 -d grant_type=client_credentials -d client_id=trusted-artifact-signer --data-urlencode "client_secret=$S" \
  "https://$KC_HOST/realms/tas-chains/protocol/openid-connect/token" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])' > "$d/tok"
openssl ecparam -genkey -name prime256v1 -noout -out "$d/k.pem" 2>/dev/null
openssl ec -in "$d/k.pem" -pubout -out "$d/pub.pem" 2>/dev/null
printf '%s' chains@cve-demo.local | openssl dgst -sha256 -sign "$d/k.pem" | base64 | tr -d '\n' > "$d/pop"
python3 -c '
import json,sys
print(json.dumps({"credentials":{"oidcIdentityToken":open(sys.argv[1]).read().strip()},
  "publicKeyRequest":{"publicKey":{"algorithm":"ECDSA","content":open(sys.argv[2]).read()},"proofOfPossession":open(sys.argv[3]).read()}}))' \
  "$d/tok" "$d/pub.pem" "$d/pop" > "$d/req.json"
F="https://$(oc get route -n "$TAS_NS" -l app.kubernetes.io/component=fulcio -o jsonpath='{.items[0].spec.host}')"
code=$(curl -s -m 30 -o "$d/resp.json" -w '%{http_code}' -H 'Content-Type: application/json' -X POST "$F/api/v2/signingCert" -d @"$d/req.json")
[ "$code" = 200 ] || die "Fulcio answered HTTP $code: $(head -c 300 "$d/resp.json")"
python3 -c '
import json,sys
r=json.load(open(sys.argv[1]))
c=(r.get("signedCertificateEmbeddedSct") or r.get("signedCertificateDetachedSct"))["chain"]["certificates"]
open(sys.argv[2],"w").write(c[0])' "$d/resp.json" "$d/cert.pem"
openssl x509 -in "$d/cert.pem" -noout -issuer -ext subjectAltName -dates | sed 's/^/  /'
ok "Fulcio issues certificates for the Chains identity"
