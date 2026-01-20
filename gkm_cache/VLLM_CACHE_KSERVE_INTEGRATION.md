# vLLM CompilationConfig.cache_dir + KServe GKM Integration

**RHOAIENG-44671** | Technical Design Document

---

## 1. vLLM Compilation Cache - How It Works

### 1.1 CompilationConfig.cache_dir

`CompilationConfig.cache_dir` is a `str` field (default: `""`) defined in `vllm/config/compilation.py`. It controls where vLLM stores and reads compiled torch artifacts.

**When empty (default):** vLLM auto-generates the cache path:

```
~/.cache/vllm/torch_compile_cache/{hash_key}/rank_{i}_{j}/
```

The `hash_key` is a 10-char SHA-256 computed from four independent hashes:
- `env_hash` - system/environment state (from `envs.compile_factors()`)
- `config_hash` - all VllmConfig settings (excluding `cache_dir` itself)
- `code_hash` - SHA-256 of all traced source files' contents
- `compiler_hash` - Inductor/system state (PyTorch version, GPU compute capability)

`cache_dir` and `local_cache_dir` are **excluded** from the hash computation, so changing the path does not invalidate the cache.

### 1.2 Cache Directory Internals

Inside the cache directory, vLLM's `InductorAdaptor.initialize_cache()` (in `vllm/compilation/compiler_interface.py`) creates:

| Subdirectory | Purpose | Env var set by vLLM |
|---|---|---|
| `{base_cache_dir}/inductor_cache/` | Compiled FX graphs, inductor artifacts | `TORCHINDUCTOR_CACHE_DIR` |
| `{base_cache_dir}/triton_cache/` | Compiled Triton kernels (.py, .so, .o) | `TRITON_CACHE_DIR` |

Additional artifacts include computation graphs and transformed code.

### 1.3 How to Set cache_dir

There are three ways to set the cache directory:

**CLI flag (recommended for KServe):**
```bash
vllm serve <model> -cc.cache_dir=/path/to/cache
```

**JSON config:**
```bash
vllm serve <model> --compilation-config='{"cache_dir": "/path/to/cache"}'
```

**Python API:**
```python
CompilationConfig(cache_dir="/path/to/cache")
```

### 1.4 Pre-populated Cache Loading (Warm Start)

When a pre-built cache is available, vLLM loads it as follows:

1. If `cache_dir` is empty (default): computes a `hash_key` from environment, config, code, and compiler hashes, then looks for `{VLLM_CACHE_ROOT}/torch_compile_cache/{hash_key}/rank_{i}_{j}/`
2. If `cache_dir` is explicitly set: **skips** the hash_key directory entirely, looks directly for `{cache_dir}/rank_{i}_{j}/`
3. Within the `rank_{i}_{j}/{prefix}/` directory, loads compiled artifacts via `FxGraphCache._lookup_graph()`
4. Skips compilation entirely - near-instant startup vs 30+ seconds cold start

This means that when using `-cc.cache_dir`, you do **not** need to worry about matching the hash directory name. The `rank_{rank}_{dp_rank}/` level is deterministic (e.g., `rank_0_0` for single-GPU).

**Portability requirements** - a cache is reusable across machines when:
- Same GPU architecture (compute capability)
- Same PyTorch version
- Same vLLM version
- Same model and model configuration

### 1.5 vLLM Environment Variables

The PoC previously used `VLLM_TORCH_COMPILE_CACHE_DIR` which **does not exist** as a vLLM env var. This has been corrected to use `--compilation-config` with `cache_dir`.

**vLLM env vars that DO exist:**

| Environment variable | Purpose |
|---|---|
| `VLLM_CACHE_ROOT` | Root for all vLLM caches (default `~/.cache/vllm`) |
| `VLLM_DISABLE_COMPILE_CACHE` | Disable compilation caching entirely |
| `VLLM_COMPILE_CACHE_SAVE_FORMAT` | Format for saved cache artifacts |

---

## 2. Cache Storage and Retrieval Mechanism

### 2.1 Cache Creation Workflow

The pipeline collects the cache using a real KServe InferenceService (`task-isvc-cache-collector.yaml`). This ensures the cache is built in exactly the same environment that will serve the model:

1. Creates a cache PVC and deploys a KServe InferenceService with `--compilation-config '{"level": 3, "cache_dir": "/mnt/cache"}'` and the selected ServingRuntime (e.g., `vllm-cuda-runtime`)
2. vLLM compiles all FX graphs during server startup and writes them to the cache PVC with the correct `rank_0_0/backbone/` structure
3. Sends warmup inference requests via the predictor pod IP to ensure all code paths are compiled
4. Extracts cache artifacts from the predictor pod via `oc cp`
5. Writes `cache_metadata.json` with model, GPU, compilation level, and vLLM first-startup timing
6. Cleans up the temporary InferenceService and PVC

This approach ensures the cache format exactly matches what vLLM expects at serving time, because the same ServingRuntime image and vLLM version produced it.

