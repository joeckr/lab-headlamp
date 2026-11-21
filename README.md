# lab-headlamp

Helm chart and local lab environment for deploying [Headlamp](https://headlamp.dev/) (Kubernetes Web UI) into a homelab Kubernetes cluster with:

- **Restricted Pod Security Standards (PSS)** compliance (`runAsNonRoot`, `readOnlyRootFilesystem`, `RuntimeDefault` seccomp, `ALL` capabilities dropped)
- **Traefik Kubernetes Gateway API** (`HTTPRoute`) fronted by a **Cloudflare Tunnel** at `https://headlamp.joeckr.dev`
- **Longhorn** persistent storage (`PersistentVolumeClaim`) for Headlamp plugins
- **Zitadel OIDC** authentication with zero secrets committed to git (supplied at `helm install` time or via an existing Kubernetes `Secret`)

---

## Architecture

```text
Browser (https://headlamp.joeckr.dev)
  │
  ▼
Cloudflare Edge / Cloudflare Tunnel (cloudflared)
  │
  ▼
Traefik Kubernetes Gateway (gateway/traefik-gateway)
  │  HTTPRoute (gateway.networking.k8s.io/v1)
  ▼
Headlamp Service (ClusterIP :80 -> :4466)
  │
  ├──▶ Zitadel OIDC (https://<your-zitadel>/oidc-callback auth flow)
  ├──▶ Kubernetes API Server (in-cluster, user OIDC Bearer token)
  └──▶ Longhorn PVC (/headlamp/plugins)
```

---

## Directory Structure

```text
.
├── .github/workflows/
│   ├── lint.yml                 # Lints workflows, commits, and shell scripts
│   ├── security.yml             # Secret scanning (betterleaks) and workflow audits (zizmor)
│   ├── release.yml              # Semantic release and OCI Helm chart publishing to GHCR
│   └── test_release.yml         # PR dry-run test for releases and chart packaging
├── chart/
│   ├── Chart.yaml               # Helm chart metadata
│   ├── values.yaml              # Default configuration values (secret-free)
│   ├── .helmignore              # Ignore rules for chart packaging
│   └── templates/
│       ├── _helpers.tpl         # Shared template helpers
│       ├── deployment.yaml      # Hardened Headlamp Deployment
│       ├── httproute.yaml       # Gateway API HTTPRoute for Traefik
│       ├── pvc.yaml             # Longhorn PersistentVolumeClaim for plugins
│       ├── rbac.yaml            # Optional ClusterRoleBindings for SA / OIDC subjects
│       ├── secret.yaml          # OIDC credentials Secret (populated at install time)
│       ├── service.yaml         # ClusterIP Service (:80 -> :4466)
│       └── serviceaccount.yaml  # Dedicated ServiceAccount
├── compose.yml                  # Local container testing via Podman Compose
├── hk.pkl                       # Git hooks and linting checks
├── mise.toml                    # Tool versions and task runner
└── README.md
```

---

## Security & Restricted PSS Compliance

This chart is hardened to run out of the box in namespaces enforcing the Kubernetes **Pod Security Admission (PSA)** `restricted` profile:

| Security Dimension | Restricted PSS Requirement | Implementation in This Chart |
|---|---|---|
| **Non-Root Execution** | `runAsNonRoot: true`, UID > 0 | `runAsNonRoot: true`, `runAsUser: 100`, `runAsGroup: 101`, `fsGroup: 101` |
| **Capabilities** | Must drop `ALL` capabilities | `capabilities.drop: ["ALL"]` |
| **Privilege Escalation** | `allowPrivilegeEscalation: false` | Enforced on the Headlamp container |
| **Read-Only Root FS** | Immutable container filesystem | `readOnlyRootFilesystem: true` with `emptyDir` mounts at `/tmp` and `/home/headlamp/.config` |
| **Seccomp Profile** | `RuntimeDefault` or `Localhost` | `seccompProfile: { type: RuntimeDefault }` |
| **Unprivileged Port** | Container port > 1024 | Listens on TCP port `4466` |
| **Least-Privilege RBAC** | No default cluster-admin on pod SA | `rbac.serviceAccountBinding.create: false` by default; API calls use the logged-in user's OIDC token |
| **Secret Hygiene** | No secrets in Git | OIDC credentials injected from Kubernetes `Secret` via env vars (`HEADLAMP_CONFIG_OIDC_*`) |

> [!NOTE]
> `serviceAccount.automountServiceAccountToken` is `true` because Headlamp's `-in-cluster` mode reads the cluster CA certificate and API server endpoint from `/var/run/secrets/kubernetes.io/serviceaccount`. Because no `ClusterRoleBinding` is attached to the ServiceAccount by default, the pod itself has no cluster privileges — Kubernetes API authorization is evaluated per-user via Zitadel OIDC tokens.

---

## Prerequisites

### 1. Restricted Namespace

Ensure the target namespace enforces the `restricted` Pod Security Standard:

```sh
kubectl create namespace headlamp
kubectl label namespace headlamp \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest
```

### 2. Zitadel OIDC Application & Action

In your **Zitadel Console** (`https://zitadel.joeckr.dev`), inside your main Organization:

1. **Create a Project** (e.g., `Kubernetes` / `Infrastructure`):
   - Under **General** (project settings), enable **Assert Roles on Authentication** (required so Zitadel loads project grants during login).
   - Under **Roles**, define your Kubernetes RBAC roles (e.g., `headlamp-view`, `headlamp-edit`, `headlamp-admin`).
   - Under **Role Assignments**, assign the appropriate role(s) to your user(s).
2. **Create a `groupsClaim` Action** (flattens Zitadel's nested `urn:zitadel:iam:org:project:roles` map into a standard `groups` array for `kube-apiserver`):
   - Go to **Actions** → **Scripts** → **+ New**, name it `groupsClaim`:
     ```javascript
     function groupsClaim(ctx, api) {
       if (ctx.v1.user.grants === undefined || ctx.v1.user.grants.count == 0) {
         return;
       }
       let grants = [];
       ctx.v1.user.grants.grants.forEach(claim => {
         claim.roles.forEach(role => {
           grants.push(role);
         });
       });
       api.v1.claims.setClaim('groups', grants);
     }
     ```
   - Switch **Flow Type** to **Complement Token**, and attach `groupsClaim` to **Pre Userinfo creation** and **Pre access token creation**.
3. **Create the Headlamp Application** inside that Project:
   - **Application Type**: `Web`
   - **Authentication Method**: `PKCE` (no client secret needed; matches `oidc.usePKCE: true`), or `Basic`/`POST` if you prefer a client secret.
   - **Redirect URI**: `https://headlamp.joeckr.dev/oidc-callback`
   - **Post Logout Redirect URI**: `https://headlamp.joeckr.dev`
   - **Token Settings**: enable **User Info inside ID Token** and **User roles inside ID Token**.
4. **Kubernetes API Server Structured Authentication (`KubeAuthenticationConfig`)**:
   - Configure your Talos control plane (`KubeAuthenticationConfig`) to trust your Zitadel issuer and map `sub` + `groups` with the `oidc:` prefix (preserving anonymous health probes):
     ```yaml
     apiVersion: v1alpha1
     kind: KubeAuthenticationConfig
     configuration:
       anonymous:
         enabled: true
         conditions:
           - path: /livez
           - path: /readyz
           - path: /healthz
       jwt:
         - issuer:
             url: https://<your-zitadel-domain>
             audiences:
               - "<ZITADEL_CLIENT_ID>"
           claimMappings:
             username:
               claim: sub
               prefix: "oidc:"
             groups:
               claim: groups
               prefix: "oidc:"
     ```

### 3. Traefik Gateway & Cloudflare Tunnel

1. **Traefik Gateway**: Confirm your Traefik `Gateway` resource exists (default: `traefik-gateway` in namespace `gateway`, listener `web`) and its listener `allowedRoutes.namespaces.from` permits routes from the `headlamp` namespace (`All` or matching `Selector`).
2. **Cloudflare Tunnel**: Add a public hostname route in your Cloudflare Tunnel pointing `headlamp.joeckr.dev` to your Traefik Gateway service.
3. **Cloudflare WAF / Bot Protection**: Headlamp and `kube-apiserver` make server-to-server HTTPS calls to Zitadel (`/oauth/v2/token`, `/oauth/v2/keys`, `/.well-known/openid-configuration`). In Cloudflare for your Zitadel hostname, add a **Custom Skip Rule** for `starts_with(http.request.uri.path, "/oauth/v2/") or starts_with(http.request.uri.path, "/.well-known/")` (and disable free-tier **Bot Fight Mode** under **Security → Settings** if it challenges backend requests).
4. Because `oidc.callbackURL` is explicitly set to `https://headlamp.joeckr.dev/oidc-callback`, Headlamp will always send the HTTPS callback URI to Zitadel even when TLS is terminated at Cloudflare/Traefik.

### 4. Longhorn StorageClass

Ensure the `longhorn` `StorageClass` is installed (or override `persistence.storageClassName`). Because Longhorn `ReadWriteOnce` volumes cannot attach to two pods simultaneously, the `Deployment` automatically uses `strategy.type: Recreate` when `persistence.enabled: true`.

---

## Installing with Helm (Without Committing Secrets)

Never commit Zitadel OIDC credentials to this repository. Choose one of the three patterns below at install time:

### Option A: Pass Secrets via `--set` Flags

```sh
helm upgrade --install lab-headlamp chart/ \
  --namespace headlamp \
  --create-namespace \
  --set oidc.issuerURL="https://auth.joeckr.dev" \
  --set oidc.clientID="<ZITADEL_CLIENT_ID>" \
  --set oidc.clientSecret="<ZITADEL_CLIENT_SECRET>"
```

*(Omit `--set oidc.clientSecret=...` if using a PKCE public client in Zitadel.)*

### Option B: Use an Untracked `values.local.yaml`

`values.local.yaml` is listed in `.gitignore`. Create it locally:

```yaml
oidc:
  issuerURL: "https://auth.joeckr.dev"
  clientID: "<ZITADEL_CLIENT_ID>"
  clientSecret: "<ZITADEL_CLIENT_SECRET>"

# Optional: grant a Zitadel OIDC group cluster-admin access
rbac:
  oidcBindings:
    - name: headlamp-oidc-admins
      clusterRoleName: cluster-admin
      subjects:
        - kind: Group
          name: "oidc:k8s-admins"
```

Then install:

```sh
helm upgrade --install lab-headlamp chart/ \
  --namespace headlamp \
  --create-namespace \
  -f values.local.yaml
```

### Option C: Use a Pre-Existing Kubernetes Secret

Create the secret out-of-band (or via External Secrets Operator / SOPS):

```sh
kubectl -n headlamp create secret generic headlamp-oidc \
  --from-literal=clientID="<ZITADEL_CLIENT_ID>" \
  --from-literal=clientSecret="<ZITADEL_CLIENT_SECRET>"
```

Then install referencing it:

```sh
helm upgrade --install lab-headlamp chart/ \
  --namespace headlamp \
  --create-namespace \
  --set oidc.issuerURL="https://auth.joeckr.dev" \
  --set oidc.existingSecret="headlamp-oidc"
```

---

## Testing & Validation

### Tier 1: Local Container (`compose.yml`)

```sh
mise run compose
mise run logs
curl -I http://localhost:4466/
mise run down
```

### Tier 2: Local Kubernetes Manifests (`mise run play`)

```sh
mise run helm-l
mise run play
# Verify locally, then tear down:
mise run play-d
```

### Tier 3: Cluster Verification

```sh
# Check pod health and Restricted PSS admission
kubectl -n headlamp get pods,pvc,httproute
kubectl -n headlamp describe pod -l app.kubernetes.io/name=headlamp
kubectl -n headlamp logs -l app.kubernetes.io/name=headlamp -f

# Verify Gateway attachment
kubectl -n headlamp describe httproute headlamp
```

---

## Local Development & Tasks

```sh
# Install tools and git hooks
mise run install

# Run all linters and hook checks
mise run hk
```

| Task | Description |
|---|---|
| `install` | Install tools and set up git hooks (`hk install --mise`) |
| `hk` / `check` | Run all linters, secret scans, and Helm lint (`hk check --all`) |
| `compose` | Start Headlamp locally via Podman Compose |
| `down` | Stop local Podman Compose stack |
| `logs` | Tail Podman Compose logs |
| `helm-l` | Lint the Helm chart (`helm lint chart/`) |
| `helm-t` | Render templates to `rendered.yaml` |
| `helm-i` | Install/upgrade the chart into the `headlamp` namespace |
| `helm-u` | Uninstall the chart from the `headlamp` namespace |
| `play` / `play-d` | Test rendered manifests locally with `podman play kube` |
| `trivy-fs` | Scan the repository filesystem with Trivy |

---

## Conventional Commits & Releases

Commits follow [Conventional Commits](https://www.conventionalcommits.org/):
- `feat:` -> minor release
- `fix:` -> patch release
- `feat!:` -> major release
- `chore:`, `docs:`, `ci:`, `refactor:` -> no release bump

Merging to `main` triggers `release.yml`, which bumps `chart/Chart.yaml`, tags the release, and publishes the OCI Helm chart to GHCR.

## License

See [LICENSE](LICENSE) for details.
