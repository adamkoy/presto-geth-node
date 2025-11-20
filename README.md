## Ethereum DevNet Load‑Testing Stack

Complete, reproducible setup for a single‑node Ethereum devnet on Kubernetes (Kind or EKS), a Python‑based load generator, and an observability stack (Prometheus + Grafana) – all wired together via Helm and Terraform.

---

## Table of contents

- [Introduction](#introduction)
  - [Directory overview](#directory-overview)
- [Usage](#usage)
  - [Local (Kind)](#local-kind)
  - [EKS (AWS)](#eks-aws)
  - [Verification (blocks, persistence, metrics)](#verification-blocks-persistence-metrics)
- [Configuration reference](#configuration-reference)
- [Local development of the workload](#local-development-of-the-workload)
- [CI/CD and environments](#cicd-and-environments)
- [Cleanup](#cleanup)
- [Troubleshooting notes](#troubleshooting-notes)

---

## Introduction

The repository is organised around three Helm charts and one Terraform module:

- **`charts/geth-node`** – Geth devnet node
  - Single node, dev mode, ~6s blocks
  - Persistent storage via PVC (EBS on EKS)
  - HTTP JSON‑RPC + metrics endpoint
  - Prefunded account `0x62358b29b9e3e70ff51D88766e41a339D3e8FFff`
- **`charts/load-generator`** – Python workload
  - Web3‑based transaction generator
  - Configurable TPS, concurrency, and duration
  - Exposes Prometheus metrics on port `8000`
- **`charts/observability`** – Prometheus + Grafana
  - Prometheus scrapes Geth and the workload
  - Grafana ships with a pre‑wired dashboard
- **Terraform** (`main.tf`, `variables.tf`)
  - Provisions an EKS cluster and node group
  - Installs the EBS CSI driver via an addon + IRSA

There is also a thin orchestration script:

- **`deploy.sh`**
  - `kind` path: create a local Kind cluster and install the three Helm charts
  - `eks` path: run Terraform to stand up EKS, then install the same charts

---

### Directory overview

```text
.
├── charts/                 # Helm charts for geth-node, observability, load-generator
├── load-generator-image/   # Dockerfile + Python workload
├── .github/workflows/      # GitHub Actions pipelines (lint, image, infra, helm, full-pipeline)
├── deploy.sh               # Helper script for local Kind and EKS deploys
├── main.tf, variables.tf   # Terraform EKS stack
├── SECRETS.md              # Documentation of CI/CD secrets (no real secrets committed)
└── README.md               # This file
```

---

## Usage

### Prerequisites

Install these locally:

- Docker
- `kubectl`
- `helm`
- `kind` (for local clusters)
- `terraform` and `aws` CLI (for EKS)

For EKS you also need:

- An AWS account and credentials with permissions to create VPC/EKS/IAM
- An S3 backend or local state (configured in Terraform as you prefer)

---

### Local (Kind)

This path gives you a full devnet + workload + dashboards on a local Kind cluster.

#### 1. Deploy

From the repo root:

```bash
./deploy.sh deploy
```

What this does:

- Creates a Kind cluster named `geth-devnet` (if it does not exist)
- Installs the three Helm charts:
  - `geth-node` as release `geth`
  - `observability` as release `observability`
  - `load-generator` as release `loadgen`
- Waits for all pods to become ready

You can sanity‑check:

```bash
kubectl get pods -A
kubectl get svc -A
```

#### 2. Access endpoints

Port‑forward from your laptop:

```bash
# Geth JSON‑RPC
kubectl port-forward svc/geth-geth-node 8545:8545

# Grafana (monitoring namespace)
kubectl port-forward -n monitoring \
  svc/observability-observability-grafana 3000:3000

# Prometheus
kubectl port-forward -n monitoring \
  svc/observability-observability-prometheus 9090:9090
```

Then in a browser:

- **Geth JSON‑RPC** (curl only): `http://localhost:8545`
- **Grafana**: `http://localhost:3000` (default `admin` / `admin`)
- **Prometheus**: `http://localhost:9090`

### Verification (blocks, persistence, metrics)

#### 3. Verify the devnet

With the port‑forward in place:

```bash
# Latest block number
curl -s -X POST http://localhost:8545 \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# Prefunded account balance
curl -s -X POST http://localhost:8545 \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc":"2.0",
    "method":"eth_getBalance",
    "params":["0x62358b29b9e3e70ff51D88766e41a339D3e8FFff","latest"],
    "id":1
  }'
```

You should see a non‑zero block height and a balance of at least `100 ETH` (it will climb as the workload sends funds to that address).

#### 4. Verify 6‑second block production

With the JSON‑RPC port‑forward still running:

```bash
while true; do
  date
  curl -s -X POST http://localhost:8545 \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    | jq -r '.result'
  sleep 6
done
```

You should see the block number increase roughly every 6 seconds. The exact cadence will depend on scheduling and load, but over a few minutes it averages to ~10 blocks/min.

#### 5. Verify persistence across restarts

1. Note the current block number using the loop above or a single `eth_blockNumber` call.
2. Restart the Geth pod (PVC is retained):

```bash
kubectl delete pod -l app.kubernetes.io/name=geth-node
kubectl get pods
```

3. Once the pod is back to `Running`, hit `eth_blockNumber` again.  
   The block height should continue from the previous value, not reset to zero – this confirms that chain data is persisted on the PVC.

#### 6. Watch the workload + dashboards

Tail the workload logs:

```bash
kubectl logs -f deploy/loadgen-load-generator
```

You should see log lines like:

- Connection to the Geth JSON‑RPC endpoint
- Prefunded account balance
- Periodic load runs with metrics summaries (TPS, RPS, MGas/s, latency, failures)

In Grafana, open the “Geth DevNet Performance Dashboard”. It includes:

- **Current Block Number** – `max(geth_workload_head_block_number)`
- **Block Production Rate (blocks/min)** – `sum(rate(geth_workload_head_block_number[5m])) * 60`
- **TPS Over Time** – `geth_workload_tps`
- **RPC RPS** – `geth_workload_rpc_rps`
- **Gas Used (MGas/s)** – `geth_workload_mgas_per_sec`
- **Average Transaction Latency** – `geth_workload_avg_latency_seconds`
- **Failure Rate** – `geth_workload_failure_rate * 100`

---

### EKS (AWS)

The EKS path uses Terraform to provision the cluster and wiring, then uses the same Helm charts.

#### 1. Deploy the cluster

From the repo root:

```bash
terraform init
terraform apply
```

The Terraform module:

- Creates the VPC, subnets, security groups, and EKS cluster
- Provisions a managed node group
- Configures OIDC and an IRSA role for the **EBS CSI driver**
- Installs the `aws-ebs-csi-driver` addon and points it at the IRSA role

After `terraform apply` completes, configure `kubectl` using the helper output:

```bash
$(terraform output -raw eks_connect)
kubectl get nodes
```

#### 2. Deploy the stack via `deploy.sh`

With `kubectl` pointing at the EKS cluster:

```bash
./deploy.sh -e eks deploy
```

This skips Kind creation and just:

- Verifies dependencies (`kubectl`, `terraform`, `aws`, `helm`)
- Ensures Terraform has been applied
- Installs the three Helm charts into the EKS cluster

You can then re‑use the same port‑forward commands as in the Kind section to reach Geth, Prometheus, and Grafana.

#### 3. Storage on EKS

On EKS, the Geth chart uses a PVC backed by the default StorageClass (for most clusters this is `gp2` or `gp3` on EBS). The EBS CSI addon and its IAM role are managed entirely by Terraform; there is no need to run `aws eks create-addon` by hand.

If you want to change the storage class or size, adjust:

- `charts/geth-node/values.yaml` → `persistence.storageClass`, `persistence.size`

Apply with:

```bash
helm upgrade geth charts/geth-node
```

Be aware that changing `storageClassName` on an existing PVC requires recreating the PVC.

---

## Configuration reference

### Geth node (`charts/geth-node`)

Key defaults (see `charts/geth-node/values.yaml` for the full list):

- **Image**: official `ethereum/client-go`
- **Mode**: `--dev` with a 6‑second block period
- **Chain ID**: `1337`
- **HTTP JSON‑RPC**: enabled on port `8545` with permissive CORS/host for in‑cluster access
- **Metrics**: Prometheus metrics endpoint exposed on port `6060` at `/debug/metrics/prometheus`
- **Persistence**:
  - PVC named `<release>-geth-node-data`
  - Configurable `storageClass` and `size`
- **Prefunding**:
  - Either baked via dev mode accounts or via a small Job that sends funds to
    `0x62358b29b9e3e70ff51D88766e41a339D3e8FFff`

### Load generator (`charts/load-generator`)

The workload image is built from `load-generator-image/Dockerfile.workload` and runs `workload.py`. It connects to the Geth JSON‑RPC endpoint and repeatedly sends small value transfers from a dev account to the prefunded target address.

Configuration (all via env vars in the Deployment):

- **`GETH_URL`**
  - Default: `http://geth-geth-node.default.svc.cluster.local:8545`
  - Set in the Helm values under `geth.url`
- **`TARGET_TPS`**
  - Total target transactions per second across all workers
  - Helm value: `workload.targetTps`
- **`CONCURRENCY`**
  - Number of worker threads sending transactions
  - Helm value: `workload.concurrency`
- **`DURATION_SECONDS`**
  - Duration of each load run before metrics are summarised
  - Helm value: `workload.durationSeconds`
- **`METRICS_PORT`**
  - Port for the Prometheus metrics HTTP endpoint
  - Helm value: `workload.metricsPort` (default `8000`)

Metrics exposed by `workload.py` (all prefixed with `geth_workload_`):

- `geth_workload_tps`
- `geth_workload_rpc_rps`
- `geth_workload_mgas_per_sec`
- `geth_workload_failure_rate`
- `geth_workload_avg_latency_seconds`
- `geth_workload_head_block_number`

The chart also annotates the pod for Prometheus scraping and creates a small ClusterIP service so Prometheus can target it directly.

### Observability (`charts/observability`)

Prometheus:

- Scrape interval and evaluation interval default to `15s`
- Static scrape configs for:
  - The Prometheus server itself
  - The Geth node metrics endpoint (service name + namespace from values)
  - The load generator metrics endpoint (service name + namespace from values)
- Optional Kubernetes pod discovery if you want to point it at other workloads

Grafana:

- Uses the official Grafana image
- Default admin user/password: `admin` / `admin` (see `values.yaml` – change this for anything non‑throwaway)
- One datasource: Prometheus (in‑cluster)
- One pre‑provisioned dashboard: Geth DevNet performance (see
  `charts/observability/templates/grafana-dashboard.yaml`)

---

## Local development of the workload

If you want to tweak the workload logic, you can run it directly on your machine:

```bash
cd load-generator-image
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

export GETH_URL=http://localhost:8545       # e.g. port‑forwarded Geth
export TARGET_TPS=5
export CONCURRENCY=2
export DURATION_SECONDS=60
export METRICS_PORT=8000

python workload.py
```

To build and push the Docker image:

```bash
docker build --platform=linux/amd64 \
  -t <your-registry>/geth-workload:latest \
  -f Dockerfile.workload .

docker push <your-registry>/geth-workload:latest
```

Then update `charts/load-generator/values.yaml` → `image.repository` / `image.tag` and redeploy:

```bash
helm upgrade --install loadgen charts/load-generator
```

---

## CI/CD and environments

Sensitive values (AWS credentials, Docker registry tokens, Grafana admin password, etc.) are intentionally not committed. See `SECRETS.md` for a list of values that should live in your CI/CD secrets store (for example GitHub Actions secrets).

GitHub Actions is used for linting, image builds, and infra/app deploys:

- **`ci-cd.yml`** – lints:
  - Python: `flake8` + `mypy` on `load-generator-image/workload.py`
  - YAML: `yamllint` on workflows and Helm `Chart.yaml` / `values.yaml`
- **`build-load-generator.yml`** – builds and pushes the workload image:
  - Job 1: flake8 on `workload.py`
  - Job 2: on success, `docker/build-push-action` builds and pushes `adamkkk89/geth-workload:latest`
- **`infra-deploy.yml`** – Terraform plan/apply for EKS:
  - Uses OIDC to assume an AWS IAM role (`AWS_ROLE_NAME`)
  - On manual runs, takes an `environment` (`dev|stage|prod`) and an `apply` flag
- **`helm-deploy.yml`** – Helm deploy of the three charts to the selected environment:
  - Reads the `eks_connect` output from Terraform to configure `kubectl`
- **`full-pipeline.yml`** / **`full-pipeline`** (if enabled) – orchestrates the above:
  - Lint → build image → Terraform → Helm in one run

GitHub Environments (e.g. `presto-dev`, `presto-stage`, `presto-prod`) can be used to require approvals before Terraform `apply` and Helm deploy run in each stage.

---

## Cleanup

### Kind

```bash
./deploy.sh cleanup
```

This uninstalls the three Helm releases and deletes the Kind cluster.

### EKS

```bash
./deploy.sh -e eks cleanup
```

This uninstalls the Helm releases and runs `terraform destroy` to tear down the EKS cluster and associated AWS resources.

---

## Troubleshooting notes

Some issues you might hit and how to recover:

- **Pods stuck in `Pending` with PVC errors**
  - Check `kubectl get pvc` and verify that the claim is `Bound`
  - If you need to change `storageClassName`, delete the PVC and re‑deploy; it is immutable
- **Geth metrics returning 404**
  - Ensure Prometheus is scraping `/debug/metrics/prometheus` on the Geth service port
- **Workload metrics all zero**
  - Confirm the workload container can reach Geth (logs will show connection attempts)
  - Check that `TARGET_TPS` and `CONCURRENCY` are set to values > 0
  - Hit `http://<loadgen-service>:8000/metrics` and look for `geth_workload_*`
- **Grafana dashboard shows “No data”**
  - Verify Prometheus has data for the relevant series via the Prometheus UI
  - Confirm the dashboard queries match the metric names listed above

The logs from `deploy.sh`, the Geth pod, Prometheus, Grafana, and the workload pod together usually give enough signal to track down any misconfiguration quickly.