### 2.2 Cache Storage (OCI Image)

The `task-cache-image-packager.yaml` packages the cache directory into a minimal OCI image (`FROM scratch`):

```
/opt/vllm/cache/
  rank_0_0/
    backbone/
      vllm_compile_cache.py
      computation_graph.py
      transformed_code.py
      cache_key_factors.json
    inductor_cache/
      [compiled FX graphs]
    triton_cache/
      [compiled Triton kernels: *.py, *.so, *.o]
```

The image is pushed to the configured container registry with tags derived from model name, revision, and GPU architecture.

### 2.3 Cache Retrieval at Serving Time

At serving time, the cache is delivered to the vLLM container via one of the delivery mechanisms described in Section 3. vLLM is configured with `-cc.cache_dir` pointing at the mounted cache directory. On startup:

1. vLLM resolves `cache_dir` and appends `rank_0_0/backbone/`
2. `InductorAdaptor.initialize_cache()` sets `TORCHINDUCTOR_CACHE_DIR` and `TRITON_CACHE_DIR` to `rank_0_0/inductor_cache/` and `rank_0_0/triton_cache/`
3. `FxGraphCache._lookup_graph()` finds pre-compiled artifacts and loads them
4. Compilation is skipped entirely

### 2.4 Cache Compatibility and Runtime Images

The cache is tightly coupled to the runtime environment. The GKM build step **must** use a vLLM image that matches the serving runtime:

| Factor | Must match between build and serve |
|---|---|
| vLLM version | Exact match required |
| PyTorch version | Exact match required |
| GPU compute capability | Exact match required |
| Model + config | Exact match required |
| CUDA version | Exact match required |

The pipeline now uses the same ServingRuntime image for cache collection as will be used at serving time, because it deploys a real KServe InferenceService with the selected ServingRuntime (e.g., `vllm-cuda-runtime` instantiated from the `vllm-cuda-runtime-template` in `redhat-ods-applications`). This eliminates image mismatch issues by design.

**Assessment:** A separate "cache creation workflow compatible with runtime images" is not needed. The ISVC-based collection approach inherently uses the same runtime image for building and serving.

---

## 3. KServe Integration - How to Deliver Cache to vLLM

### 3.1 Serving Runtime Configuration for GKM Cache Consumption

The vLLM serving runtime needs exactly one additional argument to consume a GKM cache:

```yaml
args:
  - "-cc.cache_dir=/mnt/models/cache"
```

This tells vLLM to look for pre-compiled artifacts in `/mnt/models/cache/rank_0_0/` instead of generating them from scratch.

**KServe arg passthrough - Confirmed working:** Investigation of KServe source code confirms that user-specified `args` in the ISVC spec are **appended** to the ServingRuntime's default args via `MergeRuntimeContainers()` in `pkg/controller/v1beta1/inferenceservice/utils/utils.go`. The merge uses concatenation (not replacement), so both runtime defaults and user args reach the container. No special handling is needed for the `-cc.` prefix or `--compilation-config` JSON — they pass through as plain string arguments.

### 3.2 Option A: Multi-storageUri (recommended for PoC)

KServe supports `storageUris[]` with custom mount paths. Each `StorageUri` has a `uri` and `mountPath` field (`predictor.go:57-90`). The storage initializer downloads all URIs to their respective paths.

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: mistral-24b-with-cache
spec:
  predictor:
    model:
      modelFormat:
        name: vllm
      args:
        - "-cc.cache_dir=/mnt/models/cache"
    storageUris:
      - uri: "oci://registry.redhat.io/rhelai1/modelcar-mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5"
        mountPath: "/mnt/models/model"
      - uri: "oci://registry.example.com/gkm_cache_container:mistral-small-3-1-24b-instruct-2503-cuda-8-6"
        mountPath: "/mnt/models/cache"
```

**Constraints:**

1. **Common parent path validation** (`inference_service_validation.go:539-582`): Non-PVC `storageUris` paths must share a common parent directory that is not `/`. Using `/mnt/models/model` and `/mnt/models/cache` satisfies this (common parent: `/mnt/models`).

2. **OCI modelcar bypass** (`storage_initializer_injector.go:239`): When `storageUris[0]` uses the `oci://` prefix, KServe treats it as a "modelcar" and skips init container injection entirely:

   ```go
   if params.Config.EnableOciImageSource && len(params.StorageURIs) > 0 &&
       strings.HasPrefix(params.StorageURIs[0].Uri, constants.OciURIPrefix) {
       return nil
   }
   ```

   The cache URI should **not** be the first entry if it uses `oci://`. OCI support for multi-storageUri as a non-first entry still needs testing.

