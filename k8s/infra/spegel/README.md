# spegel

Image caching

Uses an OCI helm chart. Dumped to yamls with

helm template --namespace spegel --version 0.7.4 \
  --values values.yaml \
  spegel oci://ghcr.io/spegel-org/helm-charts/spegel > spegel.yaml

> The chart's post-delete cleanup hooks (`spegel-cleanup` / `spegel-cleanup-wait`)
> are stripped from `spegel.yaml` (they would otherwise be applied as regular
> resources and break ArgoCD pruning). Remove the section starting at
> `# Source: spegel/templates/post-delete-hook.yaml` after rendering.
