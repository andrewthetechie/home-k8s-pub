# Firecrawl — home-k8s Deployment

## Architecture

- **Namespace**: `firecrawl`
- **Database**: PostgresOperator-managed cluster (`firecrawl-db`) with `preparedDatabases.firecrawl`
- **Schema**: `nuq` schema created by init Job from upstream `nuq.sql`
- **App deployment**: ArgoCD appset (apps/infra), not incubator

## Files

| File | Purpose |
|---|---|
| `namespace.yaml` | firecrawl namespace |
| `postgres.yaml` | PostgresOperator CR (cluster config, `preparedDatabases`, parameters) |
| `nuq-schema-cm.yaml` | ConfigMap containing upstream `nuq.sql` schema |
| `init-job.yaml` | One-time Job that runs `nuq.sql` as postgres superuser |
| `kustomization.yaml` | Kustomize entry point |

## Updating the nuq Schema

When Firecrawl releases a new version with changes to `apps/nuq-postgres/nuq.sql`:

### 1. Download the new schema

```bash
curl -sL https://raw.githubusercontent.com/firecrawl/firecrawl/main/apps/nuq-postgres/nuq.sql -o /tmp/nuq.sql
```

### 2. Diff against current schema

```bash
diff nauvoo-v2/manifests/apps/firecrawl/nuq-schema-cm.yaml <(echo "apiVersion: v1
kind: ConfigMap
metadata:
  name: firecrawl-nuq-schema
  namespace: firecrawl
data:
  nuq.sql: |" && sed 's/^/    /' /tmp/nuq.sql)
```

Or more simply, diff the raw SQL:

```bash
# Extract current SQL from ConfigMap (strip the 4-space YAML indent)
sed -n '/^    /s/^    //p' nauvoo-v2/manifests/apps/firecrawl/nuq-schema-cm.yaml > /tmp/nuq-current.sql
diff /tmp/nuq-current.sql /tmp/nuq.sql
```

Review the diff for any breaking changes, new tables/indexes, or removed objects.

### 3. Update the ConfigMap

Replace the SQL content in `nuq-schema-cm.yaml` under `data.nuq.sql:`. Preserve the 4-space YAML indentation. The `nuq.sql` file content goes verbatim — every line indented by 4 spaces.

### 4. Commit and push

ArgoCD will sync the updated ConfigMap automatically.

### 5. Re-run the init Job

The schema is fully idempotent (`IF NOT EXISTS`, `IF EXISTS`, exception handlers). Delete the old Job and create a new one:

```bash
# Delete the completed Job
kubectl delete job firecrawl-db-init -n firecrawl

# ArgoCD will recreate it, or apply manually:
kubectl apply -k nauvoo-v2/manifests/apps/firecrawl/
```

### 6. Verify

```bash
# Watch Job completion
kubectl logs -n firecrawl job/firecrawl-db-init --follow

# Verify new objects exist
kubectl port-forward svc/firecrawl-db 5432:5432 -n firecrawl &
PGPASSWORD=$(kubectl get secret firecrawl-owner-user.firecrawl-db.credentials.postgresql.acid.zalan.do -n firecrawl -o jsonpath='{.data.password}' | base64 -d) \
  psql -h localhost -p 5432 -U firecrawl_owner_user -d firecrawl -c '\dt nuq.*'

# Check pg_cron jobs
PGPASSWORD=$(kubectl get secret firecrawl-owner-user.firecrawl-db.credentials.postgresql.acid.zalan.do -n firecrawl -o jsonpath='{.data.password}' | base64 -d) \
  psql -h localhost -p 5432 -U firecrawl_owner_user -d firecrawl -c 'SELECT jobid, schedule, command FROM cron.job ORDER BY jobid;'
```

### 7. Clean up (optional)

After successful verification, you can remove `init-job.yaml` from `kustomization.yaml` and delete the Job from the cluster. Keep `nuq-schema-cm.yaml` as documentation of the current schema version.

```bash
kubectl delete job firecrawl-db-init -n firecrawl
```

## Notes

- The init Job connects as the `postgres` superuser because `nuq.sql` contains `ALTER SYSTEM SET` and `pg_cron.schedule()` calls. The PostgresOperator creates the superuser secret `postgres.firecrawl-db.credentials.postgresql.acid.zalan.do`.
- All `ALTER SYSTEM SET` parameters in `nuq.sql` are pre-configured in the PostgresOperator CR's `parameters` block, making them no-ops at runtime.
- The schema is fully idempotent — safe to re-run at any time.

## Local apply

Uses the file:// protocol which works in argocd but not locally, to apply locally

```shell

HELM_NO_PLUGINS=1 helm template firecrawl ./charts/firecrawl-helm -f values.yaml -n firecrawl | kubectl apply -f -
kubectl apply -f namespace.yaml -f postgres.yaml -f nuq-schema-cm.yaml -f ingress.yaml
kubectl apply -f patches/db-env.yaml
```
