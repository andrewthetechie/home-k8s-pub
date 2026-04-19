# Home Assistant (hass) — agent notes

You have access to my home assistant deployment via **kubectl** in the **`hass`** namespace.

You have access to my home assistant via the **Home Assistant MCP** that is installed.

## Repo layout (this app)

- **Kubernetes manifests:** `nauvoo-v2/manifests/apps/hass/` (Kustomize `namespace: hass`).
- **HA YAML:** `config/*.yaml` (e.g. `configuration.yaml`, `recorder.yaml`, automations). Kustomize merges these into the **`hass-configs`** ConfigMap (`configMapGenerator` in `kustomization.yaml`).
- **Database:** Zalando Postgres CR `postgres.yaml` → cluster **`hass-db`**, PVC **`pgdata-hass-db-0`**. Recorder uses PostgreSQL (`recorder.yaml` + secrets), not the default SQLite.

## Common kubectl targets

| Resource | Name |
|----------|------|
| Deployment | `deployment/hass-home-assistant` |
| Postgres (Spilo/Patroni) | `pod/hass-db-0` (container `postgres`) |
| Config ConfigMap | `configmap/hass-configs` |
| DB PVC | `persistentvolumeclaim/pgdata-hass-db-0` |

Useful commands:

```bash
kubectl get pods,pvc -n hass
kubectl logs -n hass deployment/hass-home-assistant --tail=100
kubectl logs -n hass hass-db-0 -c postgres --tail=80
```

DB credentials are in namespace secrets matching `*.credentials.postgresql.acid.zalan.do` (Zalando operator). Connect with `psql` via `kubectl exec` into `hass-db-0` using the **postgres** user secret when you need superuser access.

## When debugging recorder / disk

- **Full PVC:** PostgreSQL may fail to start (`postmaster.pid` / “no space left on device”). Check `df -h /home/postgres/pgdata` inside `hass-db-0`.
- **HA config:** `recorder.yaml` controls retention (`purge_keep_days`), excludes, and **`commit_interval`** (must not be `0` for sane write batching).
- After changing YAML in git, ensure the cluster picks up the new **`hass-configs`** (your GitOps / apply path).

## MCP

Prefer **`ha_*` tools** (search entities, get state, read automation config, call services) for live Home Assistant behavior. Use **kubectl** for cluster state, logs, PVC size, and Postgres maintenance.
