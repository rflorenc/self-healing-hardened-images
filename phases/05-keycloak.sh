#!/usr/bin/env bash
# Phase 5: Keycloak with PostgreSQL and realm tas-chains, Chains' signing identity
cd "$(dirname "$0")/.." && . lib/env.sh
require_cluster
KC_HOST="keycloak-$KC_NS.$DOMAIN"
PG_NS=$KC_NS; PG_DB=keycloak
fill() { render "$1" KC_NS KC_HOST PG_NS PG_DB; }
secret() {  # secret <name> <key>: generated random value, created once
  oc get secret "$1" -n "$KC_NS" >/dev/null 2>&1 || oc create secret generic "$1" -n "$KC_NS" \
    --from-literal="$2"="$(openssl rand -hex 24)" >/dev/null
}

say "PostgreSQL for Keycloak"
mkns "$KC_NS"
oc get secret postgres -n "$KC_NS" >/dev/null 2>&1 || oc create secret generic postgres -n "$KC_NS" \
  --from-literal=username=keycloak --from-literal=password="$(openssl rand -hex 24)" >/dev/null
fill manifests/common/postgres.yaml | oc apply -f - >/dev/null
oc rollout status statefulset/postgres -n "$KC_NS" --timeout=300s >/dev/null || die "PostgreSQL not ready: oc get pods -n $KC_NS"
ok "PostgreSQL ready"

say "Keycloak at https://$KC_HOST"
fill manifests/05-keycloak/keycloak.yaml | oc apply -f - >/dev/null
for _ in $(seq 1 60); do
  [ "$(oc get keycloak keycloak -n "$KC_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] \
    && [ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://$KC_HOST/realms/master")" = 200 ] && break
  sleep 10
done
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://$KC_HOST/realms/master")" = 200 ] \
  || die "Keycloak not reachable after 10 minutes: oc get keycloak keycloak -n $KC_NS -o yaml; oc get pods,route -n $KC_NS"
ok "Keycloak ready"

say "realm tas-chains (signing identity for Tekton Chains)"
secret tas-chains-client client-secret
fill manifests/05-keycloak/realm-tas-chains.yaml | oc apply -f - >/dev/null
for _ in $(seq 1 30); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://$KC_HOST/realms/tas-chains/.well-known/openid-configuration")" = 200 ] && break
  sleep 10
done
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://$KC_HOST/realms/tas-chains/.well-known/openid-configuration")" = 200 ] \
  || die "realm tas-chains not imported: oc get keycloakrealmimport tas-chains -n $KC_NS -o yaml"
ok "realm tas-chains: https://$KC_HOST/realms/tas-chains"