### 3.3 Option B: Custom Init Container

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: mistral-24b-with-cache
spec:
  predictor:
    model:
      modelFormat:
        name: vllm
      storageUri: "oci://registry.redhat.io/rhelai1/modelcar-mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5"
      args:
        - "-cc.cache_dir=/cache/vllm"
    initContainers:
      - name: cache-loader
        image: registry.example.com/gkm_cache_container:mistral-small-3-1-24b-instruct-2503-cuda-8-6
        command: ["cp", "-r", "/opt/vllm/cache/.", "/cache/vllm/"]
        volumeMounts:
          - name: cache-vol
            mountPath: /cache/vllm
    volumes:
      - name: cache-vol
        emptyDir: {}
```

This approach is straightforward and avoids the multi-storageUri constraints. The init container copies cache artifacts from the OCI image into a shared `emptyDir` volume before the serving container starts.

### 3.4 Option C: PVC-backed (Production)

Pre-populate a PVC with cache, mount at serving time:

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: mistral-24b-with-cache
spec:
  predictor:
    model:
      modelFormat:
        name: vllm
      args:
        - "-cc.cache_dir=/mnt/models/cache"
    storageUris:
      - uri: "oci://registry.redhat.io/rhelai1/modelcar-mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5"
        mountPath: "/mnt/models/model"
      - uri: "pvc://cache-pvc/mistral-small-3-1-24b-instruct-2503"
        mountPath: "/mnt/models/cache"
```

PVC paths are mounted directly (no init container needed) and are exempt from the common-parent validation (`inference_service_validation.go:552-556`). The storage initializer creates a direct PVC volume mount for each PVC URI (`storage_initializer_injector.go:304-324`).

### 3.5 Option D: GKM-native via GKMCache CR (recommended)

GKM provides a `GKMCache` custom resource that automatically extracts an OCI image into a PVC. This is the intended integration path and avoids manual PVC provisioning or init container wiring.

**The pipeline automates this.** The `provision-gkm-cache` task (Task 6 in the pipeline) automatically creates a GKMCache CR after the OCI image is built and pushed. It also verifies that the GKM operator is installed before proceeding. If you run the full pipeline, you can skip Step 1 below and go directly to Step 2.

**Step 1: Create a GKMCache CR manually** (see `gkm_cache/gkmcache-vllm.yaml`), or let the pipeline handle it:

```yaml
apiVersion: gkm.io/v1alpha1
kind: GKMCache
metadata:
  name: vllm-cache-mistral-small-3-1-24b-instruct-2503
spec:
  image: quay.io/your-org/gkm_cache_container:mistral-small-3-1-24b-instruct-2503-cuda-8-6
```

GKM extracts the OCI image contents into a PVC whose name matches the CR name (`vllm-cache-mistral-small-3-1-24b-instruct-2503`). The PVC will contain:

```
/opt/vllm/cache/
  rank_0_0/
    backbone/
    inductor_cache/
    triton_cache/
```

**Step 2: Reference the GKM PVC in a KServe InferenceService:**

Using `pvc://` storageUri (cleanest approach):

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: mistral-24b-with-cache
spec:
  predictor:
    model:
      modelFormat:
        name: vllm
      args:
        - "-cc.cache_dir=/mnt/models/cache/opt/vllm/cache"
    storageUris:
      - uri: "oci://registry.redhat.io/rhelai1/modelcar-mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5"
        mountPath: "/mnt/models/model"
      - uri: "pvc://vllm-cache-mistral-small-3-1-24b-instruct-2503"
        mountPath: "/mnt/models/cache"
```

Or using a direct volume mount:

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: mistral-24b-with-cache
spec:
  predictor:
    model:
      modelFormat:
        name: vllm
      storageUri: "oci://registry.redhat.io/rhelai1/modelcar-mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5"
      args:
        - "-cc.cache_dir=/cache/opt/vllm/cache"
    containers:
      - name: kserve-container
        volumeMounts:
          - name: gkm-cache
            mountPath: /cache
            readOnly: true
    volumes:
      - name: gkm-cache
        persistentVolumeClaim:
          claimName: vllm-cache-mistral-small-3-1-24b-instruct-2503
```

**Note on `-cc.cache_dir` path:** The GKM PVC contains the files at the OCI image's internal paths (e.g., `/opt/vllm/cache/rank_0_0/`). When mounted at `/mnt/models/cache`, the full path to the rank directory becomes `/mnt/models/cache/opt/vllm/cache/rank_0_0/`. The `cache_dir` argument must therefore point at the directory that is the **parent** of `rank_0_0/`. Depending on how GKM extracts the image (root-relative vs content-only), this path may be `/mnt/models/cache/opt/vllm/cache` or simply `/mnt/models/cache`. This needs to be verified by inspecting the GKM-provisioned PVC contents.

**Advantages of GKM-native approach:**
- GKM manages PVC lifecycle (creation, extraction, cleanup)
- No init container needed - PVC is pre-populated before the pod starts
- PVC can be shared across multiple InferenceService instances
- Cache updates are managed by updating the GKMCache CR's `image` field
- PVC paths are exempt from KServe's common-parent validation

---

## 4. Cache Directory Structure Alignment

### 4.1 How vLLM Resolves cache_dir at Startup

The directory resolution in `VllmBackend.__call__()` (`vllm/compilation/backends.py`) has two distinct paths:

