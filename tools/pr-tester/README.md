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

`PR_URL` can also be a GitLab merge request. The source is detected from the URL:

| URL | Source |
|-----|--------|
| `https://github.com/OWNER/REPO/pull/N` | GitHub pull request (needs the `gh` CLI) |
| `https://HOST/GROUP[/SUBGROUP...]/PROJECT/-/merge_requests/N` | GitLab merge request (any GitLab host) |

```bash
./pr-test.sh deploy https://gitlab.com/GROUP/PROJECT/-/merge_requests/42 --cluster minikube
```

GitLab access is anonymous by default. For private projects, export `GITLAB_TOKEN` (a personal or project access token with `read_api` and `read_repository`). The token is passed to `curl` and `git` without appearing in the process list, `.git/config` or the Ansible log. Both tools use the system trust store; if the GitLab CA is not in it, pass `-e gitlab_ca_path=/path/to/ca.pem`.

The GitLab path is read-only: it never comments on, approves or pushes to the MR. `--copilot` applies to GitHub only.

### Options

| Option | ansible-playbook flag | Default | Description |
|--------|----------------------|---------|-------------|
| `--cluster TYPE` | `-e cluster_type=TYPE` | `kind` | Target cluster: `kind`, `minikube`, `crc`, `openshift` |
| `--engine ENGINE` | `-e engine=ENGINE` | `docker` | Container engine for image builds: `docker`, `podman` |
| `--mode MODE` | `-e deployment_mode=MODE` | `raw` | Deploy mode: `raw` (standard), `serverless` (Knative) |
| `--skip-scan` | `-e skip_security_scan=true` | `false` | Skip security scan of PR diff |
| `--copilot` | `-e enable_copilot_review=true` | `false` | Post a `@copilot` review request comment on the GitHub PR (requires Copilot code review enabled on the repo) |
| `--canary` | `-e deploy_canary_model=true` | `false` | Deploy the canary example InferenceService (sklearn with multiple canary revisions) |
| `--models LIST` | `-e '{"models_to_deploy": [...]}'` | `sklearn-iris` | Models to deploy |
| `--ssrf-tests` | `-e run_ssrf_tests=true` | `false` | Run the HTTP(S) storageUri SSRF checks (see [SSRF checks](#ssrf-checks)) |
| `--localmodel-node-gc-tests` | `-e run_localmodel_node_gc_tests=true` | `false` | Run the LocalModelNode GC on node deletion checks (see [LocalModelNode GC checks](#localmodelnode-gc-checks)) |

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

### Live output

Long-running steps stream their output to the terminal while they run, indented under the Ansible task, instead of staying silent until the task ends:

- image builds (the full log is also kept in `build-<image>.log`), image loads and pushes
- `minikube start` and addons, `kind create cluster`, `crc start`
- `hack/kserve-install.sh`, `make deploy-dev`, controller image patches and rollouts, uninstall
- **workload readiness** (`scripts/watch-workload.sh`): while an InferenceService or LLMInferenceService becomes Ready, it shows not-ready conditions, pod and container states (init containers included), new events, and live logs of every container (`storage-initializer`, `kserve-container`, `agent`, ...). On timeout it prints the conditions and a `kubectl describe` tail of each pod.

Ansible runs tasks detached from the terminal, so `scripts/live-run.sh` and `scripts/watch-workload.sh` write to the terminal of the `ansible-playbook` process (override with `PR_TESTER_TTY=/dev/ttysNNN`). Without a terminal (CI) they fall back to captured output. Turn it off with `--no-live` (`-e live_output=false`).

## Pipeline Flow

When you run `./pr-test.sh deploy <PR_URL>`, the automation executes 9 stages in sequence. Each stage is an Ansible role, and each one feeds facts/variables into the next.

```
PR URL
 -> pr_fetch       -> pr_analyze     -> security_scan (gate)
 -> image_build    -> cluster_prepare -> image_import
 -> kserve_deploy  -> models_deploy   -> validate
```

### 1. PR Fetch

Parses the PR URL, creates an isolated sandbox, and fetches only two commits: the current base branch and the PR head, each at depth 1 (no history). The changed files and the diff come from the GitHub/GitLab API and are saved as `changed-files.txt` and `change.diff` in the sandbox. `pr_fetch` detects the source from the URL and either runs its GitHub tasks or hands off to the `gitlab_mr_fetch` role.

**GitLab merge requests** (`gitlab_mr_fetch`):

- Reads the target branch, head SHA and state from the GitLab API
- Clones the target branch at depth 1 into `/tmp/kserve-pr-sandbox/mr-<NUMBER>-<TIMESTAMP>/` and checks out `refs/merge-requests/<NUMBER>/head` at depth 1, which also covers MRs from forks
- Gets the changed files and diff from the MR changes API
- Warns when the MR is not open or moved after the API call
- Tags images `mr-<NUMBER>`

**GitHub pull requests:**

- Validates the URL format (`https://github.com/OWNER/REPO/pull/NUMBER`)
- Verifies the `gh` CLI is installed and authenticated
- Resolves the base branch (e.g. `master` or `main`) and clones it at depth 1 into `/tmp/kserve-pr-sandbox/pr-<NUMBER>-<TIMESTAMP>/`
- Fetches `refs/pull/<NUMBER>/head` at depth 1 and checks it out (works for fork PRs too)
- Gets the changed files and diff with `gh pr diff`
- Optionally posts a `@copilot review this PR for security and correctness` comment on the GitHub PR via `gh pr review --comment` (if `--copilot` is passed). This triggers GitHub Copilot's asynchronous code review on the remote PR — it is **not** a local review. Requires the repository to have GitHub Copilot code review enabled.

**Produces:** `pr_source` (`github` or `gitlab`), `source_dir`, `pr_number`, `pr_base_branch`, `pr_image_tag`, `pr_head_sha`, `pr_changed_files`, `pr_diff_file`; GitLab also sets `pr_title`, `pr_web_url`

### 2. PR Analyze

Determines what to build, deploy, and test based on which files the PR changes.

- Uses the changed files from `pr_fetch` (GitHub/GitLab API)
- Matches each file path against component detection rules (regex patterns mapped to KServe subsystems)
- Sets the install types (e.g. `kserve`, `llmisvc`, `localmodel`), images to build, and test models
- Falls back to `kserve` if no specific component is detected
- Skipped entirely when `--no-auto-detect` is passed (uses manual config instead)

See [Auto-detection](#auto-detection) below for the full mapping table.

**Produces:** `kserve_install_types`, `images_to_build`, `models_to_deploy`

### 3. Security Scan

Static analysis gate that scans the PR diff for suspicious patterns before building anything.

- Runs `scripts/security-scan.sh` on the PR's diff from the GitHub/GitLab API (`change.diff`)
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
- Patches controller deployments to use the PR-built images
- Points the agent, router and storage-initializer entries in `inferenceservice-config`, and the `default` ClusterStorageContainer, at the PR-built images. The controller reads these images from there, not from environment variables. The ClusterStorageContainer decides the storage-initializer image for `gs://`, `s3://`, `hf://` and `http(s)://` URIs.
- Prints the effective sidecar and storage-initializer images
- Waits for each controller pod to reach Ready state

### 8. Models Deploy

Creates test workloads to verify the deployed KServe controllers are functioning.

- Creates the test namespace (`kserve-pr-test`)
- Deploys each model in `models_to_deploy` using Jinja2-rendered YAML templates
- Uses `InferenceService` for core KServe models (sklearn, xgboost, lightgbm)
- Uses `LLMInferenceService` for LLM models (opt-125m)
- Waits for each resource to reach `Ready` condition (timeout: `isvc_ready_timeout`, default 5 minutes)
- For multi-model InferenceServices (`sklearn-mms`), then deploys their `TrainedModel`s and waits until the predictor reports each one ready

#### Reusable TrainedModel task

`roles/models_deploy/tasks/deploy_trained_model.yml` deploys one TrainedModel and can be called from any role or play:

```yaml
- ansible.builtin.include_role:
    name: models_deploy
    tasks_from: deploy_trained_model.yml
  vars:
    trained_model:
      name: my-model            # required
      isvc: sklearn-mms         # required, a multi-model InferenceService
      storage_uri: gs://...     # required
      framework: sklearn        # default sklearn
      memory: 128Mi             # default 128Mi
      labels: {team: x}         # extra labels
      wait: true                # wait until the predictor reports it ready
      dry_run: false            # server-side dry run (admission only)
      allow_failure: false      # record the outcome instead of failing
```

It sets `trained_model_result` (`applied`, `ready`, `rc`, `stderr`, `status`). Readiness is read from the predictor's `/v1/models/<name>` endpoint through the API server's service proxy, so no port-forward is needed (raw deployment mode).

### 9. Validate

Post-deployment verification and summary.

- Checks controller pod health for each installed component
- Lists InferenceService and/or LLMInferenceService resources and their status
- Optionally runs inference smoke tests (port-forward + HTTP POST to prediction endpoint)
- Optionally runs the [SSRF checks](#ssrf-checks) (`--ssrf-tests`)
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
| `cmd/agent`, `pkg/agent` | agent | KServe controller | controller, agent, storage-init | sklearn-iris ISVC, sklearn-mms ISVC + TrainedModels |
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
| `sklearn-mms` | InferenceService + TrainedModels | scikit-learn, agent model puller | `mms_trained_models` (default one TrainedModel from `gs://kfserving-examples/models/sklearn/1.0/model`) | v1 |

`sklearn-mms` has no `storageUri`, so KServe treats it as a multi-model predictor and injects the agent sidecar with its model puller. Override its TrainedModels with JSON extra vars:

```bash
ansible-playbook deploy-pr.yml -e pr_url=... -e '{"models_to_deploy": ["sklearn-mms"]}' \
  -e '{"mms_trained_models": [{"name": "m1", "storage_uri": "gs://..."}, {"name": "m2", "storage_uri": "https://..."}]}'
```

## SSRF checks

`--ssrf-tests` (`-e run_ssrf_tests=true`) checks the HTTP(S) `storageUri` SSRF protections in the admission webhook, the Python storage-initializer and the Go agent puller. Every check runs; the summary lists PASS / FAIL / INFO and the play fails if any check failed.

| # | Check | Expected |
|---|-------|----------|
| – | storage-initializer and agent images in use are the PR build | precheck |
| 1–2 | Dry-run create with blocked hosts/IPs in `storageUri` and `storageUris` (loopback, metadata, private, `.svc`, dword/octal, IPv6) | rejected |
| 3 | Dry-run create with public HTTPS, Azure Blob and `gs://` | admitted |
| 4 | Dry-run update of an existing ISVC to a blocked URI | rejected |
| 5 | `<ClusterIP>.nip.io` (passes admission, which does not resolve DNS) pointing at an in-cluster listener | storage-initializer refuses; the listener receives nothing |
| 6 | Public URL redirecting to `169.254.169.254` | storage-initializer refuses |
| 7 | Public HTTPS model | downloads and becomes Ready (regression check for the pinned-IP TLS path) |
| 8 | TrainedModel dry-run with a blocked URI | INFO: upstream has no TrainedModel HTTP check, so the agent is the only guard |
| 9–11 | TrainedModels with a literal ClusterIP, `<ClusterIP>.nip.io` and the metadata redirect | agent refuses |
| 12 | TrainedModel with a public HTTPS model | agent downloads it and the predictor serves it |

Checks 8–12 reuse `sklearn-mms` (deployed if the run did not already include it) and the shared TrainedModel task. Tunables live in `roles/validate/defaults/main.yml` (`ssrf_blocked_uris`, `ssrf_allowed_uris`, `ssrf_redirect_uri`, `ssrf_public_https_model_uri`, `ssrf_test_storage_uris`, `ssrf_test_agent`, `ssrf_cleanup`, ...).

Checks 5, 6 and 9–11 need public DNS (`nip.io`) and egress from the cluster; check 6 and 11 call `httpbin.org` (set `-e ssrf_redirect_uri=""` to skip). If DNS fails inside the pod, check 5 reports INCONCLUSIVE instead of passing.

## LocalModelNode GC checks

Checks that deleting a Kubernetes node removes its `LocalModelNode` and the download Jobs it owns, and leaves other nodes' `LocalModelNode`s alone ([kserve#6159](https://github.com/kserve/kserve/issues/6159)). They run only when requested with `--localmodel-node-gc-tests` (`-e run_localmodel_node_gc_tests=true`), and only when the localmodel controller is installed, which `pr_analyze` does for PRs that touch LocalModel code.

```bash
./pr-test.sh deploy https://github.com/kserve/kserve/pull/1234 --cluster minikube --localmodel-node-gc-tests
```

The checks create **fake Node objects** (no kubelet), so they run on any cluster, including single-node minikube and shared OpenShift, without removing real nodes; the controller reacts to the Node object being deleted. The fake nodes are cordoned and tainted so real workloads never land on them. Each scenario uses two of them: `gone`, which is deleted, and `keep`, the negative control.

| Scenario | Setup |
|----------|-------|
| a | `LocalModelCache`, one node group selecting both nodes |
| b | `LocalModelCache` with two node groups; only the second selects the deleted node |
| c | `LocalModelNamespaceCache`, one node group selecting both nodes |

For each scenario, after the `gone` node's `LocalModelNode` appears, a Job controller-owned by it and bound to that node is created (its pod stays Pending, as in the issue). Then the node is deleted and the checks assert:

1. the deleted node's `LocalModelNode` is removed;
2. its Job is removed (Kubernetes garbage collection through the owner reference, the same reference real download Jobs carry);
3. the `keep` node's `LocalModelNode` is still there.

The fake nodes have no localmodel agent, so the agent never creates real download Jobs for them; the owned Job stands in for one. On a build without the fix, checks 1 and 2 fail in every scenario. Scenario b can pass on such a build only if some unrelated reconcile of that cache happens to run the cleanup.

Tunables in `roles/validate/defaults/main.yml`: `lmn_gc_timeout`, `lmn_gc_cleanup`, `lmn_gc_storage_class`, `lmn_gc_scenarios` (set `enabled: false` on one to skip it). Creating Node objects needs cluster-admin.

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
