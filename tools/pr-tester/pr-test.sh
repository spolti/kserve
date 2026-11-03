#!/usr/bin/env bash
# KServe PR Test - convenience wrapper
#
# Usage:
#   ./pr-test.sh deploy <PR_URL> [OPTIONS]
#   ./pr-test.sh cleanup <PR_NUMBER> [OPTIONS]
#
# Examples:
#   ./pr-test.sh deploy https://github.com/kserve/kserve/pull/1234
#   ./pr-test.sh deploy https://github.com/kserve/kserve/pull/1234 --cluster minikube --engine podman
#   ./pr-test.sh cleanup 1234
#   ./pr-test.sh cleanup 1234 --keep-cluster

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Add local bin/ to PATH so minikube (and other locally-installed tools) are found
export PATH="${SCRIPT_DIR}/bin:${PATH}"

check_ansible() {
    if ! command -v ansible-playbook &>/dev/null; then
        echo "Error: ansible-playbook is not installed or not in PATH."
        echo ""
        echo "Install Ansible first:"
        echo ""
        case "$(uname -s)" in
            Darwin)
                echo "  brew install ansible"
                echo "  # or"
                echo "  python3 -m pip install --user ansible"
                ;;
            Linux)
                if command -v dnf &>/dev/null; then
                    echo "  sudo dnf install -y ansible-core"
                elif command -v apt-get &>/dev/null; then
                    echo "  sudo apt update && sudo apt install -y ansible"
                else
                    echo "  python3 -m pip install --user ansible"
                fi
                ;;
            *)
                echo "  python3 -m pip install --user ansible"
                ;;
        esac
        echo ""
        echo "See the README for detailed installation instructions."
        exit 1
    fi
}

usage() {
    cat <<EOF
KServe PR Local Test Automation

Usage:
  $(basename "$0") deploy <PR_URL> [OPTIONS]
  $(basename "$0") cleanup <PR_NUMBER> [OPTIONS]
  $(basename "$0") setup-minikube [OPTIONS]
  $(basename "$0") cleanup-minikube [OPTIONS]
  $(basename "$0") deploy-transformer [OPTIONS]
  $(basename "$0") cleanup-transformer

Commands:
  deploy              Fetch, scan, build, deploy, and validate a KServe PR
  cleanup             Tear down test resources for a given PR
  setup-minikube      Install/upgrade minikube to latest, start cluster with dashboard, registry, and NFS
  cleanup-minikube    Delete the minikube cluster
  deploy-transformer  Deploy an InferenceService with MLServer runtime and sentiment transformer
  cleanup-transformer Tear down the transformer deployment

Deploy options:
  --cluster TYPE      Target cluster: kind (default), minikube, crc, openshift
  --engine ENGINE     Container engine: docker (default), podman
  --mode MODE         Deploy mode: raw (default), serverless
  --skip-scan         Skip the security scan
  --copilot           Post a @copilot review comment on the GitHub PR (not local)
  --no-auto-detect    Disable auto-detection, use manual images/models config
  --canary            Deploy the canary example InferenceService (sklearn with canary revisions)
  --models LIST       Comma-separated models: sklearn-iris,xgboost-iris,lightgbm-iris,sklearn-canary,llmisvc-opt-125m

Cleanup options:
  --cluster TYPE      Target cluster type (default: kind)
  --keep-cluster      Don't destroy the cluster during cleanup
  --engine ENGINE     Container engine (default: docker)

Setup-minikube options:
  --cpus N            CPUs for minikube (default: 4)
  --memory N          Memory in MB for minikube (default: 8192)
  --driver DRIVER     Minikube driver: docker, podman, or auto (default: auto-detect)
  --csi-hostpath      Enable CSI hostpath driver for block device PVCs
  --nfs               Deploy NFS Provisioner Operator for RWX storage

Deploy-transformer options:
  --model-uri URI       Model storageUri (default: hf://optimum/distilbert-base-uncased-finetuned-sst-2-english)
  --namespace NS        Namespace for deployment (default: kserve-transformer-test)
  --transformer-image   Transformer container image (default: ODH sentiment transformer)
  --mlserver-image IMG  MLServer runtime image (default: quay.io/opendatahub/mlserver:odh-v3.4)
  --autoscaler TYPE     Autoscaler: none (default), hpa, keda
  --min-replicas N      Transformer min replicas (default: 1, requires --autoscaler)
  --max-replicas N      Transformer max replicas (default: 5, requires --autoscaler)
  --cpu-target N        CPU utilization % target for autoscaling (default: 50)

Examples:
  $(basename "$0") deploy https://github.com/kserve/kserve/pull/1234
  $(basename "$0") deploy https://github.com/kserve/kserve/pull/5678 --cluster minikube --models sklearn-iris,xgboost-iris
  $(basename "$0") cleanup 1234
  $(basename "$0") cleanup 1234 --keep-cluster
  $(basename "$0") setup-minikube
  $(basename "$0") setup-minikube --cpus 6 --memory 16384 --nfs
  $(basename "$0") cleanup-minikube
  $(basename "$0") deploy-transformer
  $(basename "$0") deploy-transformer --model-uri s3://my-bucket/sentiment-model/
  $(basename "$0") deploy-transformer --autoscaler keda --max-replicas 10 --cpu-target 60
  $(basename "$0") cleanup-transformer
EOF
    exit "${1:-0}"
}

cmd_deploy() {
    check_ansible
    local pr_url="${1:?PR URL required}"
    shift

    local extra_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cluster)
                extra_args+=(-e "cluster_type=$2"); shift 2 ;;
            --engine)
                extra_args+=(-e "engine=$2"); shift 2 ;;
            --mode)
                extra_args+=(-e "deployment_mode=$2"); shift 2 ;;
            --skip-scan)
                extra_args+=(-e "skip_security_scan=true"); shift ;;
            --copilot)
                extra_args+=(-e "enable_copilot_review=true"); shift ;;
            --no-auto-detect)
                extra_args+=(-e "auto_detect_components=false"); shift ;;
            --canary)
                extra_args+=(-e "deploy_canary_model=true"); shift ;;
            --models)
                local models_json
                models_json=$(echo "$2" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip().split(',')))")
                extra_args+=(-e "models_to_deploy=${models_json}")
                shift 2 ;;
            *)
                echo "Unknown option: $1"; usage 1 ;;
        esac
    done

    cd "$SCRIPT_DIR"
    ansible-playbook deploy-pr.yml -e "pr_url=${pr_url}" "${extra_args[@]}"
}

