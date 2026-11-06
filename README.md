# self-healing-hardened-images

RHDP catalog item for the BO1122 demo, Red Hat One 2027.

The catalog layer for the BO1122 demo, "self-healing images on OpenShift". It turns the demo into a
Field Sourced Content deployment on Red Hat Demo Platform: the catalog's Argo CD deploys this chart on a
fresh OpenShift 4.20 cluster, AWS variant, multi-node. The demo itself, its app, GitOps content, Tekton
pipeline and Conforma policy, lives in the `bo1122` repository and stays unchanged.

References: catalog template github.com/rhpds/field-sourced-content-template; bootstrap role
`ocp4_workload_field_content` in github.com/rhpds/core_workloads.

## Ordering
Field Sourced Content - OpenShift Base: Existing GitOps repo `https://github.com/rflorenc/self-healing-hardened-images.git`,
revision `main`, GitOps path `.`; multi-node, no base workloads.

## How the catalog starts it
The catalog creates one Argo CD Application, `field-content`, in `openshift-gitops`, pointing at this
repository and its chart path. It syncs automatically with self-heal and prune off, does not wait for the
sync, and injects these Helm values:

| Value | Use here |
|---|---|
| `deployer.domain`, `deployer.apiUrl` | routes, Keycloak hostname, issuer URLs |
| `gitops.repoURL`, `gitops.revision`, `gitops.path` | child Applications point back at this repository |
| `litemaas.*` | unused; kept for the future AI briefing |
| `multi_user.*` | unused |

## Design
Two layers in one chart:

1. **Declarative components**, child Argo CD Applications with sync waves and self-heal:
   operator subscriptions, NooBaa, Quay, ACS Central and secured cluster, ACS policies as
   `SecurityPolicy` resources, Keycloak, Trusted Artifact Signer, Trusted Profile Analyzer, Gitea, and
   the demo layer: namespaces, Argo CD applications for stage and prod, Tekton tasks and pipelines,
   the Conforma policy.
2. **Configuration by Ansible**, an Ansible Runner Job in the last wave, for everything that has to call
   an API or needs the cluster's current state: detecting existing operators, the Quay first user and
   robots, ACS token and integrations, Keycloak realms and clients, Gitea users, repositories, branch
   protection and webhooks, Tekton Chains keyless settings, the TPA importer, the baseline build, and
   the user information page.

Rules:
- Generated values, passwords, tokens and client secrets, are created by Ansible and kept in Secrets,
  never by Helm: random values in Helm change on every render and fight Argo CD.
- Helm `lookup` does not work under Argo CD, which renders charts without cluster access. Existing
  operators, such as the catalog's RHBK operator, are detected in Ansible before anything is installed.
- One Argo CD instance: the catalog's `openshift-gitops`. The Ansible layer can create a dedicated
  instance on clusters without one, such as a customer's.
- Keycloak is our own, with our realms, so the item also works where no Keycloak exists. Before
  subscribing, Ansible checks for an existing rhbk-operator subscription to avoid OperatorGroup conflicts.
- The ordering user sees URLs and logins through a `demo.redhat.com/userinfo` ConfigMap; passwords stay
  in Secrets and the page shows the `oc` command that reads them.

## Proposed layout
```
Chart.yaml, values.yaml        App of Apps entry point, the catalog's GitOps path is the repository root
templates/applications.yaml    one child Application per enabled component, with sync waves
components/
  operators/                   subscriptions and OperatorGroups, pinned channels
  storage/                     NooBaa, standalone Multicloud Object Gateway, lean
  acs/                         Central, SecuredCluster, SecurityPolicy resources, demo-sized
  quay/                        QuayRegistry, demo-sized
  keycloak/                    PostgreSQL and Keycloak
  tas/                         Securesign
  tpa/                         PostgreSQL, bucket claim, TrustedProfileAnalyzer
  gitea/                       Gitea
  demo/                        namespaces, Argo CD applications, Tekton resources, Conforma policy
  configure/                   the Ansible Runner Job, its RBAC and configuration
ansible/                       site.yml and one role per product
demo-content/                  app, GitOps content, pipeline and Conforma policy, copied from bo1122
catalog/bo1122.yaml            catalog stub for the Field Sourced Content listing
```

## Open points
- Demo content: copied from `bo1122` into `demo-content/` for now; once `bo1122` is published, the
  Ansible layer can clone it at a pinned tag instead.
- Ordering: about 60 minutes for the AWS cluster plus about 60 minutes for this chart, most of it the ACS
  vulnerability load. Proposed workers: 3 x m6a.2xlarge.
