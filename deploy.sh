#!/bin/bash

# Ethereum DevNet Load Testing Infrastructure - Deployment Script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIND_CLUSTER_NAME="geth-devnet"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_dependencies() {
    log_info "Checking dependencies..."

    local missing_deps=()

    if ! command -v kubectl &> /dev/null; then
        missing_deps+=("kubectl")
    fi

    if [[ "${DEPLOY_ENV}" == "kind" ]]; then
        if ! command -v kind &> /dev/null; then
            missing_deps+=("kind")
        fi
    fi

    if [[ "${DEPLOY_ENV}" == "eks" ]]; then
        if ! command -v terraform &> /dev/null; then
            missing_deps+=("terraform")
        fi
        if ! command -v aws &> /dev/null; then
            missing_deps+=("aws-cli")
        fi
    fi

    if ! command -v helm &> /dev/null; then
        missing_deps+=("helm")
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_error "Please install them and try again."
        exit 1
    fi

    log_success "All dependencies found"
}

setup_kind() {
    log_info "Setting up Kind cluster..."

    if kind get clusters | grep -q "^${KIND_CLUSTER_NAME}$"; then
        log_warn "Kind cluster '${KIND_CLUSTER_NAME}' already exists"
        read -p "Do you want to delete and recreate it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kind delete cluster --name "${KIND_CLUSTER_NAME}"
        else
            log_info "Using existing cluster"
            kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}"
            return
        fi
    fi
    # Create a simple kind cluster without extra config
    kind create cluster --name "${KIND_CLUSTER_NAME}"
    kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}"
    log_success "Kind cluster created"
}

setup_eks() {
    log_info "Setting up EKS cluster..."

    cd "${SCRIPT_DIR}"
    terraform init
    terraform apply

    # Configure kubectl
    local kubeconfig_cmd
    kubeconfig_cmd=$(terraform output -raw eks_connect)
    eval "${kubeconfig_cmd}"

    log_success "EKS cluster configured"
}

deploy_components() {
    log_info "Deploying components..."

    # Deploy via Helm charts
    log_info "Deploying Geth node (Helm release 'geth')..."
    helm upgrade --install geth "${SCRIPT_DIR}/charts/geth-node"

    log_info "Deploying observability stack (Helm release 'observability')..."
    helm upgrade --install observability "${SCRIPT_DIR}/charts/observability"

    log_info "Deploying load generator (Helm release 'loadgen')..."
    helm upgrade --install loadgen "${SCRIPT_DIR}/charts/load-generator"

    log_info "Waiting for all pods to be ready..."
    kubectl wait --for=condition=ready pod --all --timeout=300s

    log_success "All components deployed"
}

verify_deployment() {
    log_info "Verifying deployment..."

    echo "Pods:"
    kubectl get pods -A

    echo ""
    echo "Services:"
    kubectl get svc -A

    echo ""
    echo "Persistent Volumes:"
    kubectl get pvc

    log_success "Deployment verification complete"
}

show_access_info() {
    log_info "Access information:"

    if [[ "${DEPLOY_ENV}" == "kind" ]]; then
        echo "Port forwarding commands:"
        echo "  Geth JSON-RPC: kubectl port-forward svc/geth-geth-node 8545:8545"
        echo "  Grafana UI:    kubectl port-forward -n monitoring svc/observability-observability-grafana 3000:3000"
        echo "  Prometheus UI: kubectl port-forward -n monitoring svc/observability-observability-prometheus 9090:9090"
        echo ""
        echo "Access URLs:"
        echo "  Geth JSON-RPC: http://localhost:8545"
        echo "  Grafana:       http://localhost:3000"
        echo "  Prometheus:    http://localhost:9090"
    else
        echo "Geth service (ClusterIP by default):"
        kubectl get svc geth-geth-node -o wide || true
        echo ""
        echo "To access JSON-RPC from your machine:"
        echo "  kubectl port-forward svc/geth-geth-node 8545:8545"
        echo "  curl -X POST http://localhost:8545 \\"
        echo "    -H 'Content-Type: application/json' \\"
        echo "    --data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}'"
        echo ""
        echo "Grafana and Prometheus (ClusterIP by default in 'monitoring' namespace):"
        kubectl get svc -n monitoring || true
        echo "  Port-forward examples:"
        echo "    kubectl port-forward -n monitoring svc/observability-observability-grafana 3000:3000"
        echo "    kubectl port-forward -n monitoring svc/observability-observability-prometheus 9090:9090"
    fi

    echo ""
    echo "Test commands:"
    echo "  Check block production: kubectl logs -f deployment/geth-dev"
    echo "  Test RPC (after port-forward):"
    echo "    curl -X POST http://localhost:8545 \\"
    echo "      -H 'Content-Type: application/json' \\"
    echo "      --data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}'"
}

cleanup() {
    log_info "Cleaning up..."

    log_info "Uninstalling Helm releases (geth, observability, loadgen)..."
    helm uninstall geth >/dev/null 2>&1 || true
    helm uninstall observability >/dev/null 2>&1 || true
    helm uninstall loadgen >/dev/null 2>&1 || true

    if [[ "${DEPLOY_ENV}" == "kind" ]]; then
        if command -v kind &> /dev/null; then
            kind delete cluster --name "${KIND_CLUSTER_NAME}"
        else
            log_warn "kind not installed; skipping kind cluster delete"
        fi
    elif [[ "${DEPLOY_ENV}" == "eks" ]]; then
        cd "${SCRIPT_DIR}"
        terraform destroy
    fi

    log_success "Cleanup complete"
}

usage() {
    echo "Usage: $0 [OPTIONS] COMMAND"
    echo ""
    echo "Commands:"
    echo "  deploy    Deploy the entire infrastructure"
    echo "  cleanup   Clean up all resources"
    echo ""
    echo "Options:"
    echo "  -e ENV    Deployment environment (kind or eks, default: kind)"
    echo "  -h        Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 deploy                    # Deploy to Kind"
    echo "  $0 -e eks deploy            # Deploy to EKS"
    echo "  $0 cleanup                  # Clean up Kind"
    echo "  $0 -e eks cleanup           # Clean up EKS"
}

# Parse command line arguments
DEPLOY_ENV="kind"

while getopts "e:h" opt; do
    case $opt in
        e)
            DEPLOY_ENV="$OPTARG"
            if [[ "$DEPLOY_ENV" != "kind" && "$DEPLOY_ENV" != "eks" ]]; then
                log_error "Invalid environment. Use 'kind' or 'eks'"
                exit 1
            fi
            ;;
        h)
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

shift $((OPTIND-1))

COMMAND="$1"

case "$COMMAND" in
    deploy)
        check_dependencies

        if [[ "${DEPLOY_ENV}" == "kind" ]]; then
            setup_kind
        elif [[ "${DEPLOY_ENV}" == "eks" ]]; then
            setup_eks
        fi

        deploy_components
        verify_deployment
        show_access_info
        ;;
    cleanup)
        cleanup
        ;;
    *)
        log_error "Invalid command: $COMMAND"
        echo ""
        usage
        exit 1
        ;;
esac
