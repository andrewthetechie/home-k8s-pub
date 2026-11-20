# UPGRADE_PLAN — litellm

**Cluster constraint:** Kubernetes **v1.28.1** (CANNOT be upgraded). Any target must be compatible with k8s 1.28.

**Deployment style:** Non-app-template helm chart via kustomize `helmChartInflationGenerator`
(`litellm-helm` from `oci://ghcr.io/berriai`), plus a Zalando Postgres cluster (`postgres.yaml`)
and sealed secrets. The bundled postgresql/redis subcharts are disabled (`redis.enabled: false`,
`db.useExisting: true` or Zalando DB).

---

## Current version (verified)

| Component | Version |
|-----------|---------|
| `litellm-helm` chart (kustomization.yaml) | **1.95.1** |
| Chart `appVersion` | 1.95.1 |
| Image `ghcr.io/berriai/litellm-database` (values.yaml `image.tag`) | **1.95.0** |
| DB | Zalando `litellm-db` StatefulSet (1/1), external to chart |

Live cluster state confirmed:
- `deployment.apps/litellm` **1/1 Running**
- `job/litellm-migrations` **1/1 Completed** (ran in 46s)
- Running image on the pod: `ghcr.io/berriai/litellm-database:1.95.0`
- App is deployed and healthy in `litellm` namespace.

---

## Target version (recommended)

| Component | Target |
|-----------|--------|
| `litellm-helm` chart | **1.97.0** (latest available) |
| Image `litellm-database` | **1.97.0** |

**Rationale / baseline:** `1.97.0` is the newest release of the `litellm-helm` chart (verified via
`helm show chart oci://ghcr.io/berriai/litellm-helm`; higher versions 1.97.1/1.98.x/2.0.0 do not exist).
Image tag `1.97.0` exists in `ghcr.io/berriai/litellm-database` (registry manifest returns HTTP 200).
The chart's own default `image.tag` is the chart `appVersion` (which is `1.97.0`), so the image and
chart stay in lockstep.

**Is the newest compatible with k8s 1.28?** Yes.
- Chart renders only standard, long-stable APIs: `Deployment`, `Service`, `Ingress` (networking.k8s.io/v1),
  `ConfigMap`, `Secret`, `Job`, `ServiceAccount`/`Role`/`RoleBinding`, optional `HPA`/`PDB`/`ServiceMonitor`/`KEDA`
  (all disabled by default). None were removed in k8s 1.29+; no CSI/CRD-only objects are required for this app.
- The bundled `postgresql`/`redis` subcharts (which carry the `bitnamilegacy` images) are **disabled** here,
  so their image additions do not matter on 1.28.
- No chart `kubeVersion` constraint requires a newer cluster.
- Nothing is skipped — 1.97.0 is both the newest overall and the recommended target.

---

## Breaking changes / migration notes (1.95.1 → 1.97.0)

I pulled both chart versions and diffed them:

1. **Service definition is unchanged.** `templates/service.yaml` is byte-identical between 1.95.1 and 1.97.0.
   The existing kustomize patch that rewrites the first port's `targetPort` to numeric `4000` (the workaround
   for NGINX named-targetPort resolution + test/migration pods carrying the app selector) **still applies unchanged**.
2. **Helm test pod names unchanged.** `litellm-test-connection` and `litellm-env-test` are still the rendered
   names (from `test-connection.yaml` / `test-env-vars.yaml`). Both existing `$patch: delete` Pod patches
   **still match** and keep removing those ArgoCD-hostile test pods.
3. **Migrations Job now references a ServiceAccount.** `templates/migrations-job.yaml` gained
   `serviceAccountName: {{ include "litellm.migrationServiceAccountName" . }}`. The chart renders this
   ServiceAccount (and any RBAC) itself as part of the release, so this is additive and handled automatically.
   ServiceAccount/Role/RoleBinding are stable APIs — safe on k8s 1.28. No action needed; the migration Job
   still runs normally and completes.
4. **`secret-dbcredentials.yaml` / `_helpers.tpl` / test-servicemonitor** changed cosmetically (helper/fullname
   updates). No impact on this deployment's values.
5. **values.yaml additions** are only `bitnamilegacy` image pins for the bundled postgresql/redis subcharts —
   both are disabled here, so irrelevant.
6. **DB migrations:** the app's Prisma migrations apply via the existing `litellm-migrations` Job against the
   Zalando DB. Going 1.95.x → 1.97.x is a minor app bump; the migration Job will apply any pending schema
   migrations on first sync. Expected to be non-breaking (same major/minor line).

No changes to the postgres endpoint, secrets, `proxy_config`, env, or ingress handling are required.

---

## Step-by-step upgrade plan (edit version pins only — no service/values restructuring)

1. In `kustomization.yaml`, change the `helmCharts` `version:` for `litellm-helm`:
   - `version: 1.95.1` → `version: 1.97.0`
2. In `values.yaml`, change the image tag:
   - `tag: "1.95.0"` → `tag: "1.97.0"`
3. (Optional, per registry layout) Refresh the vendored chart under `charts/`:
   - `helm pull oci://ghcr.io/berriai/litellm-helm --version 1.97.0` and update the local `charts/litellm-helm-*`
     copy to match the pinned version (the repo vendors the tgz).
4. Commit and let ArgoCD / `kustomize build` re-render and sync.
   - Sanity check locally: `kustomize build .` should carry the existing 3 patches through with no errors.
5. Confirm the release updates (not necessarily recreate) the `litellm` Deployment with image `1.97.0` and the
   migrations Job completes.

---

## Rollback plan

- Revert the two one-line edits: `version: 1.97.0` → `1.95.1` and `tag: "1.97.0"` → `"1.95.0"` in Git, then re-sync.
- Because the change is purely a chart/image version bump (no destructive migration, no CRD/schema rewrite beyond
  Prisma's forward migrations in the same minor line), rolling back the image tag is safe. If a DB migration
  was applied by 1.97.0, confirm it is backwards-compatible before reverting the image; Prisma forward migrations
  in this range are designed to be applied incrementally, so a same-line revert is low risk.

---

## Post-upgrade verification

- `kubectl -n litellm get deploy litellm` → Ready `1/1`.
- `kubectl -n litellm get pod` → no lingering `litellm-test-connection` / `litellm-env-test` pods (patches hold).
- `kubectl -n litellm get job litellm-migrations` → `1/1 Completed` (no CrashLoop).
- `kubectl -n litellm get deploy litellm -o jsonpath='{.spec.template.spec.containers[*].image}'`
  → `ghcr.io/berriai/litellm-database:1.97.0`.
- Service endpoint resolves: confirm Live/Ready probe passes and ingress `litellm.herrington.services`
  returns 200 (not the old 502), verifying the numeric `targetPort: 4000` patch still resolves.
- Smoke test: log into the Admin UI (models/keys in DB as before) and issue a test model call.
