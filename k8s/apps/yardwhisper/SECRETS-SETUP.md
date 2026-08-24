# Yard Whisper (lawncare-saas) homelab deployment — secret setup

This directory is the ArgoCD app for the Yard Whisper app (namespace `yardwhisper`).
It is the dev deployment that replaces the retired VPS.

## Runtime secrets (sealed, namespace `yardwhisper`)

### `yardwhisper-secrets`
| Key | Meaning | Source |
|---|---|---|
| `JWT_ISSUER` | `https://dev-jif12ytj55oxxhyn.us.auth0.com/` | Auth0 tenant |
| `JWT_AUDIENCE` | `https://api.yardwhisper.herrington.services` | Auth0 API identifier |
| `JWKS_URL` | `https://dev-jif12ytj55oxxhyn.us.auth0.com/.well-known/jwks.json` | Auth0 |
| `ADMIN_JWT_AUDIENCE` | `https://admin-api.yardwhisper.herrington.services` | Auth0 admin API identifier |
| `ADMIN_AUTH_SUBJECTS` | `auth0\|6a8a83e801fbcf19111e5a55` | Auth0 admin user_id (operator) |
| `TURNSTILE_SECRET_KEY` | `0x4AAAAAAEZfkkzScTX88Y1QAM5GpDlTQ9M` | Cloudflare Turnstile widget secret key |
| `CRON_SECRET` | random | generated (`/internal/*` auth) |
| `APP_DB_PASSWORD` | random | lawncare_app DB role password |
| `ADMIN_DB_PASSWORD` | random | lawncare_admin DB role password |
| `DATABASE_URL` | `postgresql+asyncpg://lawncare_app:<APP_DB_PASSWORD>@yardwhisper-db:5432/lawncare` | app-role DSN (literal) |
| `ADMIN_DATABASE_URL` | `postgresql+asyncpg://lawncare_admin:<ADMIN_DB_PASSWORD>@yardwhisper-db:5432/lawncare` | admin-role DSN (literal) |

> DSNs are sealed as literal strings (not `$(VAR)` expansion) because app-template
> sorts env alphabetically, which breaks k8s dependent-env ordering.

### `yardwhisper-collector-secrets`
| Key | Value |
|---|---|
| `GRAFANA_OTLP_ENDPOINT` | `https://otlp-gateway-prod-us-east-3.grafana.net/otlp` |
| `GRAFANA_OTLP_AUTH_HEADER` | `Basic base64(1727295:<vault_grafana_otlp_token>)` |

### `yardwhisper-adminer-basic-auth`
`auth` = htpasswd `admin:<random>` for `db.yardwhisper.herrington.services`.

### `yardwhisper-ghcr-pull-secret`
docker-registry secret, `ghcr.io` / `andrewthetechie` / `<vault_ghcr_pull_token>`
(classic PAT, `read:packages`).

## Re-seal (regenerate) commands

```bash
# yardwhisper-secrets — regenerate random DB passwords & DSNs
APP=$(openssl rand -base64 24); ADM=$(openssl rand -base64 24); CRON=$(openssl rand -base64 32)
kubectl create secret generic yardwhisper-secrets \
  --from-literal=JWT_ISSUER="https://dev-jif12ytj55oxxhyn.us.auth0.com/" \
  --from-literal=JWT_AUDIENCE="https://api.yardwhisper.herrington.services" \
  --from-literal=JWKS_URL="https://dev-jif12ytj55oxxhyn.us.auth0.com/.well-known/jwks.json" \
  --from-literal=ADMIN_JWT_AUDIENCE="https://admin-api.yardwhisper.herrington.services" \
  --from-literal=ADMIN_AUTH_SUBJECTS="auth0|6a8a83e801fbcf19111e5a55" \
  --from-literal=TURNSTILE_SECRET_KEY="0x4AAAAAAEZfkkzScTX88Y1QAM5GpDlTQ9M" \
  --from-literal=CRON_SECRET="$CRON" \
  --from-literal=APP_DB_PASSWORD="$APP" \
  --from-literal=ADMIN_DB_PASSWORD="$ADM" \
  --from-literal=DATABASE_URL="postgresql+asyncpg://lawncare_app:${APP}@yardwhisper-db:5432/lawncare" \
  --from-literal=ADMIN_DATABASE_URL="postgresql+asyncpg://lawncare_admin:${ADM}@yardwhisper-db:5432/lawncare" \
  -n yardwhisper --dry-run=client -o yaml | \
  kubeseal --cert ~/.kube/sealed-pub-cert.pem --format yaml > sealedsecret-yardwhisper-secrets.yaml

# collector secrets (token from lawncare-saas Ansible vault: vault_grafana_otlp_token)
AUTH="Basic $(printf '%s' "1727295:${TOKEN}" | base64)"
kubectl create secret generic yardwhisper-collector-secrets \
  --from-literal=GRAFANA_OTLP_ENDPOINT="https://otlp-gateway-prod-us-east-3.grafana.net/otlp" \
  --from-literal=GRAFANA_OTLP_AUTH_HEADER="$AUTH" \
  -n yardwhisper --dry-run=client -o yaml | \
  kubeseal --cert ~/.kube/sealed-pub-cert.pem --format yaml > sealedsecret-yardwhisper-collector-secrets.yaml

# adminer basic auth
htpasswd -nbB admin "new-password" > /tmp/yw-adminer.htpasswd
kubectl create secret generic yardwhisper-adminer-basic-auth \
  --from-file=auth=/tmp/yw-adminer.htpasswd -n yardwhisper --dry-run=client -o yaml | \
  kubeseal --cert ~/.kube/sealed-pub-cert.pem --format yaml > sealedsecret-yardwhisper-adminer-basic-auth.yaml
rm /tmp/yw-adminer.htpasswd

# ghcr pull secret (classic PAT with read:packages)
kubectl create secret docker-registry yardwhisper-ghcr-pull-secret \
  --docker-server=ghcr.io --docker-username=andrewthetechie \
  --docker-password="<CLASSIC_PAT_read:packages>" \
  -n yardwhisper --dry-run=client -o yaml | \
  kubeseal --cert ~/.kube/sealed-pub-cert.pem --format yaml > sealedsecret-yardwhisper-ghcr-pull-secret.yaml
```

Location of values: see `lawncare-saas-git/.github/workflows/deploy-homelab.yml` (tag promotion) and
`values.yaml` in this directory (deployment config). The lawncare-saas repo holds the build-time
`VITE_AUTH0_*`/`VITE_TURNSTILE_SITE_KEY`/`VITE_DEV_AUTH` secrets/vars (git repo secrets) and
`HOME_K8S_TOKEN`.