**When `cache_dir` is empty (default):**
```
{VLLM_CACHE_ROOT}/torch_compile_cache/{hash_key}/rank_{rank}_{dp_rank}/{prefix}/
```

**When `cache_dir` is explicitly set:**
```python
if not self.compilation_config.cache_dir:
    # auto-generate hash-based path
    factors = [env_hash, config_hash, code_hash, compiler_hash]
    hash_key = hashlib.sha256(str(factors).encode()).hexdigest()[:10]
    cache_dir = os.path.join(envs.VLLM_CACHE_ROOT, "torch_compile_cache", hash_key)
    self.compilation_config.cache_dir = cache_dir
# ^^^ THIS ENTIRE BLOCK IS SKIPPED when cache_dir is already set
```

The `{hash_key}/` directory level is **bypassed** when `cache_dir` is explicitly provided. vLLM uses the provided path as-is.

**However**, `rank_{rank}_{dp_rank}/` is **always** appended unconditionally:
```python
rank = vllm_config.parallel_config.rank
dp_rank = vllm_config.parallel_config.data_parallel_index
local_cache_dir = os.path.join(cache_dir, f"rank_{rank}_{dp_rank}", self.prefix)
```

There is no configuration option or conditional to skip this level.

### 4.2 Complete Directory Structure (cache_dir explicitly set)

When `cache_dir=/mnt/models/cache`, vLLM creates and expects:

```
/mnt/models/cache/                          <-- cache_dir
  rank_0_0/                                 <-- always appended (rank_{rank}_{dp_rank})
    backbone/                               <-- prefix (compilation unit name)
      vllm_compile_cache.py
      computation_graph.py
      transformed_code.py
      cache_key_factors.json
    inductor_cache/                         <-- TORCHINDUCTOR_CACHE_DIR
    triton_cache/                           <-- TRITON_CACHE_DIR
```

`InductorAdaptor.initialize_cache()` receives `{cache_dir}/rank_0_0/backbone` as `local_cache_dir`, strips the prefix to get `base_cache_dir = {cache_dir}/rank_0_0/`, and creates `inductor_cache/` and `triton_cache/` there.

### 4.3 What the GKM Pipeline Produces (after fix)

The build step now uses `vllm serve --compilation-config '{"level": 3, "cache_dir": "..."}'`, which produces the correct layout:

```
/workspace/cache/vllm_cache/torch_compile_cache/
  rank_0_0/
    backbone/
      vllm_compile_cache.py
      computation_graph.py
      transformed_code.py
      cache_key_factors.json
    inductor_cache/
    triton_cache/
  cache_metadata.json
```

The OCI image packager preserves this structure via `cp -r`, resulting in:

```
/opt/vllm/cache/
  rank_0_0/
    backbone/
    inductor_cache/
    triton_cache/
```

This layout matches what vLLM expects when `cache_dir=/mnt/models/cache` (or wherever the image contents are mounted).

---

## 5. Test Environment and E2E Validation

### 5.1 Test Environment Setup (Plain KServe)

Minimum requirements for testing the integration:

1. Kubernetes cluster with GPU nodes (NVIDIA, compute capability 7.0+)
2. KServe installed (v0.13+, with multi-storageUri support)
3. Tekton Pipelines installed (for running the GKM build pipeline)
4. Container registry accessible from the cluster (e.g., `quay.io`)
5. The Mistral Small 3.1 24B model (or another model from the Red Hat registry catalog)

**Setup steps:**

```bash
# 1. Create service account and RBAC (includes GKM cache management permissions)
kubectl apply -f gkm_cache/build-service-account.yaml

# 2. Install pipeline components
kubectl apply -f gkm_cache/task-preflight-check.yaml
kubectl apply -f gkm_cache/task-gpu-environment-detector.yaml
kubectl apply -f gkm_cache/task-isvc-cache-collector.yaml
kubectl apply -f gkm_cache/task-cache-metadata-generator.yaml
kubectl apply -f gkm_cache/task-cache-image-packager.yaml
kubectl apply -f gkm_cache/task-gkm-cache-provisioner.yaml
kubectl apply -f gkm_cache/pipeline.yaml

# 3. Create secrets
kubectl create secret docker-registry registry-credentials \
  --docker-server=quay.io \
  --docker-username=$QUAY_USER \
  --docker-password=$QUAY_TOKEN

# 4. Run pipeline to build cache
kubectl apply -f gkm_cache/pipelinerun-template.yaml

# 5. Monitor
tkn pipelinerun logs --last -f
```

**Note:** The GKM operator must be installed before running the pipeline. The `provision-gkm-cache` task will verify the operator is present and fail with instructions if the `gkmcaches.gkm.io` CRD is not found.

### 5.2 E2E Test Scenarios

**Test 1: Cache build produces correct structure**

