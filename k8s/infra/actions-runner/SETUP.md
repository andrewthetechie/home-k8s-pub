# GitHub Actions Runner (ARC) — Manual Setup Steps

This directory uses the [Actions Runner Controller](https://github.com/actions/actions-runner-controller)
AutoscalingRunnerSet architecture to run self-hosted runners for `andrewthetechie/lawncare-saas`.
Runners scale to zero when idle and up to 2 when jobs are queued.

ArgoCD will auto-sync this app but the runners will not authenticate until you complete the steps below.

---

## Step 1 — Check chart versions

Both `arc-controller` and `actions-runner` must use the **same** chart version.

Find the latest release at: https://github.com/actions/actions-runner-controller/releases

Update the `version:` field in both:
- `nauvoo-v2/manifests/infra/arc-controller/kustomization.yaml`
- `nauvoo-v2/manifests/infra/actions-runner/kustomization.yaml`

---

## Step 2 — Create a GitHub App

1. Go to https://github.com/settings/apps/new (personal account GitHub App)
2. Fill in:
   - **GitHub App name**: `home-k8s-arc-runner` (or any name you like)
   - **Homepage URL**: `https://github.com/andrewthetechie`
   - **Webhooks**: uncheck "Active"
3. Under **Repository permissions**, set:
   - **Actions**: Read & write
   - **Administration**: Read & write (required to register runners — without this you get a 403 `Resource not accessible by integration`)
   - **Metadata**: Read-only (required, set automatically)
4. Under **Where can this GitHub App be installed?**: select **Only on this account**
5. Click **Create GitHub App**
6. Note the **App ID** shown at the top of the app's settings page.
7. Scroll to **Private keys** → click **Generate a private key** → save the downloaded `.pem` file.

---

## Step 3 — Install the App on lawncare-saas

1. On the GitHub App settings page, click **Install App** in the left sidebar.
2. Click **Install** next to your account.
3. Choose **Only select repositories** → select `andrewthetechie/lawncare-saas`.
4. Click **Install**.
5. After installing, look at the URL in your browser. It will look like:
   `https://github.com/settings/installations/12345678`
   The number at the end is your **Installation ID**. Note it.

---

## Step 4 — Create and seal the Kubernetes secret

Make sure `kubectl` is pointing at your cluster and `kubeseal` is available.

```bash
# Replace the placeholder values with your real App ID, Installation ID, and path to the .pem file
APP_ID=YOUR_APP_ID
INSTALLATION_ID=YOUR_INSTALLATION_ID
PRIVATE_KEY_FILE=~/Downloads/home-k8s-arc-runner.2024-01-01.private-key.pem

kubectl create secret generic arc-github-app \
  --namespace arc-runners \
  --from-literal=github_app_id="${APP_ID}" \
  --from-literal=github_app_installation_id="${INSTALLATION_ID}" \
  --from-file=github_app_private_key="${PRIVATE_KEY_FILE}" \
  --dry-run=client -o yaml | \
kubeseal --format yaml \
  > nauvoo-v2/manifests/infra/actions-runner/sealed-arc-github-app.yaml
```

---

## Step 5 — Wire the sealed secret into kustomization.yaml

Open `nauvoo-v2/manifests/infra/actions-runner/kustomization.yaml` and uncomment this line:

```yaml
  - sealed-arc-github-app.yaml
```

---

## Step 6 — Commit and push

```bash
git add nauvoo-v2/manifests/infra/actions-runner/sealed-arc-github-app.yaml \
        nauvoo-v2/manifests/infra/actions-runner/kustomization.yaml
git commit -m "feat(actions-runner): add GitHub App sealed secret"
git push
```

ArgoCD will sync `arc-controller` (wave 0) then `actions-runner` (wave 1). Once both are healthy,
runners will appear under **Settings → Actions → Runners** for `andrewthetechie/lawncare-saas`.

---

## Step 7 — Use the runners in lawncare-saas workflows

```yaml
# .github/workflows/example.yml
jobs:
  build:
    runs-on: lawncare-saas   # matches runnerScaleSetName in values.yaml
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running on self-hosted ARC runner"
```

---

## Troubleshooting

**Runners not appearing in GitHub:**
```bash
kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller
kubectl logs -n arc-runners -l app.kubernetes.io/name=arc-lawncare-saas
```

**Secret not found:**
```bash
kubectl get secret arc-github-app -n arc-runners
```

**Controller service account name mismatch** (if runners fail to start):
```bash
kubectl get sa -n arc-systems
# Use the actual SA name in values.yaml → controllerServiceAccount.name
```
