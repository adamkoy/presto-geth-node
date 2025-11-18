# Ethereum DevNet Load Testing Infrastructure

Complete infrastructure for running a single-node Ethereum devnet with Geth, comprehensive load testing, and performance monitoring.

## 🎯 Objective

Deploy and operate a single-node Ethereum devnet using Geth in developer mode on Kubernetes, perform load testing with Python, and visualize key performance metrics in Grafana.

## 🏗️ Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Load Generator │    │   Geth DevNet   │    │  Observability  │
│   (Python + Web3)│◄──►│  (Single Node)  │    │ (Prometheus +   │
│                 │    │                 │    │   Grafana)      │
│ • TPS Control    │    │ • 6-sec blocks  │    │                 │
│ • Concurrency    │    │ • Persistent PVC│    │ • TPS over time │
│ • Metrics Export │    │ • Prefunded acct│    │ • Latency       │
│                 │    │                 │    │ • Failure rates  │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
                    ┌────────────────────┐
                    │  Kubernetes/EKS    │
                    │  • StatefulSets    │
                    │  • Services        │
                    │  • ConfigMaps      │
                    │  • PersistentVolume│
                    └────────────────────┘
```

## ✅ Requirements Fulfilled

### Geth DevNet
- ✅ Single node deployment
- ✅ 6-second block production (`--dev.period=6`)
- ✅ Persistent state with PVC
- ✅ Prefunded account: `0x62358b29b9e3e70ff51D88766e41a339D3e8FFff` (100 ETH)

### Python Load Generator
- ✅ JSON-RPC connectivity
- ✅ Configurable TPS and concurrency
- ✅ TPS, RPS, MGas/s, latency, and failure rate metrics
- ✅ Prometheus metrics export

### Grafana Dashboard
- ✅ TPS over time
- ✅ RPC RPS over time
- ✅ MGas/s over time
- ✅ Latency (95th percentile)
- ✅ Failure rates
- ✅ Additional metrics (CPU, memory, connections)

## 🚀 Quick Start with Kind (Local Development)

### Prerequisites
- Docker
- Kind (Kubernetes in Docker)
- kubectl
- Python 3.11+ (for local development)

### 1. Create Kind Cluster

```bash
# Create kind cluster with extra resources for Geth
cat > kind-config.yaml << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 30000
    hostPort: 30000
    protocol: TCP
  - containerPort: 30001
    hostPort: 30001
    protocol: TCP
  - containerPort: 30909
    hostPort: 30909
    protocol: TCP
EOF

kind create cluster --config kind-config.yaml --name geth-devnet
```

### 2. Deploy Everything

```bash
# Deploy Geth node
kubectl apply -f geth-dev.yaml

# Deploy monitoring stack
kubectl apply -f monitoring.yaml

# Deploy load generator
kubectl apply -f load-generator.yaml

# Wait for all pods to be ready
kubectl wait --for=condition=ready pod --all --timeout=300s
```

### 3. Verify Deployment

```bash
# Check all components
kubectl get pods -A
kubectl get svc -A

# Verify 6-second block production
kubectl logs -f deployment/geth-dev -c geth

# Test Geth connectivity
kubectl run test --image=curlimages/curl --rm -it --restart=Never \
  -- curl -X POST http://geth-dev-lb.default.svc.cluster.local:8545 \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

### 4. Access Dashboards

```bash
# Port forward Grafana (admin/admin)
kubectl port-forward svc/grafana -n monitoring 3000:3000

# Port forward Prometheus
kubectl port-forward svc/prometheus -n monitoring 9090:9090

# Open in browser:
# Grafana: http://localhost:3000 (admin/admin)
# Prometheus: http://localhost:9090
```

### 5. Run Load Test

```bash
# Run load generator with custom parameters
kubectl set env deployment/load-generator \
  TARGET_TPS=50 \
  CONCURRENCY=10 \
  DURATION=600

# Trigger a new run
kubectl rollout restart deployment/load-generator

# Monitor logs
kubectl logs -f deployment/load-generator
```

## 🏭 Production Deployment (EKS)

### Prerequisites
- AWS CLI configured
- Terraform >= 1.6.0
- kubectl

### Deploy Infrastructure

```bash
# Initialize and deploy EKS cluster
terraform init
terraform apply

# Configure kubectl
$(terraform output -raw eks_connect)

# Verify cluster
kubectl get nodes
```

### Deploy Application Stack

```bash
# Apply all manifests
kubectl apply -f geth-dev.yaml
kubectl apply -f monitoring.yaml
kubectl apply -f load-generator.yaml

# Wait for completion
kubectl wait --for=condition=ready pod --all --timeout=600s
```

### Access External Services

```bash
# Get LoadBalancer URLs
kubectl get svc -o wide

# Example output:
# geth-dev-lb     LoadBalancer   10.100.XX.XX    XX.XXX.XXX.XXX   8545:XXXXX/TCP
# grafana         LoadBalancer   10.100.XX.XX    XX.XXX.XXX.XXX   3000:XXXXX/TCP
```

## 📊 Configuration

### Geth Parameters
- **Block time**: 6 seconds (`--dev.period=6`)
- **Chain ID**: 1337 (dev)
- **Gas limit**: 8M per block
- **Prefunded account**: `0x62358b29b9e3e70ff51D88766e41a339D3e8FFff` (100 ETH)
- **API**: eth,net,web3,personal,debug
- **Storage**: 10Gi PVC

### Load Generator Parameters
- **TPS**: Configurable via `TARGET_TPS` env var (default: 10)
- **Concurrency**: Configurable via `CONCURRENCY` env var (default: 5)
- **Duration**: Configurable via `DURATION` env var (default: 300s)
- **Metrics port**: 8000

