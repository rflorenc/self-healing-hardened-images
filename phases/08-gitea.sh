#!/usr/bin/env bash
# Phase 8: Gitea with organisation cve-demo, repositories, users and the pipeline token
cd "$(dirname "$0")/.." && . lib/env.sh
require_cluster

say "Gitea instance in namespace $GITEA_NS"
mkns "$GITEA_NS"
if [ -z "$(oc get gitea -n "$GITEA_NS" -o name 2>/dev/null)" ]; then
  render manifests/08-gitea/gitea.yaml GITEA_NS | oc apply -f - >/dev/null
fi
for _ in $(seq 1 60); do
  host=$(oc get route gitea -n "$GITEA_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)
  [ -n "$host" ] && [ "$(curl -sk -o /dev/null -w '%{http_code}' -m 10 "https://$host/api/v1/version")" = 200 ] && break
  sleep 10
done
[ -n "${host:-}" ] || die "Gitea not ready after 10 minutes: oc get pods -n $GITEA_NS"
ok "Gitea ready: https://$host"

oc apply -f manifests/10-gitops/namespaces.yaml >/dev/null   # tokens go to cve-demo-ci
. lib/env.sh   # Gitea route and admin credentials exist now
[ -n "$GITEA_USER" ] && [ -n "$GITEA_PASS" ] || die "Gitea admin credentials not found in namespace $GITEA_NS"
code() { curl -s -o /dev/null -w '%{http_code}' -u "$GITEA_USER:$GITEA_PASS" "$1"; }

say "organisation $GITEA_ORG and repositories"
[ "$(code "$GITEA_URL/api/v1/orgs/$GITEA_ORG")" = 200 ] || \
  gitea -X POST "$GITEA_URL/api/v1/orgs" -d "{\"username\":\"$GITEA_ORG\",\"visibility\":\"public\"}" -o /dev/null
for repo in app gitops; do
  [ "$(code "$GITEA_URL/api/v1/repos/$GITEA_ORG/$repo")" = 200 ] || \
    gitea -X POST "$GITEA_URL/api/v1/orgs/$GITEA_ORG/repos" -d "{\"name\":\"$repo\",\"default_branch\":\"main\",\"private\":false}" -o /dev/null
done

user() {  # user <name> <password>   create if missing
  [ "$(code "$GITEA_URL/api/v1/users/$1")" = 200 ] && return 0
  gitea -X POST "$GITEA_URL/api/v1/admin/users" -d "{\"username\":\"$1\",\"email\":\"$1@cve-demo.local\",
    \"password\":\"$2\",\"must_change_password\":false,\"send_notify\":false}" -o /dev/null
}
collab() {  # direct write access: team permissions break the approval whitelist in Gitea 1.24
  local u=$1; shift
  for r in "$@"; do
    gitea -X PUT "$GITEA_URL/api/v1/repos/$GITEA_ORG/$r/collaborators/$u" -d '{"permission":"write"}' -o /dev/null
  done
}

say "users pipeline-bot and approver"
user pipeline-bot "$(openssl rand -base64 24 | tr -d '/+=')"
if ! oc get secret gitea-approver -n cve-demo-ci >/dev/null 2>&1; then
  pw=$(openssl rand -base64 12 | tr -d '/+=')
  user approver "$pw"
  gitea -X PATCH "$GITEA_URL/api/v1/admin/users/approver" -d "{\"login_name\":\"approver\",\"source_id\":0,\"password\":\"$pw\",\"must_change_password\":false}" -o /dev/null
  oc create secret generic gitea-approver -n cve-demo-ci --from-literal=username=approver --from-literal=password="$pw" >/dev/null
fi
collab pipeline-bot app gitops
collab approver gitops

if [ "$(oc get secret gitea-token -n cve-demo-ci -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)" != pipeline-bot ]; then
  say "token for pipeline-bot (secret cve-demo-ci/gitea-token)"
  # token creation needs the user's own basic auth: a fresh random password, never stored
  botpw=$(openssl rand -base64 24 | tr -d '/+=')
  gitea -X PATCH "$GITEA_URL/api/v1/admin/users/pipeline-bot" \
      -d "{\"login_name\":\"pipeline-bot\",\"source_id\":0,\"password\":\"$botpw\",\"must_change_password\":false}" -o /dev/null
  token=$(curl -sS -u "pipeline-bot:$botpw" -H 'Content-Type: application/json' -X POST "$GITEA_URL/api/v1/users/pipeline-bot/tokens" \
      -d "{\"name\":\"cve-demo-pipeline-$(date +%s)\",\"scopes\":[\"write:repository\",\"read:user\",\"read:organization\"]}" \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["sha1"])')
  oc create secret generic gitea-token -n cve-demo-ci --from-literal=username=pipeline-bot \
     --from-literal=token="$token" --dry-run=client -o yaml | oc apply -f - >/dev/null
fi
ok "Gitea ready: $GITEA_URL/$GITEA_ORG (approver password: oc get secret gitea-approver -n cve-demo-ci -o jsonpath='{.data.password}' | base64 -d)"
