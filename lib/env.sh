# Shared settings for the demo scripts; source it
# shellcheck shell=bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$REPO_ROOT/lib/demo.sh"
load_env

ACS_NS=${ACS_NS:-stackrox}
ACS_CLUSTER=${ACS_CLUSTER:-demo-cluster}
GITEA_NS=${GITEA_NS:-gitea}
GITEA_ORG=cve-demo
QUAY_NS=${QUAY_NS:-quay}
QUAY_ORG=cve-demo
TAS_NS=${TAS_NS:-trusted-artifact-signer}
KC_NS=${KC_NS:-demo-keycloak}
TPA_NS=trusted-profile-analyzer   # the operator watches only its own namespace
BASE_REPO=${BASE_REPO:-registry.access.redhat.com/hi/python}
BASE_STREAM=${BASE_STREAM:-3.11}
BASELINE_DIGEST=${BASELINE_DIGEST:-sha256:7a5952bcecbf15995fd6ef6605e8cf9f9f82949a09b0142db768b64d6f610a0d}
# in-cluster traffic uses the Gitea service, the route is for laptops
GITEA_INTERNAL_URL="http://gitea.${GITEA_NS}.svc:3000"

_q() { oc "$@" 2>/dev/null || true; }
DOMAIN=$(_q get ingresses.config cluster -o jsonpath='{.spec.domain}')
GITEA_URL="https://$(_q get route gitea -n "$GITEA_NS" -o jsonpath='{.spec.host}')"
GITEA_USER=$(_q get gitea gitea -n "$GITEA_NS" -o jsonpath='{.spec.giteaAdminUser}')
# shellcheck disable=SC2034  # used by the scripts that source this file
GITEA_PASS=$(_q get secret gitea-admin-password -n "$GITEA_NS" -o jsonpath='{.data.adminPassword}' | base64 -d)
# the Gitea operator 2.1 keeps the admin password in the CR status, not in a secret
[ -n "$GITEA_PASS" ] || GITEA_PASS=$(_q get gitea gitea -n "$GITEA_NS" -o jsonpath='{.status.adminPassword}')
QUAY_HOST=$(_q get quayregistry registry -n "$QUAY_NS" -o jsonpath='{.status.registryEndpoint}' | sed 's#^https://##')
APP_IMAGE="${QUAY_HOST:-quay-not-installed}/${QUAY_ORG}/app"
ACS_URL="https://$(_q get route central -n "$ACS_NS" -o jsonpath='{.spec.host}')"
# shellcheck disable=SC2034  # used by the scripts that source this file
ACS_PASS=$(_q get secret central-admin-password -n "$ACS_NS" -o jsonpath='{.data.password}' | base64 -d)
export ACS_NS ACS_CLUSTER GITEA_NS GITEA_ORG QUAY_NS QUAY_ORG QUAY_HOST TAS_NS KC_NS TPA_NS BASE_REPO BASE_STREAM BASELINE_DIGEST \
       APP_IMAGE GITEA_INTERNAL_URL DOMAIN GITEA_URL GITEA_USER ACS_URL