cmd_cleanup() {
    check_ansible
    local pr_number="${1:?PR number required}"
    shift

    local extra_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cluster)
                extra_args+=(-e "cluster_type=$2"); shift 2 ;;
            --keep-cluster)
                extra_args+=(-e "destroy_cluster=false"); shift ;;
            --engine)
                extra_args+=(-e "engine=$2"); shift 2 ;;
            *)
                echo "Unknown option: $1"; usage 1 ;;
        esac
    done

    cd "$SCRIPT_DIR"
    ansible-playbook cleanup.yml -e "pr_number=${pr_number}" "${extra_args[@]}"
}

cmd_setup_minikube() {
    check_ansible
    local extra_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cpus)
                extra_args+=(-e "minikube_cpus=$2"); shift 2 ;;
            --memory)
                extra_args+=(-e "minikube_memory=$2"); shift 2 ;;
            --driver)
                extra_args+=(-e "minikube_driver=$2"); shift 2 ;;
            --csi-hostpath)
                extra_args+=(-e "enable_csi_hostpath=true"); shift ;;
            --nfs)
                extra_args+=(-e "enable_nfs_provisioner=true"); shift ;;
            *)
                echo "Unknown option: $1"; usage 1 ;;
        esac
    done

    cd "$SCRIPT_DIR"
    ansible-playbook setup-minikube.yml "${extra_args[@]+"${extra_args[@]}"}"
}

cmd_cleanup_minikube() {
    check_ansible
    cd "$SCRIPT_DIR"
    ansible-playbook cleanup-minikube.yml
}

cmd_deploy_transformer() {
    check_ansible
    local extra_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --model-uri)
                extra_args+=(-e "model_storage_uri=$2"); shift 2 ;;
            --namespace)
                extra_args+=(-e "transformer_namespace=$2"); shift 2 ;;
            --transformer-image)
                extra_args+=(-e "transformer_image=$2"); shift 2 ;;
            --mlserver-image)
                extra_args+=(-e "mlserver_image=$2"); shift 2 ;;
            --autoscaler)
                extra_args+=(-e "autoscaler=$2"); shift 2 ;;
            --min-replicas)
                extra_args+=(-e "transformer_min_replicas=$2"); shift 2 ;;
            --max-replicas)
                extra_args+=(-e "transformer_max_replicas=$2"); shift 2 ;;
            --cpu-target)
                extra_args+=(-e "autoscale_cpu_target=$2"); shift 2 ;;
            *)
                echo "Unknown option: $1"; usage 1 ;;
        esac
    done

    cd "$SCRIPT_DIR"
    ansible-playbook deploy-transformer.yml "${extra_args[@]+"${extra_args[@]}"}"
}

cmd_cleanup_transformer() {
    check_ansible
    cd "$SCRIPT_DIR"
    ansible-playbook deploy-transformer.yml -e cleanup=true
}

case "${1:-}" in
    deploy)
        shift; cmd_deploy "$@" ;;
    cleanup)
        shift; cmd_cleanup "$@" ;;
    setup-minikube)
        shift; cmd_setup_minikube "$@" ;;
    cleanup-minikube)
        shift; cmd_cleanup_minikube ;;
    deploy-transformer)
        shift; cmd_deploy_transformer "$@" ;;
    cleanup-transformer)
        shift; cmd_cleanup_transformer ;;
    -h|--help|help)
        usage 0 ;;
    *)
        echo "Error: unknown command '${1:-}'"
        usage 1 ;;
esac
