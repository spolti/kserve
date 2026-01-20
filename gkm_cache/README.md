# GKM Cache Builder Pipeline

A comprehensive Tekton pipeline for building, packaging, and distributing vLLM compilation caches to accelerate 
GPU kernel compilation and reduce cold start times for model serving workloads.

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
│  3. ISVC-Based Cache Collection          │
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
# Or from Docker's config:
# --from-file=.dockerconfigjson=${HOME}/.docker/config.json

# Link it to the pipeline service account
oc secrets link buildah-sa registry-push-secret --for=mount
```

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

### 3. Install Pipeline

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


### 4. Run Pipeline

```bash
# Customize pipelinerun-template.yaml with your model and registry
# Then run (uses generateName, so 'create' is required):
oc create -f pipelinerun-template.yaml
```

### 5. Monitor Progress

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

### Model Configuration

The pipeline supports two model source formats:

**OCI ModelCar Image (recommended for Red Hat models):**
```yaml
params:
- name: model-name
  value: "oci://registry.redhat.io/rhelai1/modelcar-granite-3-1-8b-lab-v1:1.4"
- name: max-model-len
  value: "2048"                      # Context length for cache building
```

**HuggingFace Model:**
```yaml
params:
- name: model-name
  value: "meta-llama/Llama-2-7b-hf"  # Any HuggingFace model (org/model format)
- name: model-revision
  value: "main"                       # Git branch/tag (only for HuggingFace)
- name: max-model-len
  value: "4096"                      # Context length for cache building
```

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
   - Packages cache as OCI-compliant container image
   - Adds metadata labels for discoverability
   - Optimizes image size and structure

6. **[GKMCache Provisioner](task-gkm-cache-provisioner.yaml)**
   - Creates a GKMCache CR to provision cache PVC
   - Links the OCI cache image to the cluster

## 🎯 Output Artifacts

### Cache Image

The pipeline produces an OCI image containing:

```
/opt/vllm/cache/                    # Compiled cache artifacts (torch_compile_cache)
/opt/vllm/cache_metadata.json      # Cache metadata (model, GPU, build info)
```

### Usage Example

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: granite-8b-with-cache
spec:
  predictor:
    model:
      modelFormat:
        name: vLLM
      storageUri: "oci://registry.redhat.io/rhelai1/modelcar-granite-3-1-8b-lab-v1:1.4"
      env:
      - name: VLLM_TORCH_COMPILE_CACHE_DIR
        value: "/opt/vllm/cache"
    initContainers:
    - name: cache-extractor
      image: quay.io/yourorg/vllm-cache:granite-3-1-8b-cuda-8-6-abc1234
      command: ["cp", "-r", "/opt/vllm/cache/*", "/shared-cache/"]
      volumeMounts:
      - name: vllm-cache
        mountPath: /shared-cache
```

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
docker run --rm -it <cache-image-url> ls -la /opt/vllm/cache/
```

## 🛠️ Development

### Adding New Tasks

1. Create task YAML in the format: `task-<name>.yaml`
2. Add task reference to `pipeline.yaml`
3. Update `pipelinerun-template.yaml` if new parameters needed
4. Test with a development model (e.g., `microsoft/DialoGPT-small`)

### Testing Pipeline Changes

```bash
# The default pipelinerun-template.yaml uses Granite 3.1 8B which is suitable for testing
# For HuggingFace models, update model-name to a small model:
sed 's|oci://registry.redhat.io/rhelai1/modelcar-granite-3-1-8b-lab-v1:1.4|openai-community/gpt2-xl|g' pipelinerun-template.yaml > test-run.yaml
oc create -f test-run.yaml
```

### Contributing

1. Test changes with small models first
2. Update documentation for any new parameters
3. Ensure compatibility metadata is properly generated
4. Add validation for new features

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