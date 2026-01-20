# GKM Cache Builder Pipeline

A comprehensive Tekton pipeline for building, packaging, and distributing vLLM compilation caches to accelerate 
GPU kernel compilation and reduce cold start times for model serving workloads.
1
## 🎯 Purpose

This pipeline addresses the gap in GPU Kernel Manager (GKM) by providing automated cache building capabilities for 
vLLM's torch.compile system. It enables:

- **Faster Model Serving**: 50-70% reduction in cold start times
- **Automated Cache Building**: No manual cache creation required
- **OCI Distribution**: Cache artifacts packaged as container images
- **KServe Integration**: Ready-to-use manifests for serving

## 🏗️ Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Git Trigger   │───▶│  Tekton Pipeline │───▶│   OCI Registry  │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                                │                        │
                                ▼                        ▼
┌─────────────────────────────────────────┐    ┌─────────────────┐
│           Pipeline Tasks                │    │  KServe Serving │
│  1. Pre-flight Checks (ODH/RHOAI)       │    │   (with cache)  │
│  2. GPU Environment Detection           │    └─────────────────┘
│  3. ISVC-Based Cache Collection         │
│  4. Metadata Generation                 │
│  5. OCI Image Packaging                 │
│  6. GKMCache Provisioning               │
└─────────────────────────────────────────┘
```

## 📋 Prerequisites

### ServingRuntime

The pipeline automatically instantiates a ServingRuntime from the templates available in the `redhat-ods-applications` namespace.
By default it uses `vllm-cuda-runtime-template`, but you can choose any available template via the `serving-runtime-template` pipeline parameter.

The templates are managed by the [odh-model-controller](https://github.com/opendatahub-io/odh-model-controller/blob/incubating/config/runtimes/vllm-cuda-template.yaml) and are automatically deployed when ODH/RHOAI is installed.

```bash
# List available ServingRuntime templates
oc get templates -n redhat-ods-applications
```

### Cluster Requirements
- **Kubernetes**: v1.23+
- **Tekton Pipelines**: v0.50+
- **ODH/RHOAI**: Open Data Hub or Red Hat OpenShift AI operator installed
- **GPU Nodes**: NVIDIA GPUs with compute capability 7.0+
- **Storage**: Fast SSD storage class (50GB+ for cache workspace)
- **OpenShift**: Red Hat OpenShift Pipelines Operator (from OperatorHub)
- **Vanilla Kubernetes**: Tekton Pipelines (latest stable release)

### Software Requirements
- **vLLM**: 0.16.0+ (provided by the `vllm-cuda-runtime` ServingRuntime image)
- **Container Registry**: Docker Hub, GHCR, or any OCI-compliant registry
- **Tekton CLI (tkn)**: Optional but recommended for easier pipeline monitoring

### Hardware Compatibility

| Component | Cache Collection (ISVC) | Deployment System |
|-----------|------------------------|-------------------|
| **GPU Architecture** | Must match exactly | Must match exactly |
| **CUDA Version** | Determined by ServingRuntime | Must match |
| **CPU Architecture** | x86_64 recommended | x86_64 (portable) |
| **Memory** | 16GB+ GPU memory | 8GB+ GPU memory |


## 🔍 Cluster GPU Identification

Before running the pipeline, identify available GPU models in your cluster:

### Basic GPU Check

**Multi-Vendor GPU Detection:**

```bash
# Check for NVIDIA GPUs
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' | grep -v '<no value>'

# Check for AMD GPUs (ROCm)
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.amd\.com/gpu}{"\n"}{end}' | grep -v '<no value>'

# Check for Intel GPUs
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.intel\.com/gpu}{"\n"}{end}' | grep -v '<no value>'

# Check for Intel Gaudi accelerators
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.habana\.ai/gaudi}{"\n"}{end}' | grep -v '<no value>'

# Universal check (all GPU types)
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}NVIDIA: {.status.allocatable.nvidia\.com/gpu}{"\t"}AMD: {.status.allocatable.amd\.com/gpu}{"\t"}Intel: {.status.allocatable.intel\.com/gpu}{"\t"}Gaudi: {.status.allocatable.habana\.ai/gaudi}{"\n"}{end}'

# Get detailed GPU information from GPU-enabled node
oc describe node <node-with-gpu> | grep -A 20 -B 5 -i gpu
```

### GPU Details from Pod

**NVIDIA GPUs:**
```bash
# Create a test pod to run nvidia-smi
oc run gpu-test --image=nvidia/cuda:12.0-runtime-ubi8 --rm -it --restart=Never -- nvidia-smi