```bash
# After pipeline completes, verify cache image contents:
podman run --rm <cache-image> find /opt/vllm/cache -type d | sort
# Expected output should include:
#   /opt/vllm/cache/rank_0_0
#   /opt/vllm/cache/rank_0_0/backbone
#   /opt/vllm/cache/rank_0_0/inductor_cache
#   /opt/vllm/cache/rank_0_0/triton_cache
```

**Test 2: Cold start vs warm start comparison**

```bash
# Cold start (no cache):
time vllm serve mistralai/Mistral-Small-3.1-24B-Instruct-2503 --compilation-config '{"level": 3}' &
# Wait for /health to return 200, record time

# Warm start (with pre-built cache):
time vllm serve mistralai/Mistral-Small-3.1-24B-Instruct-2503 -cc.cache_dir=/path/to/cache &
# Wait for /health to return 200, record time
# Compare times
```

**Test 3: KServe InferenceService with cache (Option B - init container)**

```yaml
# Deploy with cache:
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: test-gkm-cache
spec:
  predictor:
    model:
      modelFormat:
        name: vllm
      storageUri: "oci://registry.redhat.io/rhelai1/modelcar-mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5"
      args:
        - "-cc.cache_dir=/cache/vllm"
    initContainers:
      - name: cache-loader
        image: <cache-image-from-pipeline>
        command: ["cp", "-r", "/opt/vllm/cache/.", "/cache/vllm/"]
        volumeMounts:
          - name: cache-vol
            mountPath: /cache/vllm
    volumes:
      - name: cache-vol
        emptyDir: {}
```

```bash
# Verify:
kubectl apply -f test-isvc.yaml
kubectl logs -f <pod> -c kserve-container | grep -i "cache\|compile\|warm"
# Check that logs show cache loading, not compilation
```

**Test 4: Multi-storageUri delivery (Option A)**

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: test-multi-uri
spec:
  predictor:
    model:
      modelFormat:
        name: vllm
      args:
        - "-cc.cache_dir=/mnt/models/cache"
    storageUris:
      - uri: "oci://registry.redhat.io/rhelai1/modelcar-mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5"
        mountPath: "/mnt/models/model"
      - uri: "oci://<cache-image>"
        mountPath: "/mnt/models/cache"
```

**Test 5: GKM-native delivery (Option D)**

```bash
# 1. Create GKMCache CR
kubectl apply -f gkm_cache/gkmcache-vllm.yaml

# 2. Wait for GKM to extract the image into a PVC
kubectl get pvc vllm-cache-mistral-small-3-1-24b-instruct-2503 -w
# Wait until STATUS = Bound

# 3. Inspect PVC contents to determine the mount path
kubectl run inspect-cache --rm -it --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi-micro:latest \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "inspect",
        "image": "registry.access.redhat.com/ubi9/ubi-micro:latest",
        "command": ["find", "/cache", "-maxdepth", "4", "-type", "d"],
        "volumeMounts": [{"name": "cache", "mountPath": "/cache"}]
      }],
      "volumes": [{
        "name": "cache",
        "persistentVolumeClaim": {"claimName": "vllm-cache-mistral-small-3-1-24b-instruct-2503"}
      }]
    }
  }'
# Determine the path to rank_0_0/ relative to /cache

# 4. Deploy InferenceService with GKM PVC
# Adjust -cc.cache_dir based on step 3 findings
kubectl apply -f - <<EOF
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: test-gkm-native
spec:
  predictor:
    model:
      modelFormat:
        name: vllm
      storageUri: "oci://registry.redhat.io/rhelai1/modelcar-mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5"
      args:
        - "-cc.cache_dir=/cache/opt/vllm/cache"
    containers:
      - name: kserve-container
        volumeMounts:
          - name: gkm-cache
            mountPath: /cache
            readOnly: true
    volumes:
      - name: gkm-cache
        persistentVolumeClaim:
          claimName: vllm-cache-mistral-small-3-1-24b-instruct-2503
EOF
```

**Test 6: Verify `-cc.cache_dir` passthrough**

```bash
# Check if the arg reaches the vllm process inside the KServe pod:
kubectl exec <pod> -c kserve-container -- ps aux | grep vllm
# Verify -cc.cache_dir appears in the process arguments
```

### 5.3 Validation Script

```bash
#!/bin/bash
# validate-gkm-cache.sh - Validates a GKM cache OCI image
set -e

IMAGE="${1:?Usage: validate-gkm-cache.sh <image-url>}"

echo "=== Validating GKM cache image: $IMAGE ==="

# Pull and extract
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
podman create --name gkm-validate "$IMAGE" 2>/dev/null
podman cp gkm-validate:/opt/vllm/cache "$TMPDIR/cache" 2>/dev/null
podman rm gkm-validate 2>/dev/null

# Check structure
echo "Checking directory structure..."
PASS=true

if [ ! -d "$TMPDIR/cache/rank_0_0" ]; then
  echo "FAIL: rank_0_0/ directory not found"
  PASS=false
fi

for dir in inductor_cache triton_cache; do
  if [ ! -d "$TMPDIR/cache/rank_0_0/$dir" ]; then
    echo "FAIL: rank_0_0/$dir/ not found"
    PASS=false
  fi
