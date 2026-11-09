#!/usr/bin/env bash
# conforma-probe.sh [image]: show the policy input Conforma sees for an image
cd "$(dirname "$0")/.." && . lib/env.sh
img=${1:-$(oc get deploy app -n cve-demo-prod -o jsonpath='{.spec.template.spec.containers[0].image}')}
KC_HOST="keycloak-$KC_NS.$DOMAIN"
EC=registry.redhat.io/rhtas/ec-rhel9@sha256:7953bf26248b4abf0a70b10750f7634e3800cd226597521e1e5ae3b67226a261
cat <<EOF | oc apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: conforma-probe, namespace: cve-demo-ci}
spec:
  restartPolicy: Never
  containers:
    - name: ec
      image: $EC
      env:
        - {name: HOME, value: /tmp}
        - {name: DOCKER_CONFIG, value: /docker}
      command: [sh, -c]
      args:
        - |
          set -e
          curl -sf http://tuf.$TAS_NS.svc/1.root.json -o /tmp/root.json
          ec sigstore initialize --mirror http://tuf.$TAS_NS.svc --root /tmp/root.json >/dev/null
          ec validate image --image "$img" --policy '{"sources":[]}' \\
            --certificate-identity chains@cve-demo.local --certificate-oidc-issuer https://$KC_HOST/realms/tas-chains \\
            --rekor-url http://rekor-server.$TAS_NS.svc --output text --output policy-input=/tmp/input.json || true
          echo "=== POLICY INPUT"; cat /tmp/input.json
      volumeMounts: [{name: docker, mountPath: /docker}]
  volumes:
    - name: docker
      secret: {secretName: quay-robot-pipeline, items: [{key: .dockerconfigjson, path: config.json}]}
EOF
for _ in $(seq 1 30); do
  ph=$(oc get pod conforma-probe -n cve-demo-ci -o jsonpath='{.status.phase}')
  [ "$ph" = Succeeded ] || [ "$ph" = Failed ] && break; sleep 4
done
oc logs conforma-probe -n cve-demo-ci
oc delete pod conforma-probe -n cve-demo-ci --wait=false >/dev/null