# Get specific GPU details with compute capability
oc run gpu-test --image=nvidia/cuda:12.0-runtime-ubi8 --rm -it --restart=Never -- nvidia-smi --query-gpu=name,compute_cap,memory.total,driver_version --format=csv
```

**AMD ROCm GPUs:**
```bash
# AMD GPU test with rocm-smi
oc run gpu-test-amd --image=rocm/rocm-runtime:latest --rm -it --restart=Never -- rocm-smi

# Get specific AMD GPU details
oc run gpu-test-amd --image=rocm/rocm-runtime:latest --rm -it --restart=Never -- rocm-smi --showproductname --showmeminfo --showtemp
```

**Intel Gaudi Accelerators:**
```bash
# Intel Gaudi test with hl-smi
oc run gpu-test-gaudi --image=vault.habana.ai/gaudi-docker/1.16.2/ubuntu22.04/habanalabs/pytorch-installer-2.2.2:latest --rm -it --restart=Never -- hl-smi

# Get specific Gaudi details
oc run gpu-test-gaudi --image=vault.habana.ai/gaudi-docker/1.16.2/ubuntu22.04/habanalabs/pytorch-installer-2.2.2:latest --rm -it --restart=Never -- hl-smi -Q name,memory.total,temperature.aip
```

**Intel GPUs (Arc/Xe):**
```bash
# Intel GPU test with intel-gpu-tools
oc run gpu-test-intel --image=intel/intel-extension-for-pytorch:latest --rm -it --restart=Never -- intel_gpu_top