done

# Check for compilation artifacts
FILE_COUNT=$(find "$TMPDIR/cache" -type f | wc -l)
echo "Total files: $FILE_COUNT"

PY_FILES=$(find "$TMPDIR/cache" -name "*.py" | wc -l)
SO_FILES=$(find "$TMPDIR/cache" -name "*.so" | wc -l)
echo "Python files: $PY_FILES, Shared objects: $SO_FILES"

if [ "$FILE_COUNT" -lt 5 ]; then
  echo "FAIL: Too few files ($FILE_COUNT)"
  PASS=false
fi

if [ "$PASS" = true ]; then
  echo "PASS: Cache image is valid"
else
  echo "FAIL: Cache image validation failed"
  exit 1
fi
```

---

## 6. Identified Gaps and Production Readiness

### 6.1 Current Status (after PoC fix)

| Item | Status | Notes |
|---|---|---|
| Cache build uses vLLM CompilationConfig | Fixed | ISVC-based collection with `--compilation-config` via ServingRuntime |
| Cache directory structure matches vLLM expectations | Fixed | Pipeline now produces `rank_0_0/backbone/` hierarchy |
| Non-existent env var (`VLLM_TORCH_COMPILE_CACHE_DIR`) removed | Fixed | Removed from all pipeline tasks |
| USAGE.md references corrected to `-cc.cache_dir` | Fixed | Updated in metadata generator and image packager |
| KServe arg passthrough verified | Resolved | `MergeRuntimeContainers()` concatenates user args to runtime args (Section 3.1) |
| Build image matches serving runtime | Resolved | ISVC-based approach uses the same ServingRuntime for build and serve (Section 2.4) |
| KServe supports volume mounts without code changes | Resolved | `PodSpec.Volumes` uses strategic merge; `MergePodSpec()` preserves user volumes (Section 3.6) |

### 6.2 Remaining Gaps

| # | Gap | Severity | Status |
|---|---|---|---|
| 1 | **OCI + multi-storageUri interaction.** First URI being `oci://` triggers modelcar mode, skipping init container injection entirely. Needs testing with cache as second URI. | Medium | Untested |
| 2 | **Environment portability.** Inductor's internal `FxGraphCache` validates compiled artifacts against current environment. Cache built with different PyTorch/CUDA/GPU won't load. | High | By design - documented |
| 3 | ~~**`-cc.cache_dir` arg passthrough.**~~ | ~~Medium~~ | **Resolved** - KServe concatenates user args to runtime args via `MergeRuntimeContainers()` |
| 4 | ~~**Build image mismatch.**~~ | ~~Medium~~ | **Resolved** - ISVC-based collection inherently uses the serving runtime image |
| 5 | **Multi-GPU cache.** Pipeline only produces `rank_0_0/` (single-GPU). Multi-GPU serving with tensor parallelism needs `rank_0_0/`, `rank_1_0/`, etc. | Low | Out of scope for PoC |
| 6 | **Cache invalidation.** No mechanism to detect when a cache is stale (e.g., after vLLM version bump). OCI image labels include model/revision but not vLLM/PyTorch versions in a machine-readable format. | Medium | Not implemented |
| 7 | **GKM PVC mount path.** When GKM extracts the OCI image into a PVC, the internal image paths (e.g., `/opt/vllm/cache/`) may be preserved root-relative. The exact path to `rank_0_0/` inside the PVC needs to be determined by inspecting a GKM-provisioned PVC. This affects the `-cc.cache_dir` value. | Medium | Needs verification |

### 6.3 KServe Code Changes Assessment

**No KServe code changes are required.** Investigation of the KServe source code confirms that all features needed for GKM cache delivery are already implemented:

| Feature | KServe mechanism | Source |
|---|---|---|
| User-specified `volumes` | `PodSpec.Volumes` with `patchStrategy:"merge,retainKeys"` | `podspec.go:28-35` |
| User-specified `volumeMounts` | `PredictorExtensionSpec` embeds `corev1.Container` inline | `predictor.go:119-122` |
| User-specified `args` | `MergeRuntimeContainers()` concatenates ISVC args after runtime args | `utils/utils.go` |
| PVC direct mount | Storage initializer creates direct volume mount for `pvc://` URIs | `storage_initializer_injector.go:304-324` |
| Volume merge with runtime | `MergePodSpec()` uses `strategicpatch.StrategicMergePatch` | `utils/utils.go` |
| No validation rejection | No webhook validates or rejects arbitrary volumes, mounts, or args | `inference_service_validation.go` |

### 6.4 Production Readiness Checklist

