#!/usr/bin/env bash
# keycloak-reimport.sh tas-chains|tpa: re-import a realm after its manifest changed
cd "$(dirname "$0")/.." && . lib/env.sh
realm=${1:?usage: keycloak-reimport.sh <tas-chains|tpa>}
case $realm in tas-chains) step=phases/05-keycloak.sh ;; tpa) step=phases/07-tpa.sh ;; *) die "unknown realm $realm" ;; esac
KC="https://keycloak-$KC_NS.$DOMAIN"
U=$(oc get secret keycloak-initial-admin -n "$KC_NS" -o jsonpath='{.data.username}' | base64 -d)
P=$(oc get secret keycloak-initial-admin -n "$KC_NS" -o jsonpath='{.data.password}' | base64 -d)
T=$(curl -s -m 30 -d grant_type=password -d client_id=admin-cli --data-urlencode "username=$U" --data-urlencode "password=$P" \
  "$KC/realms/master/protocol/openid-connect/token" | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])') \
  || die "Keycloak admin login failed"
code=$(curl -s -m 30 -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $T" "$KC/admin/realms/$realm")
case $code in 204|404) ok "realm $realm deleted (HTTP $code)" ;; *) die "could not delete realm $realm (HTTP $code)" ;; esac
oc delete keycloakrealmimport "$realm" -n "$KC_NS" --ignore-not-found >/dev/null
"$step"
# new realm keys: restart what cached the old ones
if [ "$realm" = tpa ]; then
  oc rollout restart deploy/server deploy/importer -n "$TPA_NS" >/dev/null
  oc rollout status deploy/server -n "$TPA_NS" --timeout=180s >/dev/null && ok "Trusted Profile Analyzer restarted (new realm keys)"
else
  oc rollout restart deploy/fulcio-server -n "$TAS_NS" >/dev/null
  oc rollout status deploy/fulcio-server -n "$TAS_NS" --timeout=180s >/dev/null && ok "Fulcio restarted (new realm keys)"
fi
