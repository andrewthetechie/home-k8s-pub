# Wiping the registry caches

All four registries in `registry-cache` are disposable caches:

| Registry | Role | Wipe cost |
| --- | --- | --- |
| `registry-dockerhub` | pull-through proxy for docker.io | next pulls re-fetch from upstream |
| `registry-ghcr` | pull-through proxy for ghcr.io | next pulls re-fetch from upstream |
| `registry-mcr` | pull-through proxy for mcr.microsoft.com | next pulls re-fetch from upstream |
| `registry-local` | buildx `cache-to`/`cache-from` target for CI images | next CI build runs with a cold layer cache |

A weekly CronJob (`registry-<name>-wipe`, Sunday mornings, staggered) wipes
each one. This runbook is for wiping **now**, by hand.

## When to wipe

Symptoms of a poisoned cache (left behind by the old nightly GC, which raced
the live registry and deleted blob files the registry still referenced):

- buildkit/containerd fails with `short read: expected N bytes but got 0: unexpected EOF`
- the registry logs show `GET /v2/.../blobs/sha256:...` returning `200` with `0` bytes in a few ms
- the registry sends `Content-Length: N` then closes the connection with an empty body

The poison is both on disk (missing blob `data` files with live repository
links) and in memory (the registry's blob descriptor cache). A wipe plus a
registry restart clears both.

## Option A — quick fix: restart only (try this first)

If the on-disk links are stale but the blobs exist upstream (always true for
the three pull-through proxies), a restart alone usually heals the registry:
the in-memory descriptor cache is cleared, and the proxy falls back to
upstream on a local miss, re-caching as it goes.

```bash
kubectl -n registry-cache rollout restart deploy/registry-dockerhub deploy/registry-ghcr deploy/registry-mcr deploy/registry-local
kubectl -n registry-cache rollout status deploy/registry-dockerhub
kubectl -n registry-cache rollout status deploy/registry-ghcr
kubectl -n registry-cache rollout status deploy/registry-mcr
kubectl -n registry-cache rollout status deploy/registry-local
```

If the same `short read` errors come back, do a full wipe (Option B or C).

## Option B — full wipe via the CronJobs (after the wipe manifests are synced)

Once ArgoCD has synced the `registry-*-wipe` CronJobs from this directory:

```bash
cd nauvoo-v2/manifests/infra/registry-cache  # anywhere works; nothing here is path-dependent

for R in dockerhub ghcr mcr local; do
  kubectl -n registry-cache create job \
    --from=cronjob/registry-${R}-wipe \
    registry-${R}-wipe-manual-$(date +%s)
done

# watch progress (each job wipes, restarts the registry, waits for rollout)
kubectl -n registry-cache get jobs -w
```

Each orchestrator job takes 1–3 minutes. Check its logs if it fails:

```bash
kubectl -n registry-cache logs -l job-name=registry-dockerhub-wipe-manual-...
```

## Option C — full wipe by hand (works any time, no CronJob needed)

Use this before the wipe CronJobs exist, or if they're broken. It does exactly
what the CronJob does: same-node executor pod mounts the RWO PVC (podAffinity
— do NOT scale the Deployment to zero; ArgoCD selfHeal races the scale-down),
deletes the data tree, then restarts the registry.

```bash
NS=registry-cache
for R in registry-dockerhub registry-ghcr registry-mcr registry-local; do
  kubectl -n $NS delete job $R-wipe-manual --ignore-not-found --wait=false
  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $R-wipe-manual
  namespace: $NS
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      affinity:
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels: { app: $R }
              topologyKey: kubernetes.io/hostname
              namespaces: [$NS]
      containers:
        - name: wipe
          image: busybox:1.36
          command: ["/bin/sh", "-c"]
          args:
            - >
              rm -rf /var/lib/registry/docker &&
              mkdir -p /var/lib/registry/docker/registry/v2/repositories
              /var/lib/registry/docker/registry/v2/blobs
          volumeMounts:
            - name: data
              mountPath: /var/lib/registry
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: $R
EOF
  kubectl -n $NS wait --for=condition=complete job/$R-wipe-manual --timeout=600s
  kubectl -n $NS rollout restart deploy/$R
  kubectl -n $NS rollout status deploy/$R --timeout=300s
  kubectl -n $NS delete job $R-wipe-manual --wait=false
done
```

(`PodSecurity "restricted"` warnings on job creation are expected and
non-blocking — the namespace only warns.)

## Verify

```bash
# proxy caches should serve real bytes for a known manifest
kubectl run wipe-verify --rm -i --restart=Never --namespace=registry-cache \
  --image=busybox:1.36 --timeout=60s -- sh -c '
    wget -q -O /tmp/m --header="Accept: application/vnd.oci.image.index.v1+json" \
      http://registry-dockerhub.registry-cache.svc.cluster.local:5000/v2/library/python/manifests/3.14 \
    && wc -c /tmp/m'
```

Then re-run the failed GitHub Actions workflow. Expect the first build to be
slower (cold caches); subsequent builds are cached again.

## What NOT to do

- **Don't** run `registry garbage-collect` against a live registry — that is
  what caused the poisoning this runbook exists to fix.
- **Don't** `kubectl scale --replicas=0` the registry Deployments as a wipe
  strategy — ArgoCD selfHeal reverts the scale within minutes and can race the
  executor's volume attach.