- [x] ~~Parameterize vLLM build image to match serving runtime~~ (ISVC-based approach uses ServingRuntime directly)
- [x] ~~Verify `-cc.cache_dir` passthrough in KServe~~ (confirmed via source code analysis)
- [x] ~~Verify KServe supports PVC volume mounts without code changes~~ (confirmed via source code analysis)
- [ ] Add vLLM version and PyTorch version to OCI image labels for cache compatibility checking
- [ ] Test multi-storageUri with OCI cache as non-first URI
- [ ] Add health check / readiness probe that distinguishes warm vs cold start
- [ ] Test with production-scale models (7B, 13B, 70B)
- [ ] Measure actual startup time improvement (cold vs warm)
- [ ] Security review: cache images contain compiled native code (.so, .o) - assess trust model
- [ ] Test PVC-backed delivery (Option C) in production-like environment
- [ ] Document cache lifecycle (build, distribute, consume, invalidate)

---

## 7. End-to-End Flow and Integration Points

### 7.1 Flow Diagram

```
1. GKM Build Pipeline (Tekton)
   ├── preflight-check           → ODH/RHOAI operator, KServe CRDs, ServingRuntime instantiation
   ├── detect-gpu-environment    → GPU arch, compute capability
   ├── isvc-cache-collector      → Deploys ISVC with ServingRuntime, collects compiled cache via oc cp
   ├── generate-metadata         → Compatibility hash, metadata JSON
   ├── package-cache-image       → OCI image (FROM scratch, /opt/vllm/cache/) + push to registry
   └── provision-gkm-cache       → Verifies GKM operator, creates GKMCache CR
                                    ↓ GKM extracts image into PVC
2. Container Registry
   └── registry.example.com/gkm_cache_container:model-gpu-tag
          │
          ├─── Path A: GKM-native (recommended, automated by pipeline)
          │      ↓
          │    GKMCache CR (created by provision-gkm-cache task)
          │      ↓ GKM operator extracts image
          │    PVC (name = GKMCache CR name)
          │      ↓ pvc:// storageUri or volume mount
          │
          ├─── Path B: KServe multi-storageUri
          │      ↓ oci:// or hf:// as second storageUri
          │
          └─── Path C: Init container
                 ↓ cp from OCI image to emptyDir
                                    ↓
3. KServe InferenceService
   ├── storageUris[0]: hf://model  → Model weights
   ├── cache via GKM PVC / storageUri / init container
   └── args: -cc.cache_dir=<cache-mount-path>
                                    ↓
4. vLLM Serving Container
   ├── Resolves cache_dir
   ├── Finds rank_0_0/backbone/   → Loads FX graph cache
   ├── Sets TORCHINDUCTOR_CACHE_DIR → rank_0_0/inductor_cache/
   ├── Sets TRITON_CACHE_DIR       → rank_0_0/triton_cache/
   └── Skips compilation           → Fast startup
```

### 7.2 Integration Points

| Integration point | Components | Protocol/Mechanism |
|---|---|---|
| Pipeline -> Registry | Tekton task-cache-image-packager -> OCI registry | `buildah push` (OCI image) |
| Pipeline -> GKM | Tekton gkm-cache-provisioner -> GKMCache CR | `oc apply` (creates/updates CR) |
| GKM -> PVC | GKMCache CR references OCI image | GKM operator extracts image into PVC |
| GKM -> KServe | PVC name in InferenceService `pvc://` storageUri or volume mount | Kubernetes PVC |
| Registry -> KServe (alt) | OCI image URL in InferenceService `storageUris` | KServe storage initializer / modelcar |
| KServe -> vLLM | `-cc.cache_dir` arg in InferenceService spec | CLI argument passthrough |
| vLLM -> Cache | `CompilationConfig.cache_dir` -> filesystem | Direct filesystem read (`rank_0_0/`) |

---

## 8. Recommendations and Next Steps

### 8.1 Immediate (PoC Validation)

1. **Run the pipeline** on a cluster with GPU. Verify the cache image contains `rank_0_0/backbone/`, `rank_0_0/inductor_cache/`, `rank_0_0/triton_cache/`.

2. **Deploy an InferenceService** with the GKM-provisioned PVC (Option D - pipeline automates GKMCache CR creation). Verify vLLM loads the cache by checking logs for FxGraphCache hits.

3. **Measure startup time** - cold start (no cache) vs warm start (with GKM cache). This is the key metric for the PoC.

4. ~~**Test `-cc.cache_dir` passthrough.**~~ **Resolved** - KServe source analysis confirms args are concatenated via `MergeRuntimeContainers()`. No special handling needed.

### 8.2 Short-term (PoC Completion)

5. ~~**Parameterize the build image.**~~ **Resolved** - ISVC-based approach uses the same ServingRuntime for cache collection and serving. No separate image parameter needed.

6. **Test multi-storageUri** with `hf://` as first URI and `oci://` cache as second URI. Document whether the storage initializer handles this correctly.

7. **Test GKM-native delivery** (Option D). Inspect the GKM-provisioned PVC to determine the exact path to `rank_0_0/` (root-relative vs content-only extraction), and verify the correct `-cc.cache_dir` value.

8. **Test PVC-backed delivery** (Option C) as an alternative production path.

### 8.3 Medium-term (Production Readiness)