### Monitoring
- **Prometheus**: Scrapes every 15s
- **Grafana**: Pre-configured dashboard
- **Retention**: 200h of metrics

## 🔧 Development

### Local Testing

```bash
# Install dependencies
pip install -r requirements.txt

# Run tests
python -m pytest test_load_generator.py -v

# Run load generator locally
export GETH_URL=http://localhost:8545
export TARGET_TPS=5
export CONCURRENCY=2
export DURATION=30
python load_generator.py
```

### Building Docker Image

```bash
# Build locally
docker build -t load-generator:latest .

# Run locally (requires Geth running)
docker run --rm \
  -e GETH_URL=http://host.docker.internal:8545 \
  -e TARGET_TPS=10 \
  -e CONCURRENCY=3 \
  -e DURATION=60 \
  -p 8000:8000 \
  load-generator:latest
```

## 🧪 CI/CD Pipeline

GitHub Actions pipeline includes:
- **Linting**: Python (flake8, black, isort, mypy) and YAML
- **Testing**: Unit tests with pytest
- **Building**: Docker image build and push to GHCR
- **Security**: Automated dependency scanning

## 🧹 Cleanup

### Kind Cluster
```bash
kubectl delete -f load-generator.yaml
kubectl delete -f monitoring.yaml
kubectl delete -f geth-dev.yaml
kind delete cluster --name geth-devnet
```

### EKS Cluster
```bash
kubectl delete -f load-generator.yaml
kubectl delete -f monitoring.yaml
kubectl delete -f geth-dev.yaml
terraform destroy
```

## 📈 Performance Benchmarks

Typical performance on t3.medium instance:
- **Block production**: ~10 blocks/min (6-second target)
- **Max TPS**: ~50-100 (depends on gas limits)
- **Latency**: 100-500ms (95th percentile)
- **Memory usage**: 200-500MB
- **CPU usage**: 10-30%

## 💾 Optional: Persistent Storage on EKS (EBS CSI Driver)

By default, the simple dev node uses `emptyDir` (ephemeral). To back Geth with a real EBS volume on EKS:

### 1. Prerequisites (EKS)

- EKS cluster: `geth-dev-eks` in `eu-west-1`
- OIDC issuer: `https://oidc.eks.eu-west-1.amazonaws.com/id/B7A3E498F9BAE231F61076746475B1BE`
- AWS account ID: `717916807684`

Verify:

```bash
aws eks describe-cluster \
  --name geth-dev-eks \
  --region eu-west-1 \
  --query "cluster.identity.oidc.issuer" \
  --output text

aws iam list-open-id-connect-providers | \
  grep B7A3E498F9BAE231F61076746475B1BE
```

### 2. Create IAM role for the EBS CSI driver

```bash
cat > trust-policy-ebs-csi.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::717916807684:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/B7A3E498F9BAE231F61076746475B1BE"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.eu-west-1.amazonaws.com/id/B7A3E498F9BAE231F61076746475B1BE:aud": "sts.amazonaws.com",
          "oidc.eks.eu-west-1.amazonaws.com/id/B7A3E498F9BAE231F61076746475B1BE:sub": "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --assume-role-policy-document file://trust-policy-ebs-csi.json

aws iam attach-role-policy \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
```

### 3. Install the EBS CSI driver add-on

```bash
aws eks create-addon \
  --cluster-name geth-dev-eks \
  --region eu-west-1 \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn arn:aws:iam::717916807684:role/AmazonEKS_EBS_CSI_DriverRole
```

### 4. Create StorageClass and PVC (example)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-ebs
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: geth-data-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
  storageClassName: gp3-ebs
```

Apply:

```bash
kubectl apply -f pvc.yaml
kubectl get pvc geth-data-pvc
```

### 5. Mount PVC in a Geth Deployment

For a persistent node, adjust a Deployment to use:

```yaml
volumeMounts:
  - name: datadir
    mountPath: /root/.ethereum
volumes:
  - name: datadir
    persistentVolumeClaim:
      claimName: geth-data-pvc
```

This keeps Geth chain data on an EBS volume across pod restarts while still using the same dev node pattern as `geth-simple.yaml`.

## 🛠️ Troubleshooting

### Geth Issues
```bash
# Check Geth logs
kubectl logs deployment/geth-dev -c geth

# Verify genesis initialization
kubectl logs deployment/geth-dev -c init-genesis

# Check PVC
kubectl get pvc
kubectl describe pvc geth-data-pvc
```

### Load Generator Issues
```bash
# Check load generator logs
kubectl logs deployment/load-generator

# Verify connectivity
kubectl exec deployment/load-generator -- curl -f http://geth-dev-lb:8545
```

### Monitoring Issues
```bash
# Check Prometheus targets
kubectl port-forward svc/prometheus -n monitoring 9090:9090
# Visit http://localhost:9090/targets

# Check Grafana logs
kubectl logs deployment/grafana -n monitoring
```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes with tests
4. Ensure CI passes
5. Submit a pull request

## 📝 License

This project is licensed under the MIT License.


# Monitor block production
kubectl logs -f deployment/geth-dev

# Check latest block
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# Get account balance
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_getBalance","params":["0x71562b71999873db5b286df957af199ec94617f7","latest"],"id":1}'

# Send a test transaction (unlock account first)
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"personal_unlockAccount","params":["0x71562b71999873db5b286df957af199ec94617f7",""],"id":1}'

# Create a new account
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"personal_newAccount","params":["password"],"id":1}'# presto-geth-node
