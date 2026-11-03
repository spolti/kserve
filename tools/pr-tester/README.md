# KServe PR Local Test Automation

Ansible-based tool for testing upstream KServe pull requests locally. Fetches a PR into an isolated sandbox, runs a security scan, builds container images, deploys KServe to a local cluster, and sets up predefined models for testing.

## Prerequisites

- Ansible 2.14+ (see [Installing Ansible](#installing-ansible) below)
- [GitHub CLI](https://cli.github.com/) (`gh`) - authenticated with `gh auth login`
- Container engine: [Docker](https://www.docker.com/) or [Podman](https://podman.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- At least one cluster tool:
  - [Kind](https://kind.sigs.k8s.io/) (default, recommended)
  - [Minikube](https://minikube.sigs.k8s.io/)
  - [CRC](https://developers.redhat.com/products/openshift-local/overview) (OpenShift Local)
  - Access to an OpenShift cluster

### Installing Ansible

#### macOS

Using Homebrew (recommended):

```bash
brew install ansible
```

Or with pip:

```bash
python3 -m pip install --user ansible
```

If you use pip, make sure `~/.local/bin` is in your `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

#### Linux (Debian / Ubuntu)

```bash
sudo apt update
sudo apt install -y software-properties-common
sudo add-apt-repository --yes --update ppa:ansible/ansible
sudo apt install -y ansible
```

Or with pip (works on any distro):

```bash
python3 -m pip install --user ansible
```

#### Linux (Fedora / RHEL / CentOS)

```bash
sudo dnf install -y ansible-core
```

#### Verify installation

```bash
ansible --version
# Should show ansible [core 2.14+]
```

## Quick Start

```bash
cd tools/pr-tester

# Deploy a PR to a local Kind cluster
./pr-test.sh deploy https://github.com/kserve/kserve/pull/1234

# Or set up a minikube cluster first, then deploy
./pr-test.sh setup-minikube
./pr-test.sh deploy https://github.com/kserve/kserve/pull/1234 --cluster minikube

# When done, clean up everything
./pr-test.sh cleanup 1234
```

## Usage

### Deploying a PR

Using the wrapper script:

```bash
./pr-test.sh deploy <PR_URL> [OPTIONS]
```

Or directly with ansible-playbook:

```bash
ansible-playbook deploy-pr.yml -e pr_url=https://github.com/kserve/kserve/pull/1234
```

### Options

| Option | ansible-playbook flag | Default | Description |
|--------|----------------------|---------|-------------|
| `--cluster TYPE` | `-e cluster_type=TYPE` | `kind` | Target cluster: `kind`, `minikube`, `crc`, `openshift` |
| `--engine ENGINE` | `-e engine=ENGINE` | `docker` | Container engine for image builds: `docker`, `podman` |
| `--mode MODE` | `-e deployment_mode=MODE` | `raw` | Deploy mode: `raw` (standard), `serverless` (Knative) |
| `--skip-scan` | `-e skip_security_scan=true` | `false` | Skip security scan of PR diff |
| `--copilot` | `-e enable_copilot_review=true` | `false` | Post a `@copilot` review request comment on the GitHub PR (requires Copilot code review enabled on the repo) |
| `--canary` | `-e deploy_canary_model=true` | `false` | Deploy the canary example InferenceService (sklearn with multiple canary revisions) |
| `--models LIST` | `-e 'models_to_deploy=[...]'` | `sklearn-iris` | Models to deploy |

### Examples

```bash
# Deploy on minikube with podman
./pr-test.sh deploy https://github.com/kserve/kserve/pull/1234 --cluster minikube --engine podman

# Deploy with multiple models
./pr-test.sh deploy https://github.com/kserve/kserve/pull/1234 --models sklearn-iris,xgboost-iris

# Deploy to existing OpenShift cluster
./pr-test.sh deploy https://github.com/kserve/kserve/pull/1234 --cluster openshift

# Deploy with canary InferenceService (multi-revision traffic split)
./pr-test.sh deploy https://github.com/kserve/kserve/pull/1234 --canary

# Skip security scan (for trusted PRs)
./pr-test.sh deploy https://github.com/kserve/kserve/pull/1234 --skip-scan

# Cleanup but keep the cluster
./pr-test.sh cleanup 1234 --keep-cluster
```

## Pipeline Flow

When you run `./pr-test.sh deploy <PR_URL>`, the automation executes 9 stages in sequence. Each stage is an Ansible role, and each one feeds facts/variables into the next.

```
PR URL
 -> pr_fetch       -> pr_analyze     -> security_scan (gate)
 -> image_build    -> cluster_prepare -> image_import
 -> kserve_deploy  -> models_deploy   -> validate
```

### 1. PR Fetch

Parses the PR URL, creates an isolated sandbox, clones the repo, and checks out the PR branch.

- Validates the URL format (`https://github.com/OWNER/REPO/pull/NUMBER`)
- Verifies the `gh` CLI is installed and authenticated
- Clones the repository into `/tmp/kserve-pr-sandbox/pr-<NUMBER>-<TIMESTAMP>/`
- Runs `gh pr checkout` to get the PR branch
- Resolves the base branch (e.g. `master` or `main`) and fetches it for diff comparison
- Optionally posts a `@copilot review this PR for security and correctness` comment on the GitHub PR via `gh pr review --comment` (if `--copilot` is passed). This triggers GitHub Copilot's asynchronous code review on the remote PR — it is **not** a local review. Requires the repository to have GitHub Copilot code review enabled.

**Produces:** `source_dir`, `pr_number`, `pr_base_branch`, `pr_image_tag`

### 2. PR Analyze

Determines what to build, deploy, and test based on which files the PR changes.

- Runs `git diff --name-only` against the base branch to get the list of changed files
- Matches each file path against component detection rules (regex patterns mapped to KServe subsystems)
- Sets the install types (e.g. `kserve`, `llmisvc`, `localmodel`), images to build, and test models
- Falls back to `kserve` if no specific component is detected
- Skipped entirely when `--no-auto-detect` is passed (uses manual config instead)

See [Auto-detection](#auto-detection) below for the full mapping table.

**Produces:** `kserve_install_types`, `images_to_build`, `models_to_deploy`

### 3. Security Scan

Static analysis gate that scans the PR diff for suspicious patterns before building anything.

- Runs `scripts/security-scan.sh` against the diff between the PR and base branch
- Checks for: base64 blobs (with `+`/`/`/`=`), AWS credentials, hardcoded secrets/tokens, private keys, shell injection (`eval`, `curl|sh`), binary files, cryptocurrency addresses, and LLM prompt injection patterns
- **Fails the pipeline** if any findings are detected (review output and re-run with `--skip-scan` if benign)
- Skipped when `--skip-scan` is passed

### 4. Image Build

Builds container images from the PR source code using docker or podman.

- Auto-detects the container engine if set to `auto` (prefers docker, falls back to podman)
- Builds each image in `images_to_build` from its mapped Dockerfile and context directory
- Tags images with the PR-specific tag (e.g. `kserve-controller:pr-1234`)
- Timeout controlled by `image_build_timeout` (default: 30 minutes)

**Produces:** `built_images` (list of `image:tag` strings)

### 5. Cluster Prepare

Provisions or connects to the target Kubernetes cluster.

- **Kind** (default): creates a Kind cluster with a local Docker registry, configures containerd to mirror it
- **Minikube**: installs/upgrades minikube, starts the cluster with addons (dashboard, registry), optionally enables CSI hostpath driver and NFS provisioner
- **CRC**: starts CodeReady Containers, logs in, exposes the internal registry
- **OpenShift**: verifies `oc` connectivity, resolves the registry host
- Verifies cluster connectivity with `kubectl get nodes`

**Produces:** `ko_docker_repo` (registry URL for image deployment), `cluster_ready`

### 6. Image Import

Loads the built images into the cluster's registry so deployments can pull them.

- **Kind**: `docker tag` + `docker push` to `localhost:<registry_port>`
- **Minikube**: `minikube image load`
- **CRC / OpenShift**: `docker login` to internal registry, tag, and push

**Produces:** `imported_images` (cluster-registry-qualified references)

### 7. KServe Deploy

Installs KServe controllers and dependencies into the cluster.

- For Kind with all components: uses `make deploy-dev` for a full development deployment
- Otherwise: uses `hack/kserve-install.sh --type <types>` to install only the needed controllers
- Installs infrastructure dependencies based on detected components (cert-manager for core, Gateway API + LWS + Envoy Gateway for LLMISvc)
- On OpenShift/CRC: patches controller deployments to use the PR-built images
- Waits for each controller pod to reach Ready state

### 8. Models Deploy

Creates test workloads to verify the deployed KServe controllers are functioning.

- Creates the test namespace (`kserve-pr-test`)
- Deploys each model in `models_to_deploy` using Jinja2-rendered YAML templates
- Uses `InferenceService` for core KServe models (sklearn, xgboost, lightgbm)
- Uses `LLMInferenceService` for LLM models (opt-125m)
- Waits for each resource to reach `Ready` condition (timeout: `isvc_ready_timeout`, default 5 minutes)

### 9. Validate

Post-deployment verification and summary.

- Checks controller pod health for each installed component
- Lists InferenceService and/or LLMInferenceService resources and their status
- Optionally runs inference smoke tests (port-forward + HTTP POST to prediction endpoint)
- Prints a summary with resource status and cleanup instructions

## Auto-detection

When `auto_detect_components` is `true` (the default), the `pr_analyze` role scans the PR diff to determine which KServe subsystems are affected and automatically configures:

- **`kserve_install_types`** - which controller types to install (`kserve`, `llmisvc`, `localmodel`)
- **`images_to_build`** - which container images to build
- **`models_to_deploy`** - which test models/workloads to apply

| PR changes files in... | Detected component | Installs | Builds | Deploys |
|-------------------------|-------------------|----------|--------|---------|
| `cmd/manager`, `pkg/controller/v1beta1`, core config | kserve | KServe controller + deps | controller, agent, router, storage-init | sklearn-iris ISVC |
| `cmd/llmisvc`, `pkg/controller/v1alpha2/llmisvc`, llmisvc config | llmisvc | LLMISvc controller + Gateway API + LWS + Envoy Gateway | llmisvc-controller, storage-init | opt-125m LLMInferenceService |
| `cmd/localmodel*`, `pkg/controller/v1alpha1/localmodel*` | localmodel | KServe + LocalModel controllers | controller, localmodel-controller, localmodel-agent, storage-init | sklearn-iris ISVC |
| `python/sklearnserver` | runtime_sklearn | KServe controller | controller, sklearn, storage-init | sklearn-iris ISVC |
| `python/xgbserver` | runtime_xgboost | KServe controller | controller, xgboost, storage-init | xgboost-iris ISVC |
| `python/huggingfaceserver` | runtime_huggingface | KServe controller | controller, huggingface-cpu, storage-init | sklearn-iris ISVC |
| `cmd/agent`, `pkg/agent` | agent | KServe controller | controller, agent, storage-init | sklearn-iris ISVC |
| `python/kserve/` (SDK) | python_sdk | KServe controller | controller, storage-init | sklearn-iris ISVC |

PRs touching multiple components (e.g. both core ISVC and LLMISvc code) will install the union of all required infrastructure.

To disable auto-detection and use manual configuration:

```bash
./pr-test.sh deploy https://github.com/kserve/kserve/pull/1234 --no-auto-detect
# or
ansible-playbook deploy-pr.yml -e pr_url=... -e auto_detect_components=false
```

## Test Models

Predefined models that the playbook deploys to validate that KServe is working after the PR is applied. Auto-detection picks the right ones based on the PR diff, or you can choose manually with `--models`.

| Model key | Kind | Runtime | Model source | Protocol |
|-----------|------|---------|--------------|----------|
| `sklearn-iris` | InferenceService | scikit-learn | `gs://kfserving-examples/models/sklearn/1.0/model` | v1 |
| `xgboost-iris` | InferenceService | XGBoost | `gs://kfserving-examples/models/xgboost/iris` | v1 |
| `lightgbm-iris` | InferenceService | LightGBM | `gs://kfserving-examples/models/lgb/iris` | v1 |
| `llmisvc-opt-125m` | LLMInferenceService | vLLM (CPU) | `hf://facebook/opt-125m` | OpenAI-compatible |

## Available Images

Build targets you can add to `images_to_build`:

| Name | Component |
|------|-----------|
| `controller` | KServe controller manager |
| `agent` | Inference agent sidecar |
| `router` | Inference router |
| `storage-initializer` | Model storage init container |
| `llmisvc-controller` | LLM InferenceService controller |
| `localmodel-controller` | LocalModel controller |
| `localmodel-agent` | LocalModel node agent |
| `sklearn` | scikit-learn serving runtime |
| `xgboost` | XGBoost serving runtime |
| `huggingface-cpu` | HuggingFace serving runtime (CPU) |

## Minikube Setup

A standalone playbook to install/upgrade minikube to the latest release, start a cluster with dashboard and registry, and optionally deploy [JooHo's NFS Provisioner Operator](https://github.com/Jooho/nfs-provisioner-operator) for a dynamic `nfs` StorageClass with ReadWriteMany support.

> **Note:** Minikube is installed into the local `bin/` directory next to the playbooks (no `sudo` required). The `pr-test.sh` wrapper adds this directory to `PATH` automatically. When using `ansible-playbook` directly, the playbook handles the path internally.

The container driver (`docker` or `podman`) is **auto-detected**. If an existing minikube cluster already exists, the playbook reuses its driver to avoid `GUEST_DRIVER_MISMATCH` errors. To force a specific driver, pass `--driver docker` or `--driver podman` (you may need to `minikube delete` first if switching).

The playbook always checks the [latest minikube release](https://github.com/kubernetes/minikube/releases/latest) from GitHub and upgrades if a newer version is available. This can be disabled with `--minikube_auto_upgrade=false`.

### Using the wrapper script

```bash
# Basic setup: latest minikube + dashboard + registry
./pr-test.sh setup-minikube

# Custom resources
./pr-test.sh setup-minikube --cpus 6 --memory 16384

# Force a specific driver
./pr-test.sh setup-minikube --driver podman

# With CSI hostpath driver for block device PVCs
./pr-test.sh setup-minikube --csi-hostpath

# With NFS Provisioner for RWX storage
./pr-test.sh setup-minikube --nfs

# Combine options
./pr-test.sh setup-minikube --cpus 8 --memory 32768 --driver podman --csi-hostpath --nfs
```

### Using ansible-playbook directly

```bash
cd tools/pr-tester

# Basic setup: latest minikube + dashboard + registry
ansible-playbook setup-minikube.yml

# Custom resources and driver
ansible-playbook setup-minikube.yml \
  -e minikube_cpus=6 \
  -e minikube_memory=16384 \
  -e minikube_driver=podman

# With CSI hostpath driver for block device PVCs
ansible-playbook setup-minikube.yml -e enable_csi_hostpath=true

# With NFS Provisioner for RWX storage
ansible-playbook setup-minikube.yml -e enable_nfs_provisioner=true

# Pin a specific Kubernetes version
ansible-playbook setup-minikube.yml -e minikube_kubernetes_version=v1.32.0

# Skip minikube auto-upgrade (use whatever is installed)
ansible-playbook setup-minikube.yml -e minikube_auto_upgrade=false

# Full example: custom resources + CSI + NFS + specific K8s version
ansible-playbook setup-minikube.yml \
  -e minikube_cpus=8 \
  -e minikube_memory=32768 \
  -e enable_csi_hostpath=true \
  -e enable_nfs_provisioner=true \
  -e minikube_kubernetes_version=v1.32.0
```

### Minikube setup options

| pr-test.sh flag | ansible-playbook flag | Default | Description |
|-----------------|----------------------|---------|-------------|
| `--cpus N` | `-e minikube_cpus=N` | `4` | Number of CPUs |
| `--memory N` | `-e minikube_memory=N` | `8192` | Memory in MB |
| `--driver DRIVER` | `-e minikube_driver=DRIVER` | `auto` | Container driver: `docker`, `podman`, or `auto` |
| `--csi-hostpath` | `-e enable_csi_hostpath=true` | `false` | Enable CSI hostpath driver (`csi-hostpath-sc` StorageClass, block volume mode) |
| `--nfs` | `-e enable_nfs_provisioner=true` | `false` | Deploy NFS Provisioner Operator for RWX storage |
| — | `-e minikube_kubernetes_version=VER` | latest | Pin a specific Kubernetes version |
| — | `-e minikube_auto_upgrade=false` | `true` | Skip minikube binary upgrade |

### Cleanup minikube

```bash
# Using the wrapper script
./pr-test.sh cleanup-minikube

# Using ansible-playbook directly
ansible-playbook cleanup-minikube.yml

# Also explicitly remove the NFS operator resources before deleting
ansible-playbook cleanup-minikube.yml -e remove_nfs_operator=true
```

## Transformer Deployment

A standalone playbook to deploy an InferenceService with a custom **transformer** in front of an [ODH MLServer](https://github.com/opendatahub-io/MLServer) predictor. Uses the [sentiment_transformer](https://github.com/brettmthompson/sentiment_transformer) resources: an ONNX sentiment-analysis model from HuggingFace with a transformer that tokenizes text input and returns sentiment predictions.

The playbook creates:
- A namespace-scoped **MLServer ServingRuntime** (`quay.io/opendatahub/mlserver:odh-v3.4`) with ONNX, sklearn, xgboost, and lightgbm support
- An **InferenceService** with a predictor (ONNX model via `hf://`) and a sentiment transformer container

> **Prerequisites:** KServe must be installed on the target cluster. Use `setup-minikube` + `deploy` first, or install KServe manually.

### Usage

```bash
# Using the wrapper script
./pr-test.sh deploy-transformer

# Using ansible-playbook directly
ansible-playbook deploy-transformer.yml

# With a custom model URI (e.g. from S3)
ansible-playbook deploy-transformer.yml \
  -e model_storage_uri=s3://my-bucket/sentiment-analysis/

# Custom namespace
ansible-playbook deploy-transformer.yml -e transformer_namespace=my-test-ns

# Cleanup
./pr-test.sh cleanup-transformer
ansible-playbook deploy-transformer.yml -e cleanup=true
```

### Transformer options

| pr-test.sh flag | ansible-playbook flag | Default | Description |
|-----------------|----------------------|---------|-------------|
| `--model-uri URI` | `-e model_storage_uri=URI` | `hf://optimum/distilbert-base-uncased-finetuned-sst-2-english` | Model storageUri |
| `--namespace NS` | `-e transformer_namespace=NS` | `kserve-transformer-test` | Namespace for deployment |
| `--transformer-image IMG` | `-e transformer_image=IMG` | ODH sentiment transformer (digest-pinned) | Transformer container image |
| `--mlserver-image IMG` | `-e mlserver_image=IMG` | `quay.io/opendatahub/mlserver:odh-v3.4` | MLServer runtime image |
| `--autoscaler TYPE` | `-e autoscaler=TYPE` | `none` | Autoscaler for the transformer: `none`, `hpa`, `keda` |
| `--min-replicas N` | `-e transformer_min_replicas=N` | `1` | Transformer min replicas (requires `--autoscaler`) |
| `--max-replicas N` | `-e transformer_max_replicas=N` | `5` | Transformer max replicas (requires `--autoscaler`) |
| `--cpu-target N` | `-e autoscale_cpu_target=N` | `50` | CPU utilization % target for autoscaling |

## Using playbooks directly

All playbooks can be run standalone with `ansible-playbook` — no wrapper script needed. Run from the `tools/pr-tester/` directory.

### Deploy a PR

```bash
cd tools/pr-tester

# Basic deploy (Kind cluster)
ansible-playbook deploy-pr.yml -e pr_url=https://github.com/kserve/kserve/pull/1234

# Deploy on minikube with podman, serverless mode
ansible-playbook deploy-pr.yml \
  -e pr_url=https://github.com/kserve/kserve/pull/1234 \
  -e cluster_type=minikube \
  -e engine=podman \
  -e deployment_mode=serverless

# Deploy with multiple models, skip security scan
ansible-playbook deploy-pr.yml \
  -e pr_url=https://github.com/kserve/kserve/pull/1234 \
  -e 'models_to_deploy=["sklearn-iris","xgboost-iris"]' \
  -e skip_security_scan=true

# Disable auto-detection and manually control what gets built
ansible-playbook deploy-pr.yml \
  -e pr_url=https://github.com/kserve/kserve/pull/1234 \
  -e auto_detect_components=false \
  -e 'images_to_build=["controller","agent"]' \
  -e 'kserve_install_types=["kserve"]'
```

### Cleanup a PR deployment

```bash
# Full cleanup: delete resources, destroy cluster, remove sandbox
ansible-playbook cleanup.yml -e pr_number=1234

# Cleanup but keep the cluster running
ansible-playbook cleanup.yml -e pr_number=1234 -e destroy_cluster=false

# Cleanup a minikube-based deployment
ansible-playbook cleanup.yml -e pr_number=1234 -e cluster_type=minikube
```

## Configuration

All defaults are in `group_vars/all.yml`. Override any variable with `-e` on the command line or by editing the file.

## Troubleshooting

**Security scan false positives**: The scan uses pattern matching and may flag legitimate code. Review the output and re-run with `--skip-scan` if the findings are benign.

**Image build failures**: Ensure your container engine has enough resources. For Docker Desktop, allocate at least 4 CPUs and 8GB RAM.

**Kind cluster issues**: If the Kind cluster fails to create, try deleting stale resources first:

```bash
kind delete cluster --name kserve-pr-test
docker rm -f kind-registry
```

**GitHub auth**: The `gh` CLI must be authenticated. Run `gh auth login` and ensure `GH_TOKEN` or `GITHUB_TOKEN` is set in your environment.