8. **Cache versioning.** Add vLLM version, PyTorch version, and CUDA version to OCI image labels. Implement a compatibility check that prevents loading a cache built with a different stack.

9. **Multi-GPU support.** Extend the build pipeline to produce caches for tensor-parallel configurations (`rank_0_0/` through `rank_N_0/`).

10. **Cache invalidation workflow.** Define when caches should be rebuilt (vLLM upgrade, model update, GPU fleet change) and automate the trigger.

---

## Appendix: Source File References

| File | Lines | Content |
|---|---|---|
| `pkg/apis/serving/v1beta1/predictor.go` | 57-90 | `StorageUri` type and `storageUris` field definition |
| `pkg/apis/serving/v1beta1/inference_service_validation.go` | 539-582 | Common parent path validation for multi-storageUri |
| `pkg/webhook/admission/pod/storage_initializer_injector.go` | 232-340 | Init container injection, modelcar bypass, PVC direct mount |
| `gkm_cache/task-preflight-check.yaml` | - | Verifies ODH/RHOAI operator, KServe CRDs, instantiates ServingRuntime |
| `gkm_cache/task-gpu-environment-detector.yaml` | - | Detects GPU architecture and compute capability |
| `gkm_cache/task-isvc-cache-collector.yaml` | - | Deploys ISVC with ServingRuntime, collects compiled cache via `oc cp` |
| `gkm_cache/task-cache-metadata-generator.yaml` | - | Generates `cache_metadata.json` and USAGE.md (references `-cc.cache_dir`) |
| `gkm_cache/task-cache-image-packager.yaml` | - | OCI image packaging (preserves `rank_0_0/` structure) + push to registry |
| `gkm_cache/task-gkm-cache-provisioner.yaml` | - | Verifies GKM operator, creates/updates GKMCache CR, waits for PVC |
| `gkm_cache/pipeline.yaml` | - | 6-task pipeline (preflight → detect → collect → metadata → package → provision) |
| `gkm_cache/build-service-account.yaml` | - | Service account + RBAC (includes GKM cache, ISVC, and preflight roles) |
| `gkm_cache/gkmcache-vllm.yaml` | - | Example GKMCache CR referencing pipeline-built OCI image |
| `pkg/apis/serving/v1beta1/podspec.go` | 28-35 | `PodSpec.Volumes` with strategic merge (user volumes preserved) |
| `pkg/controller/v1beta1/inferenceservice/utils/utils.go` | - | `MergeRuntimeContainers()` (arg concat) and `MergePodSpec()` (volume merge) |
| vLLM: `vllm/config/compilation.py` | - | `CompilationConfig.cache_dir` and `compute_hash()` |
| vLLM: `vllm/compilation/backends.py` | - | `VllmBackend.__call__()` - hash_key generation, `rank_{i}_{j}` appending |
| vLLM: `vllm/compilation/compiler_interface.py` | - | `InductorAdaptor.initialize_cache()` - creates subdirs under `rank_{i}_{j}/` |

---

## Appendix: Changes Made in This Iteration

| File | Change |
|---|---|
| `task-vllm-cache-builder.yaml` | Replaced manual `torch.compile()` with `vllm serve --compilation-config`. Removed `VLLM_TORCH_COMPILE_CACHE_DIR`, `TORCHINDUCTOR_CACHE_DIR`, `TORCH_COMPILE_CACHE_DIR`, `FLASHINFER_CACHE_ROOT`, `TRITON_CACHE_DIR` env vars. Added health-check polling, warmup requests, and structured cache verification. |
| `task-cache-validator.yaml` | Added validation for `rank_0_0/` directory structure, `inductor_cache/`, `triton_cache/`, and backbone compilation unit directories. |
| `task-cache-metadata-generator.yaml` | Fixed USAGE.md to reference `-cc.cache_dir` instead of non-existent `VLLM_TORCH_COMPILE_CACHE_DIR`. Added expected cache structure documentation. |
| `task-cache-image-packager.yaml` | Updated README generation to document correct cache structure and `-cc.cache_dir` usage instead of env var. |
| `gkmcache-vllm.yaml` | New file. GKMCache CR that references the pipeline-built OCI image. GKM extracts it into a PVC for KServe consumption. |
| `task-gkm-cache-provisioner.yaml` | New file. Tekton task that (1) verifies the GKM operator is installed by checking the `gkmcaches.gkm.io` CRD and controller pods, and (2) creates/updates a GKMCache CR with the pipeline-built OCI image, then waits for the resulting PVC to become Bound. |
| `pipeline.yaml` | Added Task 6 (`provision-gkm-cache`) after `package-cache-image`. Added `gkmcache-name` pipeline result. Pipeline is now 6 tasks. |
| `build-service-account.yaml` | Added `gkm-cache-manager` Role granting access to `gkm.io/gkmcaches` (get, list, create, update, patch), PVCs (get, list, watch), and CRDs (get). Added corresponding RoleBinding for `buildah-sa`. |