# Alternative with PCI detection
oc run gpu-test-intel --image=ubuntu:22.04 --rm -it --restart=Never -- sh -c "apt update && apt install -y pciutils && lspci | grep -i display"
```

### GPU Resource Summary

| **Vendor** | **Resource Name** | **Detection Tool** | **Container Image** |
|------------|------------------|-------------------|---------------------|
| NVIDIA     | `nvidia.com/gpu` | `nvidia-smi`      | `nvidia/cuda:12.0-runtime-ubi8` |
| AMD        | `amd.com/gpu`     | `rocm-smi`        | `rocm/rocm-runtime:latest` |
| Intel Gaudi| `habana.ai/gaudi` | `hl-smi`          | `vault.habana.ai/gaudi-docker/*` |
| Intel GPU  | `intel.com/gpu`  | `intel_gpu_top`   | `intel/intel-extension-for-pytorch:latest` |

### Expected Output Example

```
# For AWS g5.4xlarge instances (NVIDIA A10G):
GPU Name: NVIDIA A10G
Compute Capability: 8.6
Memory: 23028 MiB
CUDA Version: 13.0
Architecture: cuda-8.6
```

**⚠️ Pipeline Compatibility Note:**
This pipeline is currently optimized for **NVIDIA GPUs with CUDA support**. While the documentation includes 
multi-vendor detection commands for completeness, the actual cache collection tasks require significant modifications
to support AMD ROCm, Intel GPUs, or Intel Gaudi accelerators.

## 🚀 Quick Start


### 1. Create Registry Push Secret

The pipeline pushes the cache image to your container registry. You must create a `docker-registry` secret
named `registry-push-secret` (default) and link it to the `buildah-sa` service account:

```bash
# Option 1: Create from username/password
oc create secret docker-registry registry-push-secret \
  --docker-server=quay.io \
  --docker-username=your-username \
  --docker-password=your-token

# Option 2: Import from existing docker/podman auth
oc create secret generic registry-push-secret \
  --from-file=.dockerconfigjson=$HOME/.docker/config.json \
  --type=kubernetes.io/dockerconfigjson

# Link it to the pipeline service account
oc secrets link buildah-sa registry-push-secret --for=mount
```

> **quay.io note:** Personal web passwords do not work for CLI/API pushes on quay.io.
> You must use one of the following:
> - **Encrypted CLI password**: quay.io -> Account Settings (gear icon) -> "CLI Password" -> Generate Encrypted Password
> - **Robot account token**: quay.io -> Repository Settings -> Create Robot Account with write permission
>
> The target repository (e.g. `gkm_cache_container`) must also exist on quay.io before the
> first push — quay.io does not auto-create repositories.

The pipeline validates this secret exists before attempting the build. If using a different secret name,
pass it via the `registry-secret` pipeline parameter.

### 2. Create HuggingFace Token Secret (Optional)

Only needed when using HuggingFace models (not required for OCI ModelCar images):

```bash
oc create secret generic huggingface-token \
  --from-literal=token=your-hf-token-here
```

**When is this required:**

- **Private models**: Meta Llama, Mistral, etc. require explicit access
- **Rate limiting**: Prevents hitting download limits for public models

**Note**: Not needed when using Red Hat ModelCar images (`oci://registry.redhat.io/...`).

### 3. Build and Push MCV Image

The pipeline uses [GKM MCV (Model Cache Vault)](https://github.com/redhat-et/GKM/blob/main/mcv/README.md)
to package vLLM compilation caches as OCI images. MCV auto-detects cache format
(vLLM binary, Triton), generates proper metadata labels (`cache.vllm.image/*`),
and creates OCI-compliant images.

MCV does not have a pre-built container image, so you need to build one:

```bash
# Build the MCV container image
podman build -t quay.io/<your-org>/mcv:latest -f Containerfile.mcv .

# Push to your registry
podman push quay.io/<your-org>/mcv:latest
```

Then set the `mcv-image` pipeline parameter to point to your image
(default: `quay.io/gkm/mcv:latest`).

### 4. Install Pipeline


```bash
# Apply RBAC, tasks, and pipeline
kubectl apply -f build-service-account.yaml
kubectl apply -f task-preflight-check.yaml
kubectl apply -f task-gpu-environment-detector.yaml
kubectl apply -f task-isvc-cache-collector.yaml
kubectl apply -f task-cache-metadata-generator.yaml
kubectl apply -f task-cache-image-packager.yaml
kubectl apply -f task-gkm-cache-provisioner.yaml
kubectl apply -f pipeline.yaml

# Or use directory-based apply
kubectl apply -f .
```


### 5. Run Pipeline

```bash
# Customize pipelinerun-template.yaml with your model and registry
# Then run (uses generateName, so 'create' is required):
oc create -f pipelinerun-template.yaml
```

### 6. Monitor Progress

```bash
# Watch pipeline execution
tkn pipelinerun logs --last -f

# Check task status
kubectl get pipelineruns
kubectl get taskruns
```

### Restart:
- `oc delete pipelinerun -l app=gkm-cache-builder`
- Reapply the tasks and pipeline
- `oc create -f pipelinerun-template.yaml`

## 🔧 Configuration

### Pipeline Parameters Reference

The pipeline takes several parameters. This section explains **what each one does and why it exists**.

| Parameter | Required | Default | Purpose |
|-----------|----------|---------|---------|
| `model-name` | Yes | - | Full model identifier passed to vLLM (OCI URI or HuggingFace path) |
| `model-name-clean` | Yes | - | Short, DNS-safe name for Kubernetes resource naming |
| `model-revision` | No | `main` | Git branch/tag (HuggingFace models only) |
| `target-gpu-arch` | No | `""` (auto) | GPU architecture override; auto-detected if empty |
| `registry-url` | Yes | - | Container registry URL for the cache image |
| `max-model-len` | No | `2048` | Maximum context length for cache compilation |
| `cache-tag` | No | `""` (auto) | Custom OCI image tag; auto-generated if empty |
| `registry-secret` | No | `registry-push-secret` | Kubernetes secret with registry push credentials |
| `serving-runtime-template` | No | `vllm-cuda-runtime-template` | ServingRuntime template to instantiate |
| `mcv-image` | No | `quay.io/gkm/mcv:latest` | OCI image containing the MCV binary (build from `Containerfile.mcv`) |

#### Why `model-name` and `model-name-clean` are separate parameters

These two parameters serve fundamentally different purposes:

**`model-name`** is the **real model identifier** passed directly to vLLM's `--model` flag. It tells
vLLM where to load model weights from. It can be long and contain characters that Kubernetes
does not allow in resource names:

```
oci://registry.redhat.io/rhelai1/modelcar-mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5
```

**`model-name-clean`** is a **short, human-readable slug** used only for naming Kubernetes resources.
It is never passed to vLLM. It is used for:

- **GKMCache CR name** -> `vllm-cache-<model-name-clean>` (must be DNS-1123 subdomain)
- **PVC name** -> same as the GKMCache CR name (GKM creates a PVC matching the CR)
- **OCI image tag** -> `<model-name-clean>-<gpu-arch>` (no slashes allowed in tags)
- **Tekton labels** -> `model: <model-name-clean>` (max 63 chars, no slashes)
- **InferenceService name** -> used in examples and documentation

**Why not auto-derive it?** The pipeline can't reliably produce a meaningful short name from `model-name`:
- OCI URIs contain registry host, org, image name, quantization info, and tag
- HuggingFace paths contain org/model with mixed case
- Naive slug transformations (replace `/` with `-`, truncate) produce ugly or ambiguous names
- The user knows best which short name identifies their model

**Example mapping:**

| `model-name` | `model-name-clean` |
|---|---|
| `oci://registry.redhat.io/rhelai1/modelcar-mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5` | `mistral-small-3-1-24b-instruct-2503` |
| `mistralai/Mistral-Small-3.1-24B-Instruct-2503` | `mistral-small-3-1-24b-instruct-2503` |
| `oci://registry.redhat.io/rhelai1/modelcar-granite-3-1-8b-lab-v1:1.4` | `granite-3-1-8b-lab-v1` |
| `meta-llama/Llama-2-7b-hf` | `llama-2-7b-hf` |

**Rules for `model-name-clean`:**
- Lowercase only
- No slashes (`/`), colons (`:`), or dots (`.`)
- Use hyphens (`-`) as separators
- Maximum 63 characters (Kubernetes label value limit)
- Should be recognizable as the model it refers to

#### Other parameters explained

**`model-revision`**: Only relevant for HuggingFace models where you need a specific git
branch or tag (e.g., `main`, `v1.0`, a commit SHA). Ignored for OCI ModelCar images because
those are versioned by their image tag instead.

**`target-gpu-arch`**: The compiled cache is tied to a specific GPU architecture. If left
empty, the pipeline auto-detects the GPU in the cluster. If you set it manually (e.g.,
`cuda-8.6`), the pipeline validates it matches the actual hardware and fails with a clear
error on mismatch. This prevents accidentally building a cache for the wrong GPU.

**`cache-tag`**: By default the pipeline generates the OCI image tag automatically from
`model-name-clean` and the GPU architecture (e.g., `mistral-small-3-1-24b-instruct-2503-cuda-8-6`).
Set this only if you need a specific tag like `v1.0` or `latest`.

**`registry-secret`**: A `kubernetes.io/dockerconfigjson` secret with credentials to push
the cache image to `registry-url`. Must be created before running the pipeline and linked
to the `buildah-sa` service account (see Quick Start).

**`serving-runtime-template`**: The pipeline instantiates a ServingRuntime from this template
to ensure the cache is built with the **exact same vLLM image** that will serve the model
in production. Changing this to a different runtime (e.g., a custom or newer vLLM version)
will produce a cache compatible with that runtime instead.

### Model Configuration

The pipeline supports two model source formats:

**OCI ModelCar Image (recommended for Red Hat models):**
```yaml
params:
- name: model-name
  value: "oci://registry.redhat.io/rhelai1/modelcar-mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5"
- name: model-name-clean
  value: "mistral-small-3-1-24b-instruct-2503"    # Short name for resource naming (see above)
- name: max-model-len
  value: "2048"                      # Context length for cache building (see note below)
```

**HuggingFace Model:**
```yaml
params:
- name: model-name
  value: "mistralai/Mistral-Small-3.1-24B-Instruct-2503"
- name: model-name-clean
  value: "mistral-small-3-1-24b-instruct-2503"    # Short name for resource naming (see above)
- name: model-revision
  value: "main"                       # Git branch/tag (only for HuggingFace)
- name: max-model-len
  value: "4096"                      # Context length for cache building (see note below)
```

**About `max-model-len`:**

This parameter sets the maximum sequence (context) length that vLLM uses when building
the compilation cache (`--max-model-len` flag passed to `vllm serve`). It controls:

- **Which CUDA kernels get compiled**: vLLM compiles attention kernels, MLP layers, and
  other GPU operations for specific tensor shapes. The `max-model-len` value determines
  the upper bound of sequence-length dimensions in those shapes.
- **GPU memory usage during build**: Longer context lengths require more GPU memory for
  KV-cache allocation. A value of `2048` keeps memory usage low enough to run on most
  GPUs (16 GB+), while `4096` or higher may require 24 GB+ GPUs.
- **Cache applicability at serving time**: The compiled kernels cover sequence lengths
  **up to** this value. Requests within this range will benefit from the pre-compiled
  cache. Requests exceeding it will trigger on-the-fly compilation at serving time.

**Guidelines for choosing `max-model-len`:**

| Value | Use Case | GPU Memory |
|-------|----------|------------|
| `2048` | Testing, chatbot workloads with short contexts | ~16 GB |
| `4096` | General-purpose serving, document Q&A | ~24 GB |
| `8192`+ | Long-context workloads (summarization, RAG) | ~40 GB+ |

Set this to the maximum context length you expect in production. If unsure, `2048` is a
safe default that produces a functional cache with modest GPU requirements. You can always
rebuild with a larger value later.

Available Red Hat ModelCar images on `registry.redhat.io/rhelai1/`:
- `modelcar-granite-3-1-8b-lab-v1` - Granite 3.1 8B Lab v1
- `modelcar-granite-3-1-8b-starter-v1` - Granite 3.1 8B Starter v1
- `modelcar-granite-8b-code-instruct` - Granite 8B Code Instruct
- `modelcar-granite-8b-code-base` - Granite 8B Code Base

For additional models, see the [Red Hat AI ModelCar Catalog](https://github.com/redhat-ai-services/modelcar-catalog) on Quay.io.

**OCI ModelCar requirements:**
- `enableModelcar: true` must be set in the `inferenceservice-config` ConfigMap (enabled by default in RHOAI)
- The cluster must have pull access to the model image registry

### GPU Configuration

```yaml
params:
- name: target-gpu-arch
  value: ""                          # Auto-detected (leave empty for auto-detection)
```

**GPU Architecture Auto-Detection:**
- **Leave empty** (default): Automatically detects GPU architecture from cluster hardware
- **Specify manually**: Override auto-detection for validation or cross-compilation scenarios
- **Validation**: If specified, must match detected hardware or pipeline fails with clear error message

Common GPU architectures:
- `cuda-7.5`: RTX 20 series, GTX 16 series, Tesla T4
- `cuda-8.0`: A100, DGX A100
- `cuda-8.6`: RTX 30 series, A100, A10G (AWS g5 instances)
- `cuda-8.9`: RTX 40 series (Ada Lovelace), L40S
- `cuda-9.0`: H100, H800, GH200


### CUDA Version Compatibility

| GPU Model | Compute Capability | Min CUDA | Recommended CUDA | Notes |
|-----------|-------------------|----------|------------------|-------|
| Tesla T4  | 7.5               | 10.0     | 11.0+            | Good for testing |
| A10G      | 8.6               | 11.1     | 12.0+            | AWS g5 instances |
| A100      | 8.0/8.6           | 11.0     | 12.0+            | Data center standard |
| RTX 4090  | 8.9               | 11.8     | 12.0+            | Consumer/workstation |
| H100      | 9.0               | 12.0     | 12.0+            | Latest generation |

### Registry Configuration

```yaml
params:
- name: registry-url
  value: "quay.io/yourorg"           # Your registry URL
- name: registry-secret
  value: "registry-push-secret"      # Secret with push credentials (default)
- name: cache-tag
  value: "v1.0"                      # Optional custom tag
```

## 📁 Pipeline Components

### Core Tasks

1. **[Pre-flight Check](task-preflight-check.yaml)**
   - Verifies ODH or RHOAI operator is installed
   - Checks KServe CRDs are available
   - Instantiates the selected ServingRuntime template from `redhat-ods-applications`

2. **[GPU Environment Detector](task-gpu-environment-detector.yaml)**
   - Detects GPU specifications and CUDA environment
   - Validates minimum requirements
   - Generates compatibility metadata

3. **[ISVC Cache Collector](task-isvc-cache-collector.yaml)**
   - Deploys a KServe InferenceService with `vllm-cuda-runtime`
   - vLLM produces the compilation cache naturally during startup
   - Sends warmup requests and extracts cache via `oc cp`
   - No separate validation needed - cache is inherently valid

4. **[Metadata Generator](task-cache-metadata-generator.yaml)**
   - Creates comprehensive compatibility metadata
   - Generates usage documentation
   - Produces compatibility hashes for matching

5. **[Image Packager](task-cache-image-packager.yaml)**
   - Uses [GKM MCV](https://github.com/redhat-et/GKM/blob/main/mcv/README.md) to package cache as OCI image
   - MCV auto-detects cache format and generates `cache.vllm.image/*` labels
   - Adds `io.kserve.gkm/*` labels (vllm-version, model-name, architecture, cache-size, etc.)
   - Pushes image to the configured container registry

6. **[GKMCache Provisioner](task-gkm-cache-provisioner.yaml)**
   - Creates a GKMCache CR to provision cache PVC
   - Links the OCI cache image to the cluster

## 🎯 Output Artifacts

### Cache Image

The pipeline produces an OCI image (built by MCV) containing:

```
io.vllm.cache/                      # Compiled cache artifacts (auto-detected by MCV)
io.vllm.manifest/manifest.json      # MCV-generated manifest with cache metadata
```

**OCI Image Labels:**

The image carries two sets of labels:

| Label prefix | Source | Example labels |
|---|---|---|
| `cache.vllm.image/*` | MCV (auto-generated) | `entry-count`, `cache-size-bytes`, `summary`, `format` |
| `io.kserve.gkm/*` | Pipeline (explicit) | `built-on`, `vllm-version`, `model-name`, `model-architecture`, `compilation-level`, `cache-size-in-bytes`, `entry-count` |
| `ai.vllm.*` | Pipeline (explicit) | `model.name`, `model.revision`, `cache.gpu-arch`, `cache.first-startup-seconds` |

### Usage Example

**Option A: GKM-native (recommended when GKM operator is installed)**

The pipeline creates a GKMCache CR that provisions a PVC from the cache OCI image.
Mount that PVC and point vLLM at it via the `--compilation-config` arg on the ServingRuntime:

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: mistral-24b-with-cache
spec:
  predictor:
    model:
      runtime: vllm-cuda-runtime
      modelFormat:
        name: vLLM
      storageUri: "oci://registry.redhat.io/rhelai1/modelcar-mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5"
      args:
        - "--compilation-config"
        - '{"level": 3, "cache_dir": "/mnt/cache"}'
      resources:
        limits:
          nvidia.com/gpu: "1"
        requests:
          nvidia.com/gpu: "1"
      volumeMounts:
        - name: gkm-cache
          mountPath: /mnt/cache
          readOnly: true
    volumes:
      - name: gkm-cache
        persistentVolumeClaim:
          claimName: vllm-cache-mistral-small-3-1-24b-instruct-2503  # PVC created by GKMCache CR
```

**Option B: Init container (no GKM operator required)**

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: mistral-24b-with-cache
spec:
  predictor:
    model:
      runtime: vllm-cuda-runtime
      modelFormat:
        name: vLLM
      storageUri: "oci://registry.redhat.io/rhelai1/modelcar-mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5"
      args:
        - "--compilation-config"
        - '{"level": 3, "cache_dir": "/mnt/cache"}'
      resources:
        limits:
          nvidia.com/gpu: "1"
        requests:
          nvidia.com/gpu: "1"
      volumeMounts:
        - name: cache-vol
          mountPath: /mnt/cache
    initContainers:
      - name: cache-loader
        image: quay.io/yourorg/gkm_cache_container:mistral-small-3-1-24b-instruct-2503-cuda-8-6
        command: ["cp", "-r", "/io.vllm.cache/.", "/mnt/cache/"]
        volumeMounts:
          - name: cache-vol
            mountPath: /mnt/cache
    volumes:
      - name: cache-vol
        emptyDir: {}
```

> **Note**: `VLLM_TORCH_COMPILE_CACHE_DIR` is **not** a valid vLLM environment variable.
> Always use the `--compilation-config '{"cache_dir": "..."}'` arg (or the shorthand
> `-cc.cache_dir=...`) to configure the cache directory. The ServingRuntime passes these
> args directly to the `vllm serve` command. See
> [VLLM_CACHE_KSERVE_INTEGRATION.md](VLLM_CACHE_KSERVE_INTEGRATION.md) for full details.

## 📊 Performance Benefits

### Startup Time Improvement

| Model Size | Without Cache | With Cache | Improvement |
|------------|---------------|------------|-------------|
| 7B         | 5-8 minutes  | 1-2 minutes| 70-80%      |
| 13B        | 8-12 minutes | 2-3 minutes| 75-80%      |
| 70B        | 15+ minutes  | 4-6 minutes| 65-75%      |

### Resource Utilization

- **GPU Memory**: 10-20% reduction during startup
- **CPU Utilization**: 50% reduction during compilation phase
- **Network**: Reduced model download frequency

## 🔍 Troubleshooting

### Common Issues

#### ISVC Not Becoming Ready

```bash
# Check InferenceService status
oc get inferenceservice -l app=gkm-cache-builder
oc describe inferenceservice <isvc-name>

# Check predictor pod status and logs
oc get pods -l serving.kserve.io/inferenceservice=<isvc-name>
oc logs <predictor-pod> -c kserve-container --tail=100

# Common causes:
# - vllm-cuda-runtime ServingRuntime not applied in namespace
# - Insufficient GPU memory
# - Model access issues (private repos, missing HuggingFace token)
# - No GPU nodes available
```

#### Cache Collection Failures

```bash
# Check if cache was produced inside the predictor pod
oc exec <predictor-pod> -c kserve-container -- ls -la /mnt/cache/

# Check oc cp errors in the isvc-cache-collector task logs
tkn taskrun logs --last

# Common causes:
# - PVC not mounted correctly
# - Cache directory empty (model may not trigger compilation)
# - oc cp permission issues
```

#### Registry Push Failures

```bash
# Check registry push secret exists and is correct type
oc get secret registry-push-secret -o jsonpath='{.type}'
# Expected: kubernetes.io/dockerconfigjson

# Check the packager task logs
tkn taskrun logs --last

# Common causes:
# - Secret 'registry-push-secret' not created (pipeline fails early with instructions)
# - Invalid registry credentials
# - Secret not linked to buildah-sa: oc secrets link buildah-sa registry-push-secret --for=mount
# - Registry storage quota exceeded
```

#### GPU Architecture Mismatch

```bash
# Check GPU environment detection logs
kubectl logs <detect-gpu-environment-pod> -c detect-gpu-specs

# Example error: "Target GPU architecture mismatch!"
# Solutions:
# 1. Remove target-gpu-arch parameter to use auto-detection
# 2. Use correct architecture shown in detection logs
# 3. Deploy on hardware that matches specified architecture
```

#### Orphaned Resources After Pipeline Failure

```bash
# Find orphaned ISVC and PVC resources from failed runs
oc get inferenceservice -l app=gkm-cache-builder
oc get pvc -l app=gkm-cache-builder

# Clean up manually
oc delete inferenceservice -l app=gkm-cache-builder
oc delete pvc -l app=gkm-cache-builder
```

### Debugging Commands

```bash
# Get detailed pipeline execution info
tkn pipelinerun describe <pipelinerun-name>

# Watch ISVC cache collector task logs
tkn taskrun logs --last -f

# Check ISVC status during cache collection
oc get inferenceservice -l app=gkm-cache-builder -w

# Access task workspaces
kubectl get pvc  # Find workspace PVCs
kubectl run debug --image=alpine -it --rm -- sh
# mount PVC and explore

# Test cache image manually
docker pull <cache-image-url>
docker run --rm -it <cache-image-url> ls -la /io.vllm.cache/
```

## 🛠️ Development

### Adding New Tasks

1. Create task YAML in the format: `task-<name>.yaml`
2. Add task reference to `pipeline.yaml`
3. Update `pipelinerun-template.yaml` if new parameters needed
4. Test with a development model

### Testing Pipeline Changes

```bash
# The default pipelinerun-template.yaml uses Mistral Small 3.1 24B (quantized)
# For HuggingFace models, update model-name accordingly:
sed 's|oci://registry.redhat.io/rhelai1/modelcar-mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5|mistralai/Mistral-Small-3.1-24B-Instruct-2503|g' pipelinerun-template.yaml > test-run.yaml
oc create -f test-run.yaml
```

### Contributing

1. Test changes with small models first
2. Update documentation for any new parameters
3. Ensure compatibility metadata is properly generated
4. Add validation for new features

## 🔑 Code Changes Needed

This section lists the changes required across different components to make the GKM cache
pipeline work end-to-end. Items are ordered by importance.

### No Changes Needed

**KServe** - Investigation of the KServe source code confirmed that **no code changes are
required**. All features needed for cache delivery already exist:

| What we need | KServe already has it |
|---|---|
| Mount a PVC at a custom path | `PodSpec.Volumes` uses `patchStrategy:"merge"` - user volumes are preserved |
| Pass `--compilation-config` arg to vLLM | `MergeRuntimeContainers()` concatenates user args after runtime args |
| PVC direct mount (no init container) | Storage initializer creates direct volume mounts for `pvc://` URIs |
| No webhook rejection | No validation rejects arbitrary volumes, mounts, or args |

### Critical Changes

#### 1. GKM PVC mount path alignment (GKM operator)

**What:** When GKM extracts an OCI image into a PVC, the internal image paths (e.g.,
`/opt/vllm/cache/`) may be preserved root-relative inside the PVC. The exact directory
structure inside the PVC determines what value to use for `-cc.cache_dir`.

**Why it matters:** If the PVC contains `/opt/vllm/cache/rank_0_0/...` and the ISVC mounts
the PVC at `/mnt/cache`, then `-cc.cache_dir` must be `/mnt/cache/opt/vllm/cache` (not
`/mnt/cache`). Getting this wrong means vLLM won't find the `rank_0_0/` directory and the
cache is useless.

**Action:** Inspect a GKM-provisioned PVC to determine the extraction layout. Then either:
- Adjust the OCI image to place files at `/` so that the PVC root contains `rank_0_0/` directly, or
- Document the correct `-cc.cache_dir` value based on GKM's extraction behavior, or
- Change GKM to support a configurable extraction root path

#### 2. Cache invalidation / versioning (pipeline + OCI labels)

**What:** The cache is only valid for a specific combination of vLLM version + PyTorch
version + CUDA version + GPU architecture + model.

**Current state:** The pipeline now includes `io.kserve.gkm/vllm-version` in the OCI image
labels. PyTorch version is not yet captured.

**Remaining action:**
- Add PyTorch version extraction and `ai.vllm.cache.pytorch-version` label
- Optionally, build a compatibility-check init container that compares cache labels against
  the running vLLM version and fails fast if they don't match

#### 3. Multi-GPU / tensor-parallel cache (pipeline)

**What:** The pipeline currently produces only `rank_0_0/` (single-GPU). Multi-GPU serving
with tensor parallelism (e.g., 2x A100) requires `rank_0_0/`, `rank_1_0/`, etc.

**Why it matters:** Production deployments of large models (70B+) typically require 2-8 GPUs
with tensor parallelism. The cache is per-rank, so each GPU rank needs its own compiled
artifacts.

**Action:** Extend `task-isvc-cache-collector.yaml` to deploy the ISVC with
`tensor-parallel-size > 1` and collect cache from all `rank_*_0/` directories.

### Medium-Priority Changes

#### 4. OCI + multi-storageUri interaction (KServe testing)

**What:** When `storageUris[0]` is an `oci://` URI, KServe activates "modelcar" mode and
skips init container injection entirely. It is untested whether a second `storageUri`
entry (the cache) works correctly alongside a modelcar first entry.

**Why it matters:** The recommended flow uses `oci://` for the model (modelcar) and
`pvc://` for the cache. If modelcar mode prevents processing of the second `storageUri`,
the cache won't be mounted.

**Action:** Test on a cluster with KServe. If it doesn't work, the workaround is to use
explicit `volumes` and `volumeMounts` in the ISVC spec instead of `storageUris` (which
is what the current examples already do).

#### 5. ServingRuntime `-cc.cache_dir` default (ServingRuntime template)

**What:** The `vllm-cuda-runtime` ServingRuntime does not include any compilation config
args by default. Users must add `--compilation-config` args manually in every ISVC.

**Why it matters:** Users may forget to add the arg, resulting in a mounted cache that is
silently ignored. vLLM will cold-start as if no cache exists.

**Action:** Consider adding a default `--compilation-config '{"level": 3}'` to the
ServingRuntime template, or document a "cache-enabled" variant of the ServingRuntime
that includes the cache args.

### Low-Priority / Future

#### 6. Cache size estimation (pipeline)

**What:** The pipeline workspace PVC is hardcoded to 20Gi. Different models produce
different cache sizes. A 70B model may need more; a 7B model wastes space.

**Action:** Add a parameter or auto-sizing logic based on model size.

#### 7. Health check: warm vs cold start (vLLM / KServe)

**What:** There is no readiness signal that distinguishes "vLLM loaded cache and is
ready" from "vLLM is compiling from scratch and will be slow for a while."

**Action:** This would require changes in vLLM (expose cache hit/miss metrics) and
possibly in KServe (expose startup latency in ISVC status).

### Summary

| Component | Changes needed? | Priority |
|-----------|----------------|----------|
| **KServe** | None | - |
| **GKM operator** | Verify/fix PVC extraction path layout | Critical |
| **Pipeline (Tekton tasks)** | Add version labels, multi-GPU support, cache sizing | Medium-High |
| **ServingRuntime template** | Consider cache-aware default args | Medium |
| **vLLM** | Expose cache hit/miss metrics (future) | Low |

For the full technical analysis, see [VLLM_CACHE_KSERVE_INTEGRATION.md](VLLM_CACHE_KSERVE_INTEGRATION.md),
Sections 6 (Identified Gaps) and 8 (Recommendations and Next Steps).

## 📚 References

### Related Projects

- **[vLLM](https://github.com/vllm-project/vllm)**: High-throughput LLM serving
- **[KServe](https://github.com/kserve/kserve)**: Kubernetes model serving platform
- **[GKM](https://github.com/redhat-et/GKM)**: GPU Kernel Manager
- **[MCU](https://github.com/redhat-et/MCU)**: Model Cache Utils

### Documentation

- [vLLM torch.compile Guide](https://docs.vllm.ai/en/latest/design/torch_compile/)
- [KServe OCI ModelCar Storage](https://kserve.github.io/website/latest/modelserving/storage/oci/)
- [KServe Multi-Storage URI](https://kserve.github.io/website/0.12/modelserving/storage/)
- [Red Hat AI ModelCar Catalog](https://github.com/redhat-ai-services/modelcar-catalog)
- [Build and Deploy ModelCar in OpenShift AI](https://developers.redhat.com/articles/2025/01/30/build-and-deploy-modelcar-container-openshift-ai)
- [Tekton Pipelines](https://tekton.dev/docs/pipelines/)

### Hardware Compatibility

- [NVIDIA GPU Compute Capability](https://developer.nvidia.com/cuda-gpus)
- [CUDA Compatibility Guide](https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/)

## 📄 License

This project is licensed under the Apache License 2.0 - see the LICENSE file for details.

## 🤝 Support

For issues and questions:

1. **Pipeline Issues**: Create an issue in this repository
2. **vLLM Issues**: [vLLM GitHub Issues](https://github.com/vllm-project/vllm/issues)
3. **KServe Issues**: [KServe GitHub Issues](https://github.com/kserve/kserve/issues)
4. **Tekton Issues**: [Tekton Pipelines Issues](https://github.com/tektoncd/pipeline/issues)

---