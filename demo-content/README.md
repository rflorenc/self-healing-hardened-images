# Demo content

Copied from the `bo1122` repository, which stays the source of truth while it is not published. Keep both
copies in step; once `bo1122` is on GitHub, the Ansible layer can clone it at a pinned tag instead.

| Path | Content |
|---|---|
| `app/` | the demo app and its Containerfile, pushed to Gitea as `cve-demo/app` |
| `gitops/` | base and stage/prod overlays, pushed to Gitea as `cve-demo/gitops` |
| `pipeline/` | Tekton tasks, pipelines and trigger |
| `conforma/` | Conforma policy |
| `acs-policy-fixable.json` | the build-gate policy, to become a `SecurityPolicy` resource |
