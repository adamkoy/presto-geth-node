### Secrets reference (for GitHub Actions / CI)

This project currently has no real secrets committed, but the following values **should be provided via GitHub Actions secrets or local environment**, not hard‑coded in production.

#### AWS / Terraform

- **`AWS_ACCESS_KEY_ID`**
  - **Used for**: Terraform `aws` provider (CI applying `main.tf`).
  - **GitHub Actions secret name**: `AWS_ACCESS_KEY_ID`.
- **`AWS_SECRET_ACCESS_KEY`**
  - **Used for**: Terraform `aws` provider.
  - **GitHub Actions secret name**: `AWS_SECRET_ACCESS_KEY`.
- **`AWS_DEFAULT_REGION`**
  - **Used for**: Terraform + `aws eks update-kubeconfig`.
  - **GitHub Actions secret name**: `AWS_DEFAULT_REGION` (matches `var.region` in `variables.tf`).

#### Container registry (for workload image)

If you build/push the load generator image from CI:

- **`REGISTRY_USERNAME` / `REGISTRY_PASSWORD`** (or a GitHub token)
  - **Used for**: `docker login` (in a future GitHub Actions workflow).
  - **GitHub Actions secret names**: e.g. `REGISTRY_USERNAME`, `REGISTRY_PASSWORD`.
- **`WORKLOAD_IMAGE`**
  - **Used for**: Image reference in `charts/load-generator/values.yaml` (`image.repository`, `image.tag`).
  - **GitHub Actions secret name**: `WORKLOAD_IMAGE` (e.g. `ghcr.io/<user>/geth-workload:latest`).

#### Grafana admin credentials

Current default (dev only) is in `charts/observability/values.yaml`:

- **Path**: `charts/observability/values.yaml`
  - `grafana.adminUser: admin`
  - `grafana.adminPassword: admin`

For a real deployment:

- Override these via Helm or CI, not by committing real credentials.
- Recommended GitHub Actions secrets:
  - `GRAFANA_ADMIN_USER`
  - `GRAFANA_ADMIN_PASSWORD`

#### How to use in GitHub Actions (example snippet)

In a workflow, you would map secrets to env vars like:

```yaml
env:
  AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
  AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
  AWS_DEFAULT_REGION: ${{ secrets.AWS_DEFAULT_REGION }}
  GRAFANA_ADMIN_USER: ${{ secrets.GRAFANA_ADMIN_USER }}
  GRAFANA_ADMIN_PASSWORD: ${{ secrets.GRAFANA_ADMIN_PASSWORD }}
```

and then pass them into `terraform` and `helm` commands as needed.


