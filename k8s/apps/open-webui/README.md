# Open WebUI

Chat frontend for the homelab's LLM endpoints, deployed via the [official
Open WebUI Helm chart](https://github.com/open-webui/helm-charts).

Namespace: `open-webui`
Ingress: `https://open-webui.herrington.services`

## Connected models (OpenAI-compatible)

Four connections are configured (chart `openaiBaseApiUrls`, keys from the
`open-webui-secrets` SealedSecret in the same order):

1. **spark** — `http://10.10.0.30:8888/v1`, key `local` (llama-server ignores it).
   Primary model: `deepseek-v4-flash-0731` (also set via `DEFAULT_MODELS`).
2. **opencode-go** — `https://opencode.ai/zen/go/v1`.
3. **kimi** — `https://api.kimi.com/coding/v1`.
4. **freellm** — `https://freellm.herrington.services/v1` (custom OpenAI API).

The `WEBUI_SECRET_KEY` and the API keys live in
`sealed-open-webui-secrets.yaml` (re-seal with
`kubeseal --cert ~/.kube/sealed-pub-cert.pem` if they ever need to change).

## First-run setup (manual, one-time)

1. Browse to the ingress URL and create the first user — this becomes the
   **admin** account.
2. Best-effort charity: model dropdown should already show
   `deepseek-v4-flash-0731` as the default plus the opencode-go and kimi
   models.

## Home Assistant MCP (manual, one-time — env var does NOT work)

> Why not via env: `TOOL_SERVER_CONNECTIONS` only registers OpenAPI/MCPO
> tool servers (`open_webui/utils/tools.py:get_tool_servers_data` filters to
> `type == 'openapi'`). Native streamable-HTTP MCP servers are stored in the
> DB and must be added in the UI. The deployed `type: mcp` entry was parsed by
> the schema but ignored at runtime ("Initialized 0 tool server(s)").

To connect Home Assistant (served by the existing `ha-mcp` deployment):

1. Admin Settings → External Tools.
2. **+ Add Server**.
3. Type: **MCP (Streamable HTTP)**.
4. Server URL: `http://ha-mcp.ha-mcp.svc.cluster.local:8086/mcp`
   (no auth needed — ha-mcp holds the Home Assistant token server-side).
5. Save; tools appear per-chat under the Tools picker. This persists in the
   sqlite DB on the PVC, so it survives restarts.

## Other useful MCP thoughts

- **GitHub** (remote, `https://api.githubcopilot.com/mcp/`, OAuth) — issues/PRs/repos.
- **Context7** (`https://mcp.context7.com/mcp`) — up-to-date library docs.
- **Kubernetes MCP** (`containers/kubernetes-mcp-server`, HTTP mode) — cluster query/diagnostics (scope read-only).
- **Argo CD MCP** — app sync status/history.
- stdio-only MCP servers need an in-cluster `mcpo` proxy to expose them as HTTP.

## Updating

- The chart version is pinned in `kustomization.yaml`; the image tag in
  `values.yaml`. Follow the normal ArgoCD `apps` ApplicationSet flow — add a
  new `apps/open-webui` dir change and push to master.
