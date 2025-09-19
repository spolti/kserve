# ModelMesh to KServe Raw Deployment Migration Helper

A bash script that migrates InferenceServices from ModelMesh serving to KServe Raw deployment mode. This tool handles bulk migrations with interactive pagination, template selection, and storage configuration management.

## What it does

- **Migrates models**: Converts ModelMesh InferenceServices to KServe Raw deployment
- **Preserves configuration**: Maintains route exposure, authentication, and storage settings
- **Handles secrets**: Clones and manages storage and authentication secrets
- **Creates resources**: Generates ServingRuntimes, ServiceAccounts, Roles, and RoleBindings
- **Pagination support**: Interactive navigation for namespaces with hundreds of models
- **Dry-run mode**: Preview changes without applying them

## Requirements

- `oc` (OpenShift CLI)
- `yq` (YAML processor)
- `openssl`
- Access to both source and target namespaces
- OpenShift cluster login

## Usage

```bash
./modelmesh-to-raw.sh --from-ns <source-namespace> --target-ns <target-namespace> [OPTIONS]
```

### Parameters

| Parameter | Description | Required |
|-----------|-------------|----------|
| `--from-ns` | Source namespace containing ModelMesh InferenceServices | ✅ |
| `--target-ns` | Target namespace for KServe Raw deployment | ✅ |
| `--ignore-existing-ns` | Skip check if target namespace already exists | ❌ |
| `--debug` | Show complete processed resources and wait for confirmation | ❌ |
| `--dry-run` | Save all YAML resources to local directory without applying | ❌ |
| `--page-size` | Number of InferenceServices to display per page (default: 10) | ❌ |
| `-h, --help` | Show help message | ❌ |

## Examples

### Basic Migration
```bash
./modelmesh-to-raw.sh --from-ns modelmesh-serving --target-ns kserve-raw
```

### Migration with Pagination
```bash
./modelmesh-to-raw.sh --from-ns large-namespace --target-ns kserve-raw --page-size 5
```

### Dry Run Mode
```bash
./modelmesh-to-raw.sh --from-ns modelmesh-serving --target-ns kserve-raw --dry-run
```

### Debug Mode with Existing Namespace
```bash
./modelmesh-to-raw.sh --from-ns modelmesh-serving --target-ns kserve-raw --ignore-existing-ns --debug
```

## Example Output

### Successful Migration
```
ModelMesh to KServe Raw Deployment Migration Helper
==================================================

Source namespace (ModelMesh): modelmesh-serving
Target namespace (KServe Raw): kserve-raw

🔍 Checking OpenShift login status...
✓ Logged in as: developer
✓ Connected to: https://api.cluster.local:6443

🔍 Verifying ModelMesh configuration in source namespace...
✓ ModelMesh is enabled in namespace 'modelmesh-serving'

🚀 Setting up target namespace for KServe Raw deployment...
🏗️ Creating target namespace 'kserve-raw'...
✓ Target namespace 'kserve-raw' created successfully
✓ Dashboard label applied to namespace 'kserve-raw'
✓ modelmesh-enabled label set to false on namespace 'kserve-raw'

🔍 Discovering InferenceServices in source namespace 'modelmesh-serving'...
✓ Found 3 InferenceService(s) in namespace 'modelmesh-serving'

📦 InferenceServices (Page 1/1, showing items 1-3 of 3):
=======================================================================================
[1] Name: mnist-model
    Status: Ready
    Runtime: ovms
    Model Format: onnx
    Storage: s3://my-bucket/mnist/

[2] Name: sklearn-model
    Status: Ready
    Runtime: ovms
    Model Format: sklearn
    Storage: s3://my-bucket/sklearn/

[3] Name: custom-model
    Status: Ready
    Runtime: custom-runtime
    Model Format: tensorflow
    Storage: s3://my-bucket/tensorflow/

🤔 Selection options:
====================
• 'all' - Select all InferenceServices across all pages
• '3 4' - Select specific items by number (e.g., '3 4' to select items 3 and 4)

• 'q' - Quit migration

Your selection: all
✓ Selected all 3 InferenceService(s) for migration

🔧 Preparing serving runtimes for selected models...
✓ All serving runtimes created successfully

🔄 Processing InferenceServices for Raw Deployment migration...
===================================================================
🔧 Transforming InferenceService 'mnist-model' for Raw Deployment...

🔐 Secret Management for InferenceService 'mnist-model'
=======================================================
📁 Current Storage Configuration:
   Path: models/mnist/1/
   URI: s3://my-bucket/mnist/

✓ Selected all 3 InferenceService(s) for migration

🎉 Migration completed successfully!
======================================

📊 Migration Summary:
  • Source namespace: modelmesh-serving (ModelMesh)
  • Target namespace: kserve-raw (KServe Raw)
  • InferenceServices migrated: 3
  • Models: mnist-model, sklearn-model, custom-model

💡 Next steps:
  • Verify your migrated models are working: oc get inferenceservice -n kserve-raw
  • Check ServingRuntimes: oc get servingruntime -n kserve-raw
  • Test model endpoints for functionality

🏁 Migration helper completed!
```

