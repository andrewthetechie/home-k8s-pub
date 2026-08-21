# WFS dev deployment — secret setup

This directory currently contains **placeholder/test sealed secrets** so the
ArgoCD app can sync. Before the deployment is actually usable you need to
replace them with real values.

## Current skeleton state

- `sealedsecret-wfs-secrets.yaml` — placeholder Auth0/HockeyTech values.
- `sealedsecret-wfs-adminer-basic-auth.yaml` — basic-auth secret for `admin.wfs.herrington.services`.
- `sealedsecret-wfs-ghcr-pull-secret.yaml` — uses the current `gh auth token`; will expire eventually.

## Required replacements

### 1) `wfs-secrets`

Keys that must be real before the app works:

| Key | How to obtain | Current placeholder |
|---|---|---|
| `AUTH0_DOMAIN` | Auth0 tenant domain, e.g. `dev-xxx.us.auth0.com` | `test.example.com` |
| `AUTH0_AUDIENCE` | Auth0 API identifier | `https://api.test` |
| `AUTH0_ISSUER` | Issuer URL, usually `https://<AUTH0_DOMAIN>/` | `https://test.example.com/` |
| `AUTH0_CLIENT_ID` | Auth0 application client ID | `test-client-id` |
| `AUTH0_ROLES_CLAIM` | Namespaced roles claim from the Auth0 Action | `https://wfs.app/roles` |
| `AUTH0_ADMIN_ROLE` | Role value that grants admin | `admin` |
| `AUTH0_BIRTHDATE_CLAIM` | Claim carrying birthdate for age gating | `birthdate` |
| `HOCKEYTECH_KEY` | Public HockeyTech API key | `test-key-placeholder` |
| `HOCKEYTECH_USER_AGENT` | Contact user-agent string | `wfs/1.0 (...)` |

Optional keys (currently empty) that you may want to fill in later:
`SMTP_HOST`, `SMTP_USER`, `SMTP_PASSWORD`, `EMAILS_FROM_EMAIL`,
`SENTRY_DSN`, `DISCORD_OPS_WEBHOOK_URL`, `OTEL_EXPORTER_OTLP_ENDPOINT`,
`OTEL_EXPORTER_OTLP_HEADERS`.

To re-seal after editing:

```bash
kubectl create secret generic wfs-secrets \
  --from-literal=AUTH0_DOMAIN="..." \
  --from-literal=AUTH0_AUDIENCE="..." \
  --from-literal=AUTH0_ISSUER="..." \
  --from-literal=AUTH0_CLIENT_ID="..." \
  --from-literal=AUTH0_ROLES_CLAIM="..." \
  --from-literal=AUTH0_ADMIN_ROLE="..." \
  --from-literal=AUTH0_BIRTHDATE_CLAIM="..." \
  --from-literal=HOCKEYTECH_KEY="..." \
  --from-literal=HOCKEYTECH_USER_AGENT="..." \
  --from-literal=SECRET_KEY="$(python -c 'import secrets; print(secrets.token_urlsafe(32))')" \
  --from-literal=SMTP_HOST="" \
  --from-literal=SMTP_USER="" \
  --from-literal=SMTP_PASSWORD="" \
  --from-literal=EMAILS_FROM_EMAIL="noreply@example.com" \
  --from-literal=SENTRY_DSN="" \
  --from-literal=DISCORD_OPS_WEBHOOK_URL="" \
  --from-literal=OTEL_EXPORTER_OTLP_ENDPOINT="" \
  --from-literal=OTEL_EXPORTER_OTLP_HEADERS="" \
  --from-literal=OTEL_SERVICE_NAME="" \
  -n wfs --dry-run=client -o yaml | \
  kubeseal --cert ~/.kube/sealed-pub-cert.pem --format yaml > \
  nauvoo-v2/manifests/apps/wfs/sealedsecret-wfs-secrets.yaml
```

### 2) `wfs-adminer-basic-auth`

Current username: `admin`
Current temporary password: `AndzHbAXD20v1BR-XxIywTQ0nVvFOS66`

To change the password:

```bash
htpasswd -nbB admin "new-password" > /tmp/wfs-adminer.htpasswd
kubectl create secret generic wfs-adminer-basic-auth \
  --from-file=auth=/tmp/wfs-adminer.htpasswd \
  -n wfs --dry-run=client -o yaml | \
  kubeseal --cert ~/.kube/sealed-pub-cert.pem --format yaml > \
  nauvoo-v2/manifests/apps/wfs/sealedsecret-wfs-adminer-basic-auth.yaml
rm /tmp/wfs-adminer.htpasswd
```

### 3) `wfs-ghcr-pull-secret`

The current sealed secret was built from the active `gh auth token`. GitHub
OAuth tokens expire, so create a dedicated **fine-grained PAT** with only
`read:packages` and seal it:

```bash
kubectl create secret docker-registry wfs-ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=andrewthetechie \
  --docker-password="<PAT>" \
  -n wfs --dry-run=client -o yaml | \
  kubeseal --cert ~/.kube/sealed-pub-cert.pem --format yaml > \
  nauvoo-v2/manifests/apps/wfs/sealedsecret-wfs-ghcr-pull-secret.yaml
```

Alternative: make the `womens-fantasy-sports` GHCR packages public in the
GitHub package settings, then delete the `imagePullSecrets` reference in
`values.yaml`.

### 4) Auth0 application configuration

Add the following to the Auth0 application allowed callback/logout/web origins:

- Allowed Callback URLs: `https://wfs.herrington.services/callback`
- Allowed Logout URLs: `https://wfs.herrington.services/`
- Allowed Web Origins: `https://wfs.herrington.services`

### 5) GitHub Actions `HOME_K8S_TOKEN`

The `deploy-homelab.yml` workflow pushes a tag-bump commit to this home-k8s
repo. Create a GitHub PAT (or GitHub App) with **contents:write** on
`andrewthetechie/home-k8s` and store it as a repository/environment secret
named `HOME_K8S_TOKEN` in the `womens-fantasy-sports` repo.