### Pagination Example
```
📦 InferenceServices (Page 1/3, showing items 1-10 of 25):
=======================================================================================
[1] Name: model-001
[2] Name: model-002
...
[10] Name: model-010

🤔 Selection options:
====================
• 'all' - Select all InferenceServices across all pages
• '3 4' - Select specific items by number (e.g., '3 4' to select items 3 and 4)

📄 Navigation:
==============
• 'n' - Next page
• 'l' - Last page
• 'goto:X' - Go to specific page X (e.g., 'goto:3')

• 'q' - Quit migration

Your selection: n
📄 Moving to page 2...

📦 InferenceServices (Page 2/3, showing items 11-20 of 25):
=======================================================================================
[11] Name: model-011
[12] Name: model-012
...
```

### Dry Run Example
```
🏁 Dry-run completed successfully!

📋 DRY-RUN SUMMARY
==================

All YAML resources have been saved to: migration-dry-run-20241007-143022

📊 Resources saved:
  • Original ModelMesh resources: 9 files
  • New KServe Raw resources: 15 files

📂 Directory structure:
  migration-dry-run-20241007-143022/
  ├── original-resources/     (ModelMesh resources for comparison)
  │   ├── inferenceservice/
  │   ├── servingruntime/
  │   └── secret/
  └── new-resources/          (KServe Raw resources to apply)
      ├── inferenceservice/
      ├── servingruntime/
      ├── secret/
      ├── serviceaccount/
      ├── role/
      └── rolebinding/

💡 Next steps:
  1. Review the generated YAML files in migration-dry-run-20241007-143022
  2. Compare original vs new resources to understand the migration changes
  3. When ready, apply the resources manually:
     find migration-dry-run-20241007-143022/new-resources -name '*.yaml' -exec oc apply -f {} \;
  4. Or re-run this script without --dry-run to perform the actual migration
```

## Features

### Interactive Template Selection
When custom ServingRuntimes are detected, the script presents available templates:
```
🤔 Please select a template for model 'custom-model' from the available ones:
=========================================================================================
    [1] kserve-ovms (OpenVINO Model Server)
    [2] kserve-tensorflow (TensorFlow Serving)
    [3] kserve-pytorch (PyTorch Serving)
    [d] Use default: kserve-ovms (OpenVINO Model Server)
    [m] Enter template name manually

  Your choice (1-3/d/m): 1
```

### Storage Configuration Management
For each model, you can update storage paths for OpenVINO compatibility:
```
📁 Storage Configuration for 'mnist-model':
   Current path: models/mnist/
   Current storageUri: s3://my-bucket/mnist/

🤔 Do you want to update the storage configuration for this model?
   1) Keep current configuration
   2) Enter a new path S3 OpenVINO versioned compatible 'storage.path'
   3) Enter a new URI (storageUri)
   4) Skip this model

Your choice (1/2/3/4): 2
📝 Enter the new storage path (e.g., openvino/mnist/):
New path: models/mnist/1/
✅ Updated path to: models/mnist/1/
```

### Authentication and Route Preservation
The script automatically detects and preserves:
- Route exposure settings (`networking.kserve.io/visibility=exposed`)
- Authentication configuration (`security.opendatahub.io/enable-auth=true`)
- Service account creation and RBAC setup

## Troubleshooting

### Common Issues

**Error: You are not logged into an OpenShift cluster**
```bash
oc login https://your-cluster-url:6443
```

**Error: Source namespace does not have 'modelmesh-enabled' label**
```bash
oc label namespace your-namespace modelmesh-enabled=true
```

**Error: Target namespace already exists**
- Use `--ignore-existing-ns` flag or delete the existing namespace

**Error: Missing dependencies**
- Install required tools: `oc`, `yq`, `openssl`

### Debug Mode
Use `--debug` to see complete YAML resources before applying:
```bash
./modelmesh-to-raw.sh --from-ns source --target-ns target --debug
```

## Help

```bash
./modelmesh-to-raw.sh --help
```

```
ModelMesh to KServe Raw Deployment Migration Helper

USAGE:
    ./modelmesh-to-raw.sh --from-ns <source-namespace> --target-ns <target-namespace> [OPTIONS]

PARAMETERS:
    --from-ns <namespace>      Source namespace containing ModelMesh InferenceServices
    --target-ns <namespace>    Target namespace for KServe Raw deployment
    --ignore-existing-ns       Skip check if target namespace already exists
    --debug                    Show complete processed resources and wait for user confirmation
    --dry-run                  Save all YAML resources to local directory without applying them
    --page-size <number>       Number of InferenceServices to display per page (default: 10)
    -h, --help                 Show this help message

DESCRIPTION:
    This script migrates InferenceServices from ModelMesh to KServe Raw deployment.
    It will copy models from the source namespace to the target namespace and
    convert them to use KServe Raw deployment method.

    For namespaces with many InferenceServices, use --page-size to control pagination.

EXAMPLES:
    ./modelmesh-to-raw.sh --from-ns modelmesh-serving --target-ns kserve-raw
    ./modelmesh-to-raw.sh --from-ns my-models --target-ns my-models-raw --page-size 5
    ./modelmesh-to-raw.sh --from-ns modelmesh-serving --target-ns kserve-raw --ignore-existing-ns --page-size 20
    ./modelmesh-to-raw.sh --from-ns large-ns --target-ns kserve-raw --dry-run --page-size 50

REQUIREMENTS:
    - oc (OpenShift CLI)
    - yq (YAML processor)
    - Access to both source and target namespaces
```