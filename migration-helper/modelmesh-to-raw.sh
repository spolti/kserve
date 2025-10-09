#!/bin/bash

# ModelMesh to KServe Raw Deployment Migration Helper Script
# This script helps migrate models from ModelMesh to KServe Raw deployment

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Symbols
SUCCESS_SYMBOL="${GREEN}✓${NC}"
ERROR_SYMBOL="${RED}✗${NC}"

# Global variables
ERRORS=()
ORIGINAL_ISVCS=()
SELECTED_ISVCS=()
VALIDATED_TEMPLATE=""
VALIDATED_TEMPLATE_NAME=""
AVAILABLE_TEMPLATES=""
TEMPLATE_ARRAY=()
TEMPLATE_DISPLAY_ARRAY=()
LAST_APPLY_OUTPUT=""
SELECTED_SECRET_FOR_ISVC=""


# Check if required binaries are installed
check_dependencies() {
    local missing_deps=()

    if ! command -v oc &> /dev/null; then
        missing_deps+=("oc")
    fi

    if ! command -v yq &> /dev/null; then
        missing_deps+=("yq")
    fi

    if ! command -v openssl &> /dev/null; then
        missing_deps+=("openssl")
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${ERROR_SYMBOL} Error: The following required dependencies are missing:"
        printf '  - %s\n' "${missing_deps[@]}"
        echo ""
        echo "Please install the missing dependencies and try again."
        echo "  - oc: OpenShift CLI (https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html)"
        echo "  - yq: Command-line YAML/JSON processor (https://mikefarah.gitbook.io/yq/)"
        exit 1
    fi
}

# Parse command line arguments
parse_arguments() {
    FROM_NS=""
    TARGET_NS=""
    IGNORE_EXISTING_NS=false
    DEBUG_MODE=false
    DRY_RUN=false
    DRY_RUN_DIR=""
    PAGE_SIZE=10
    USE_ODH=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --from-ns)
                FROM_NS="$2"
                shift 2
                ;;
            --target-ns)
                TARGET_NS="$2"
                shift 2
                ;;
            --ignore-existing-ns)
                IGNORE_EXISTING_NS=true
                shift 1
                ;;
            --debug)
                DEBUG_MODE=true
                shift 1
                ;;
            --dry-run)
                DRY_RUN=true
                shift 1
                ;;
            --odh)
                USE_ODH=true
                shift 1
                ;;
            --page-size)
                PAGE_SIZE="$2"
                # Validate that PAGE_SIZE is a positive integer
                if ! [[ "$PAGE_SIZE" =~ ^[1-9][0-9]*$ ]]; then
                    echo -e "${ERROR_SYMBOL} Error: --page-size must be a positive integer (got: $PAGE_SIZE)"
                    exit 1
                fi
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo -e "${ERROR_SYMBOL} Error: Unknown parameter $1"
                show_help
                exit 1
                ;;
        esac
    done

    # Validate required parameters
    if [[ -z "$FROM_NS" ]]; then
        echo -e "${ERROR_SYMBOL} Error: --from-ns parameter is required"
        show_help
        exit 1
    fi

    if [[ -z "$TARGET_NS" ]]; then
        echo -e "${ERROR_SYMBOL} Error: --target-ns parameter is required"
        show_help
        exit 1
    fi

    if [[ "$FROM_NS" == "$TARGET_NS" ]]; then
        echo -e "${ERROR_SYMBOL} Error: --from-ns and --target-ns cannot be the same"
        exit 1
    fi
}

# Show help information
show_help() {
    cat << EOF
ModelMesh to KServe Raw Deployment Migration Helper

USAGE:
    $0 --from-ns <source-namespace> --target-ns <target-namespace> [OPTIONS]

PARAMETERS:
    --from-ns <namespace>      Source namespace containing ModelMesh InferenceServices
    --target-ns <namespace>    Target namespace for KServe Raw deployment
    --ignore-existing-ns       Skip check if target namespace already exists
    --debug                    Show complete processed resources and wait for user confirmation
    --dry-run                  Save all YAML resources to local directory without applying them
    --odh                      Use OpenDataHub template namespace (opendatahub) instead of RHOAI (redhat-ods-applications)
    --page-size <number>       Number of InferenceServices to display per page (default: 10)
    -h, --help                 Show this help message

DESCRIPTION:
    This script migrates InferenceServices from ModelMesh to KServe Raw deployment.
    It will copy models from the source namespace to the target namespace and
    convert them to use KServe Raw deployment method.

    For namespaces with many InferenceServices, use --page-size to control pagination.

EXAMPLES:
    $0 --from-ns modelmesh-serving --target-ns kserve-raw
    $0 --from-ns my-models --target-ns my-models-raw --page-size 5
    $0 --from-ns modelmesh-serving --target-ns kserve-raw --ignore-existing-ns --page-size 20
    $0 --from-ns large-ns --target-ns kserve-raw --dry-run --page-size 50
    $0 --from-ns modelmesh-serving --target-ns kserve-raw --odh

REQUIREMENTS:
    - oc (OpenShift CLI)
    - yq (YAML processor)
    - Access to both source and target namespaces

EOF
}

# Check if user is logged into OpenShift cluster
check_openshift_login() {
    echo "🔍 Checking OpenShift login status..."

    if ! oc whoami &> /dev/null; then
        echo -e "${ERROR_SYMBOL} Error: You are not logged into an OpenShift cluster."
        echo "📝 Please login using 'oc login' and try again."
        echo ""
        echo "💡 Example:"
        echo "  oc login https://your-cluster-url:6443"
        exit 1
    fi

    local current_user=$(oc whoami)
    local current_server=$(oc whoami --show-server)

    echo -e "${SUCCESS_SYMBOL} Logged in as: $current_user"
    echo -e "${SUCCESS_SYMBOL} Connected to: $current_server"
    echo ""
}

# Check dependencies before proceeding
check_dependencies

# Parse command line arguments
parse_arguments "$@"

# Set template namespace based on ODH flag
if [[ "$USE_ODH" == "true" ]]; then
    TEMPLATE_NAMESPACE="opendatahub"
else
    TEMPLATE_NAMESPACE="redhat-ods-applications"
fi

# Check OpenShift login status
check_openshift_login

# Initialize dry-run directory structure
initialize_dry_run_directory() {
    if [[ "$DRY_RUN" != "true" ]]; then
        return
    fi

    DRY_RUN_DIR="migration-dry-run-$(date +%Y%m%d-%H%M%S)"
    echo "📁 Initializing dry-run directory: $DRY_RUN_DIR"

    mkdir -p "$DRY_RUN_DIR"/{original-resources,new-resources}/{namespace,servingruntime,inferenceservice,secret,role,rolebinding,serviceaccount}

    echo -e "${SUCCESS_SYMBOL} Created dry-run directory structure: $DRY_RUN_DIR"
    echo ""
}

# Save YAML resource to file in dry-run mode
save_dry_run_resource() {
    local resource_type="$1"
    local resource_name="$2"
    local resource_yaml="$3"
    local category="$4"  # "original-resources" or "new-resources"

    if [[ "$DRY_RUN" != "true" ]]; then
        return
    fi

    local filename="${DRY_RUN_DIR}/${category}/${resource_type}/${resource_name}.yaml"
    echo "$resource_yaml" > "$filename"
    echo "💾 Saved $resource_type '$resource_name' to: $filename"
}

# Save original ModelMesh resource for review
save_original_resource() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="$3"

    if [[ "$DRY_RUN" != "true" ]]; then
        return
    fi

    echo "📋 Saving original $resource_type '$resource_name' from namespace '$namespace'..."
    local resource_yaml=$(oc get "$resource_type" "$resource_name" -n "$namespace" -o yaml 2>/dev/null)

    if [[ $? -eq 0 ]]; then
        save_dry_run_resource "$resource_type" "${resource_name}-original" "$resource_yaml" "original-resources"
    else
        echo "⚠️  Warning: Could not retrieve original $resource_type '$resource_name' from '$namespace'"
    fi
}

# Apply resource or save to file in dry-run mode
apply_or_save_resource() {
    local resource_type="$1"
    local resource_name="$2"
    local resource_yaml="$3"
    local target_namespace="$4"

    if [[ "$DRY_RUN" == "true" ]]; then
        save_dry_run_resource "$resource_type" "$resource_name" "$resource_yaml" "new-resources"
        echo -e "${SUCCESS_SYMBOL} [DRY-RUN] Would create $resource_type '$resource_name' in namespace '$target_namespace'"
        return 0
    else
        # Normal apply logic
        LAST_APPLY_OUTPUT=$(echo "$resource_yaml" | oc apply -n "$target_namespace" -f - 2>&1)
        return $?
    fi
}

# Helper function for debug output
debug_resource() {
    local resource_type="$1"
    local resource_name="$2"
    local resource_yaml="$3"

    if [[ "$DEBUG_MODE" == "true" ]]; then
        echo ""
        echo "🔍 DEBUG MODE: Showing complete $resource_type YAML for '$resource_name'"
        echo "================================================================="
        echo "$resource_yaml"
        echo "================================================================="
        echo ""
        echo "Press any key to continue with applying this $resource_type..."
        read -n 1 -s
        echo ""
    fi
}

# Verify that source namespace has ModelMesh enabled
verify_modelmesh_namespace() {
    echo "🔍 Verifying ModelMesh configuration in source namespace..."

    # Check if namespace exists
    if ! oc get namespace "$FROM_NS" &> /dev/null; then
        echo -e "${ERROR_SYMBOL} Error: Source namespace '$FROM_NS' does not exist."
        exit 1
    fi

    # Check if modelmesh-enabled label exists and is set to true
    local modelmesh_enabled=$(oc get namespace "$FROM_NS" -o jsonpath='{.metadata.labels.modelmesh-enabled}' 2>/dev/null || echo "")

    if [[ -z "$modelmesh_enabled" ]]; then
        echo -e "${ERROR_SYMBOL} Error: Source namespace '$FROM_NS' does not have the 'modelmesh-enabled' label."
        echo "📋 This namespace is not configured for ModelMesh serving."
        echo ""
        echo "💡 To enable ModelMesh in a namespace, run:"
        echo "  oc label namespace $FROM_NS modelmesh-enabled=true"
        echo ""
        exit 1
    fi

    if [[ "$modelmesh_enabled" != "true" ]]; then
        echo -e "${ERROR_SYMBOL} Error: Source namespace '$FROM_NS' has 'modelmesh-enabled' set to '$modelmesh_enabled'."
        echo "📋 ModelMesh is not enabled in this namespace (must be 'true')."
        echo ""
        echo "💡 To enable ModelMesh in a namespace, run:"
        echo "  oc label namespace $FROM_NS modelmesh-enabled=true"
        echo ""
        exit 1
    fi

    echo -e "${SUCCESS_SYMBOL} ModelMesh is enabled in namespace '$FROM_NS'"
    echo ""
}

# Cache available templates to avoid repeated oc calls
cache_available_templates() {
    echo "🔍 Caching available templates from $TEMPLATE_NAMESPACE namespace..."

    # Get all templates from template namespace
    AVAILABLE_TEMPLATES=$(oc get templates -n "$TEMPLATE_NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' || echo "")

    if [[ -n "$AVAILABLE_TEMPLATES" ]]; then
        TEMPLATE_ARRAY=()
        TEMPLATE_DISPLAY_ARRAY=()

        while IFS= read -r template_name; do
            if [[ -n "$template_name" ]]; then
                TEMPLATE_ARRAY+=("$template_name")
                # Cache the description for each template
                local template_description=$(oc get template "$template_name" -n "$TEMPLATE_NAMESPACE" -o jsonpath='{.metadata.annotations.description}' 2>/dev/null || echo "")
                TEMPLATE_DISPLAY_ARRAY+=("$template_description")
            fi
        done <<< "$AVAILABLE_TEMPLATES"

        echo -e "${SUCCESS_SYMBOL} Cached ${#TEMPLATE_ARRAY[@]} template(s) with display names from $TEMPLATE_NAMESPACE namespace"
    else
        echo "⚠️  No templates found in $TEMPLATE_NAMESPACE namespace"
    fi

    echo ""
}

# Create target namespace and configure it for KServe Raw
create_target_namespace() {
    echo "🚀 Setting up target namespace for KServe Raw deployment..."

    # Skip actual namespace creation in dry-run mode
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "📁 [DRY-RUN] skipping target namespace ['$TARGET_NS']."
        echo ""
        return 0
    fi

    # Check if target namespace already exists (unless --ignore-existing-ns is set)
    if oc get namespace "$TARGET_NS" &> /dev/null; then
        if [[ "$IGNORE_EXISTING_NS" == "true" ]]; then
            echo "⚠️  Target namespace '$TARGET_NS' already exists (ignoring due to --ignore-existing-ns)"
        else
            echo -e "${ERROR_SYMBOL} Error: Target namespace '$TARGET_NS' already exists"
            echo "📋 Please choose a different target namespace or delete the existing one."
            echo ""
            echo "💡 To delete the existing namespace, run:"
            echo "  oc delete namespace $TARGET_NS"
            echo ""
            echo "💡 Or use --ignore-existing-ns to skip this check"
            exit 1
        fi
    else
        echo "🏗️ Creating target namespace '$TARGET_NS'..."
        if oc create namespace "$TARGET_NS"; then
            echo -e "${SUCCESS_SYMBOL} Target namespace '$TARGET_NS' created successfully"
        else
            echo -e "${ERROR_SYMBOL} Error: Failed to create target namespace '$TARGET_NS'"
            exit 1
        fi
    fi

    # Apply the required label for dashboard integration
    echo "🏷️  Applying dashboard label to target namespace..."
    if oc label namespace "$TARGET_NS" opendatahub.io/dashboard="true" --overwrite; then
        echo -e "${SUCCESS_SYMBOL} Dashboard label applied to namespace '$TARGET_NS'"
    else
        echo -e "${ERROR_SYMBOL} Error: Failed to apply dashboard label to namespace '$TARGET_NS'"
        exit 1
    fi

    echo "🏷️  Applying modelmesh-enabled label to target namespace..."
    if oc label namespace "$TARGET_NS" modelmesh-enabled="false" --overwrite; then
        echo -e "${SUCCESS_SYMBOL} modelmesh-enabled label set to false on namespace '$TARGET_NS'"
    else
        echo -e "${ERROR_SYMBOL} Error: Failed to apply modelmesh-enabled label to namespace '$TARGET_NS'"
        exit 1
    fi

    echo ""
}

# List InferenceServices and get user selection
list_and_select_inference_services() {
    echo "🔍 Discovering InferenceServices in source namespace '$FROM_NS'..."

    # Initialize variables to avoid unset variable errors
    local index=0
    local isvc_count=0

    # Get all InferenceServices in the source namespace
    local isvc_list=$(oc get inferenceservice -n "$FROM_NS" -o yaml 2>/dev/null)

    if [[ $? -ne 0 ]]; then
        echo -e "${ERROR_SYMBOL} Error: Failed to retrieve InferenceServices from namespace '$FROM_NS'"
        echo "📋 Please ensure you have access to the namespace and InferenceServices exist."
        exit 1
    fi

    # Check if any InferenceServices exist
    local isvc_count=$(echo "$isvc_list" | yq '.items | length')

    if [[ "$isvc_count" -eq 0 ]]; then
        echo -e "${ERROR_SYMBOL} Error: No InferenceServices found in namespace '$FROM_NS'"
        echo "📭 There are no models to migrate."
        exit 1
    fi

    echo -e "${SUCCESS_SYMBOL} Found $isvc_count InferenceService(s) in namespace '$FROM_NS'"
    echo ""

    # Store names in an array for selection
    local isvc_names=($(echo "$isvc_list" | yq '.items[].metadata.name'))

    # Calculate pagination
    local total_pages=$(( (isvc_count + PAGE_SIZE - 1) / PAGE_SIZE ))
    local current_page=1
    local start_index=0
    local end_index=$((PAGE_SIZE - 1))

    # Pagination loop
    while true; do
        # Adjust end index for last page
        if [[ $end_index -ge $isvc_count ]]; then
            end_index=$((isvc_count - 1))
        fi

        # Display current page header
        echo "📦 InferenceServices (Page $current_page/$total_pages, showing items $((start_index + 1))-$((end_index + 1)) of $isvc_count):"
        echo "======================================================================================="

        # Display InferenceServices for current page
        for (( i=start_index; i<=end_index; i++ )); do
            local isvc_name="${isvc_names[$i]}"
            local isvc_info=$(echo "$isvc_list" | yq ".items[] | select(.metadata.name == \"$isvc_name\")")
            local status=$(echo "$isvc_info" | yq '.status.conditions[-1].type // "Unknown"')
            local runtime=$(echo "$isvc_info" | yq '.spec.predictor.model.runtime // "N/A"')
            local model_format=$(echo "$isvc_info" | yq '.spec.predictor.model.modelFormat.name // "N/A"')
            local storage=$(echo "$isvc_info" | yq '.spec.predictor.model.storage.key // .spec.predictor.model.storageUri // "N/A"')

            echo "[$((i + 1))] Name: $isvc_name"
            echo "    Status: $status"
            echo "    Runtime: $runtime"
            echo "    Model Format: $model_format"
            echo "    Storage: $storage"
            echo ""
        done

        echo ""
        echo "🤔 Selection options:"
        echo "===================="
        echo "• 'all' - Select all InferenceServices across all pages"
        echo "• '3 4' - Select specific items by number (e.g., '3 4' to select items 3 and 4)"

        # Navigation options
        if [[ $total_pages -gt 1 ]]; then
            echo ""
            echo "📄 Navigation:"
            echo "=============="
            if [[ $current_page -gt 1 ]]; then
                echo "• 'p' - Previous page"
                echo "• 'f' - First page"
            fi
            if [[ $current_page -lt $total_pages ]]; then
                echo "• 'n' - Next page"
                echo "• 'l' - Last page"
            fi
            echo "• 'goto:X' - Go to specific page X (e.g., 'goto:3')"
        fi

        echo ""
        echo "• 'q' - Quit migration"
        echo ""
        read -p "Your selection: " selection

        # Handle navigation and selection
        case "$selection" in
            "q"|"Q")
                echo "👋 Migration cancelled by user"
                exit 0
                ;;
            "all"|"ALL")
                echo -e "${SUCCESS_SYMBOL} Selected all $isvc_count InferenceService(s) for migration"
                SELECTED_ISVCS=("${isvc_names[@]}")
                break
                ;;
            "n"|"N")
                if [[ $current_page -lt $total_pages ]]; then
                    current_page=$((current_page + 1))
                    start_index=$((start_index + PAGE_SIZE))
                    end_index=$((end_index + PAGE_SIZE))
                    clear
                    echo "📄 Moving to page $current_page..."
                    echo ""
                else
                    echo "⚠️  Already on last page"
                    echo ""
                fi
                ;;
            "p"|"P")
                if [[ $current_page -gt 1 ]]; then
                    current_page=$((current_page - 1))
                    start_index=$((start_index - PAGE_SIZE))
                    end_index=$((end_index - PAGE_SIZE))
                    clear
                    echo "📄 Moving to page $current_page..."
                    echo ""
                else
                    echo "⚠️  Already on first page"
                    echo ""
                fi
                ;;
            "f"|"F")
                if [[ $current_page -gt 1 ]]; then
                    current_page=1
                    start_index=0
                    end_index=$((PAGE_SIZE - 1))
                    clear
                    echo "📄 Moving to first page..."
                    echo ""
                else
                    echo "⚠️  Already on first page"
                    echo ""
                fi
                ;;
            "l"|"L")
                if [[ $current_page -lt $total_pages ]]; then
                    current_page=$total_pages
                    start_index=$(( (total_pages - 1) * PAGE_SIZE ))
                    end_index=$(( start_index + PAGE_SIZE - 1 ))
                    clear
                    echo "📄 Moving to last page..."
                    echo ""
                else
                    echo "⚠️  Already on last page"
                    echo ""
                fi
                ;;
            goto:*)
                local target_page="${selection#goto:}"
                if [[ "$target_page" =~ ^[0-9]+$ ]] && [[ $target_page -ge 1 ]] && [[ $target_page -le $total_pages ]]; then
                    current_page=$target_page
                    start_index=$(( (current_page - 1) * PAGE_SIZE ))
                    end_index=$(( start_index + PAGE_SIZE - 1 ))
                    clear
                    echo "📄 Moving to page $current_page..."
                    echo ""
                else
                    echo -e "${ERROR_SYMBOL} Invalid page number. Valid range: 1-$total_pages"
                    echo ""
                fi
                ;;
            g:*)
                # Handle global selection (g:5 10 15)
                local global_selection="${selection#g:}"
                local selected_indices=($global_selection)
                SELECTED_ISVCS=()

                for idx in "${selected_indices[@]}"; do
                    # Validate index is a number
                    if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
                        echo -e "${ERROR_SYMBOL} Error: '$idx' is not a valid number"
                        echo ""
                        continue 2
                    fi

                    # Convert to 0-based index and validate range
                    local array_idx=$((idx - 1))
                    if [[ $array_idx -lt 0 || $array_idx -ge ${#isvc_names[@]} ]]; then
                        echo -e "${ERROR_SYMBOL} Error: Global index '$idx' is out of range (1-${#isvc_names[@]})"
                        echo ""
                        continue 2
                    fi

                    # Add to selected list
                    SELECTED_ISVCS+=("${isvc_names[$array_idx]}")
                done

                if [[ ${#SELECTED_ISVCS[@]} -eq 0 ]]; then
                    echo -e "${ERROR_SYMBOL} Error: No valid InferenceServices selected"
                    echo ""
                    continue
                fi

                echo -e "${SUCCESS_SYMBOL} Selected ${#SELECTED_ISVCS[@]} InferenceService(s) for migration:"
                for isvc in "${SELECTED_ISVCS[@]}"; do
                    echo "  • $isvc"
                done
                break
                ;;
            *)
                # Handle current page selection
                local selected_indices=($selection)
                SELECTED_ISVCS=()

                for idx in "${selected_indices[@]}"; do
                    # Validate index is a number
                    if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
                        echo -e "${ERROR_SYMBOL} Error: '$idx' is not a valid number"
                        echo ""
                        continue 2
                    fi

                    # Convert to current page index and validate range
                    local page_idx=$((idx - 1))
                    local items_on_current_page=$((end_index - start_index + 1))
                    if [[ $page_idx -lt 0 || $page_idx -ge $items_on_current_page ]]; then
                        echo -e "${ERROR_SYMBOL} Error: Index '$idx' is out of range for current page (1-$items_on_current_page)"
                        echo ""
                        continue 2
                    fi

                    # Convert to global array index
                    local global_array_idx=$((start_index + page_idx))
                    SELECTED_ISVCS+=("${isvc_names[$global_array_idx]}")
                done

                if [[ ${#SELECTED_ISVCS[@]} -eq 0 ]]; then
                    echo -e "${ERROR_SYMBOL} Error: No valid InferenceServices selected"
                    echo ""
                    continue
                fi

                echo -e "${SUCCESS_SYMBOL} Selected ${#SELECTED_ISVCS[@]} InferenceService(s) for migration:"
                for isvc in "${SELECTED_ISVCS[@]}"; do
                    echo "  • $isvc"
                done
                break
                ;;
        esac
    done

    echo ""
}

# Validate custom ServingRuntime and determine appropriate template
validate_custom_runtime() {
    local original_runtime="$1"
    local isvc_name="$2"

    echo "  🔍 Validating custom ServingRuntime '$original_runtime' for model '$isvc_name'..."

    local selected_template=$(select_template_interactively "custom" "$original_runtime" "$isvc_name")

    VALIDATED_TEMPLATE="$selected_template"
    VALIDATED_TEMPLATE_NAME="$selected_template"

    echo "  📋 Will use template: $VALIDATED_TEMPLATE"
    echo ""
}

# Interactive template selection with list and manual entry options
select_template_interactively() {
    local context="$1"  # "missing" or "custom"
    local original_runtime="$2"
    local isvc_name="$3"
    local selected_template=""

    if [[ "$context" == "missing" ]]; then
        echo "  ⚠️  No original runtime specified for '$isvc_name'" >&2
        echo "  🔍 This might indicate that serving runtimes are not available in the source namespace" >&2
    else
        echo "  🚨 Custom ServingRuntime detected: '$original_runtime'" >&2
        echo "  📝 Custom ServingRuntime '$original_runtime' requires a template from redhat-ods-applications namespace." >&2
    fi

    echo "" >&2
    echo "  🤔 Please select a template for model '$isvc_name' from the available ones:" >&2
    echo "  =========================================================================================" >&2

    # Use cached templates instead of making new oc calls
    if [[ ${#TEMPLATE_ARRAY[@]} -gt 0 ]]; then
        if [[ ${#TEMPLATE_ARRAY[@]} -gt 0 ]]; then
            for i in "${!TEMPLATE_ARRAY[@]}"; do
                local template_name="${TEMPLATE_ARRAY[$i]}"
                local template_display="${TEMPLATE_DISPLAY_ARRAY[$i]}"
                echo "    [$((i+1))] $template_name ($template_display)" >&2
            done
            echo "    [d] Use default: kserve-ovms (OpenVINO Model Server)" >&2
            echo "    [m] Enter template name manually" >&2
            echo "" >&2
            read -p "  Your choice (1-${#TEMPLATE_ARRAY[@]}/d/m): " template_choice

            case "$template_choice" in
                "d"|"D"|"")
                    echo "  ✅ Using default: kserve-ovms (OpenVINO Model Server)" >&2
                    selected_template="kserve-ovms"
                    ;;
                "m"|"M")
                    selected_template=$(get_manual_template_name)
                    ;;
                *)
                    # Validate numeric choice
                    if [[ "$template_choice" =~ ^[0-9]+$ ]] && [[ $template_choice -ge 1 ]] && [[ $template_choice -le ${#TEMPLATE_ARRAY[@]} ]]; then
                        selected_template="${TEMPLATE_ARRAY[$((template_choice-1))]}"
                        echo "  ✅ Selected template: $selected_template" >&2
                    else
                        echo "  ⚠️  Invalid choice, defaulting to OpenVINO Model Server" >&2
                        selected_template="kserve-ovms"
                    fi
                    ;;
            esac
        else
            echo "  ⚠️  No kserve templates found, defaulting to OpenVINO Model Server" >&2
            selected_template="kserve-ovms"
        fi
    else
        echo "  ⚠️  Could not retrieve templates from redhat-ods-applications namespace" >&2
        echo "  📋 Defaulting to OpenVINO Model Server" >&2
        selected_template="kserve-ovms"
    fi

    # Return the selected template
    echo "$selected_template"
}

# Handle manual template name entry with validation
get_manual_template_name() {
    echo "  📝 Enter template name manually:"
    echo "  💡 Available templates can be listed with:"
    echo "     oc get templates -n $TEMPLATE_NAMESPACE | grep kserve"
    echo ""

    while true; do
        read -p "  Template name: " manual_template

        if [[ -z "$manual_template" ]]; then
            echo "  ⚠️  Empty template name provided" >&2
            echo "  🤔 Options:" >&2
            echo "    1) Enter a different template name" >&2
            echo "    2) Use default (kserve-ovms)" >&2
            echo "" >&2
            read -p "  Your choice (1/2): " retry_choice

            case "$retry_choice" in
                "1")
                    continue
                    ;;
                *)
                    echo "  ✅ Using default: kserve-ovms (OpenVINO Model Server)" >&2
                    echo "kserve-ovms"
                    return
                    ;;
            esac
        else
            # Validate that the manually entered template exists
            echo "  🔍 Validating template '$manual_template' in $TEMPLATE_NAMESPACE namespace..."

            if oc get template "$manual_template" -n "$TEMPLATE_NAMESPACE" &> /dev/null; then
                echo "  ✅ Template '$manual_template' found and validated" >&2
                echo "$manual_template"
                return
            else
                echo "  ❌ Template '$manual_template' not found in $TEMPLATE_NAMESPACE namespace" >&2
                echo "  🤔 Options:" >&2
                echo "    1) Enter a different template name" >&2
                echo "    2) Use default (kserve-ovms)" >&2
                echo "" >&2
                read -p "  Your choice (1/2): " retry_choice

                case "$retry_choice" in
                    "1")
                        continue
                        ;;
                    *)
                        echo "  ✅ Using default: kserve-ovms (OpenVINO Model Server)" >&2
                        echo "kserve-ovms"
                        return
                        ;;
                esac
            fi
        fi
    done
}

# Get custom template name from user with validation (legacy function - now uses new interactive selection)
get_custom_template_name() {
    local original_runtime="$1"
    local isvc_name="$2"

    local selected_template=$(select_template_interactively "custom" "$original_runtime" "$isvc_name")

    VALIDATED_TEMPLATE="$selected_template"
    VALIDATED_TEMPLATE_NAME="$selected_template"

    echo "  📋 Will use custom template: $VALIDATED_TEMPLATE"
    echo ""
}

# Create serving runtimes for selected models
create_serving_runtimes() {
    echo "🔧 Preparing serving runtimes for selected models..."

    # Initialize arrays to avoid unset variable errors with set -u
    local runtime_templates=()
    local runtime_names=()

    # Analyze each selected InferenceService to determine required runtime
    local index=0

    echo "🔍 Analyzing original ServingRuntimes for each model..."
    for isvc_name in "${SELECTED_ISVCS[@]}"; do
        echo "📋 Checking original runtime for model '$isvc_name'..."

        # Get the original InferenceService
        local original_isvc=$(oc get inferenceservice "$isvc_name" -n "$FROM_NS" -o yaml 2>&1)
        if [[ $? -ne 0 ]]; then
            ERRORS+=("Failed to get InferenceService '$isvc_name' from '$FROM_NS': $original_isvc")
            index=$((index+1))
            continue
        fi

        # Get the runtime name from the InferenceService spec
        local runtime_name=$(echo "$original_isvc" | yq '.spec.predictor.model.runtime // ""')

        # Query the actual ServingRuntime in the namespace to get its template display name
        local original_runtime=""
        if [[ -n "$runtime_name" ]]; then
            original_runtime=$(oc get servingruntime "$runtime_name" -n "$FROM_NS" -o jsonpath='{.metadata.annotations.opendatahub\.io/template-name}' 2>/dev/null || echo "")
        fi
        if [[ -z "$original_runtime" ]]; then
            local selected_template=$(select_template_interactively "missing" "" "$isvc_name")
            runtime_templates+=("$selected_template")
            runtime_names+=("$selected_template")
        else
            echo "  📦 Original runtime: $original_runtime"

            # Check if the runtime name is exactly ovms
            if [[ "$original_runtime" == "ovms" ]]; then
                echo "  ${SUCCESS_SYMBOL} Detected OpenVINO Model Server runtime, using kserve-ovms template"
                runtime_templates+=("kserve-ovms")
                runtime_names+=("kserve-ovms")
            else
                # Custom runtime detected - validate with user
                validate_custom_runtime "$original_runtime" "$isvc_name"
                runtime_templates+=("$VALIDATED_TEMPLATE")
                runtime_names+=("$VALIDATED_TEMPLATE_NAME")
            fi
        fi

        index=$((index+1))
    done

    echo ""
    echo "🔧 Creating serving runtimes based on analysis..."

    # Create serving runtimes for each model with their appropriate template
    index=0
    for isvc_name in "${SELECTED_ISVCS[@]}"; do
        local template_name="${runtime_templates[$index]}"
        local template_display_name="${runtime_names[$index]}"

        echo "🏗️ Creating serving runtime for model '$isvc_name' using template '$template_name'..."

        # Get the template from template namespace
        local runtime_template=$(oc get template "$template_name" -n "$TEMPLATE_NAMESPACE" -o yaml 2>/dev/null)

        if [[ $? -ne 0 ]]; then
            echo -e "${ERROR_SYMBOL} Error: Failed to retrieve '$template_name' template from $TEMPLATE_NAMESPACE namespace"
            echo "📋 Please ensure the template '$template_name' exists in the $TEMPLATE_NAMESPACE namespace."
            exit 1
        fi

        echo -e "  ${SUCCESS_SYMBOL} Retrieved template '$template_name' from $TEMPLATE_NAMESPACE namespace"

        # Get template display name from the template
        # TODO seee if it is needed, we can inherit it from the template as we are not going to update it
        local template_display=$(echo "$runtime_template" | yq '.objects[0].metadata.annotations."opendatahub.io/template-display-name" // "Custom Runtime"')

        # Prepare the template to be applied
        local modified_runtime=$(echo "$runtime_template" | \
            yq '.objects[0].metadata.name = "'$isvc_name'"' | \
            yq '.objects[0].metadata.annotations."opendatahub.io/template-name" = "'$template_name'"' | \
            yq '.objects[0].metadata.annotations."opendatahub.io/serving-runtime-scope" = "global"' | \
            yq '.objects[0].metadata.annotations."openshift.io/display-name" = "'$isvc_name'"' | \
            yq '.objects[0].metadata.annotations."opendatahub.io/apiProtocol" = "REST"' | \
            yq '.objects[0].metadata.annotations."opendatahub.io/hardware-profile-name" = "small-serving-1bmle"' | \
            yq '.metadata.name = "'$isvc_name'"' | \
            yq '.metadata.namespace = "'$TARGET_NS'"' | \
            yq '.metadata.labels."opendatahub.io/dashboard" = "true"' | \
            yq '.metadata.annotations."migration.kserve.io/source" = "modelmesh"' )

        # Save original serving runtime for review in dry-run mode
        save_original_resource "servingruntime" "$runtime_name" "$FROM_NS"

        # Apply the serving runtime to the target namespace
        local processed_runtime=$(echo "$modified_runtime" | oc process -f -)
        if apply_or_save_resource "servingruntime" "$isvc_name" "$processed_runtime" "$TARGET_NS"; then
            echo -e "  ${SUCCESS_SYMBOL} Created serving runtime '$isvc_name' in namespace '$TARGET_NS' using template '$template_name'"
        else
            ERRORS+=("Failed to create serving runtime '$isvc_name' in namespace '$TARGET_NS': $LAST_APPLY_OUTPUT")
        fi

        # Increment index for next iteration
        index=$((index+1))
    done

    # Check if there were any errors during serving runtime creation
    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        echo ""
        echo -e "${ERROR_SYMBOL} Errors occurred during serving runtime creation:"
        for error in "${ERRORS[@]}"; do
            echo "  • $error"
        done
        echo ""
        echo "💡 Common issues and solutions:"
        echo "  - Permission denied: Ensure you have admin rights on the target namespace"
        echo "  - Resource already exists: Use --ignore-existing-ns or delete existing resources"
        echo "  - Template not found: Verify the template exists in redhat-ods-applications namespace"
        echo "  - Invalid YAML: Check template processing and yq syntax"
        exit 1
    fi

    echo ""
    echo -e "${SUCCESS_SYMBOL} All serving runtimes created successfully"
    echo ""
}

# Clone storage-config and handle user secrets
clone_storage_secrets() {
    local current_isvc="$1"
    local storage_path="$2"
    local storage_uri="$3"
    local current_storage_key="$4"
    echo ""
    echo "🔐 Secret Management for InferenceService '$current_isvc'"
    echo "======================================================="
    echo "📁 Current Storage Configuration:"
    echo "   Path: ${storage_path:-"(not set)"}"
    echo "   URI: ${storage_uri:-"(not set)"}"

    # Get all secrets in the source namespace that might be user-provided
    local user_secrets=$(oc get secrets -n "$FROM_NS" -o yaml 2>/dev/null | \
        yq '.items[] | select(.type == "Opaque" and .metadata.name != "storage-config") | .metadata.name' 2>/dev/null || echo "")

    if [[ -n "$user_secrets" ]]; then
        echo ""
        echo "📋 Found the following secrets in source namespace:"
        echo "==================================================="

        local secret_array=()
        local prioritized_secret=""

        # First pass: collect all secrets and check for storage key match
        local temp_secrets=()
        while IFS= read -r secret_name; do
            if [[ -n "$secret_name" ]]; then
                temp_secrets+=("$secret_name")
                # Check if this secret matches the current storage key
                if [[ -n "$current_storage_key" && "$secret_name" == "$current_storage_key" ]]; then
                    prioritized_secret="$secret_name"
                fi
            fi
        done <<< "$user_secrets"

        # If no storage key match found but we have a storage URI, check for URI field matches
        if [[ -z "$prioritized_secret" && -n "$current_storage_uri" ]]; then
            echo "🔍 No storage key found, checking for URI field matches in secrets..."
            for secret_name in "${temp_secrets[@]}"; do
                # Get the secret and check if it has a URI field
                local secret_data=$(oc get secret "$secret_name" -n "$FROM_NS" -o jsonpath='{.data.URI}' 2>/dev/null || echo "")
                if [[ -n "$secret_data" ]]; then
                    # Decode the base64 URI field
                    local decoded_uri=$(echo "$secret_data" | base64 -d 2>/dev/null || echo "")
                    if [[ -n "$decoded_uri" && "$decoded_uri" == "$current_storage_uri" ]]; then
                        prioritized_secret="$secret_name"
                        echo "  ✅ Found URI match in secret '$secret_name': $decoded_uri"
                        break
                    else
                        echo "  🔍 Secret '$secret_name' URI: $decoded_uri (no match)"
                    fi
                else
                    echo "  ℹ️  Secret '$secret_name' does not contain URI field"
                fi
            done
        fi

        # Build final array with prioritized secret first
        if [[ -n "$prioritized_secret" ]]; then
            secret_array+=("$prioritized_secret")
            # Add remaining secrets (excluding the prioritized one)
            for secret in "${temp_secrets[@]}"; do
                if [[ "$secret" != "$prioritized_secret" ]]; then
                    secret_array+=("$secret")
                fi
            done
        else
            secret_array=("${temp_secrets[@]}")
        fi

        # Display secrets with hints
        local index=1
        for secret_name in "${secret_array[@]}"; do
            if [[ -n "$prioritized_secret" && "$secret_name" == "$prioritized_secret" ]]; then
                echo "  [$index] $secret_name (referenced by current model)"
            else
                echo "  [$index] $secret_name"
            fi
            index=$((index+1))
        done

        if [[ ${#secret_array[@]} -gt 0 ]]; then
            echo ""
            echo "🤔 Do you want to clone any of these secrets to the target namespace?"
            echo "Enter 'all' to clone all secrets"
            echo "Enter specific numbers separated by spaces (e.g., '1 3 5')"
            echo "Enter 'none' to skip"
            echo "Default: 1"
            read -p "Your selection [1]: " secret_selection

            # Set default to first secret if empty input
            if [[ -z "$secret_selection" ]]; then
                secret_selection="1"
                echo "✅ Using default selection: 1 (${secret_array[0]})"
            fi

            case "$secret_selection" in
                "none"|"NONE")
                    echo "⏭️  Skipping secret cloning as requested"
                    ;;
                "all"|"ALL")
                    echo "🔄 Cloning all user secrets..."
                    for secret_name in "${secret_array[@]}"; do
                        clone_user_secret "$secret_name"
                    done
                    ;;
                *)
                    # Parse specific selections and validate each one
                    local selected_indices=($secret_selection)
                    local valid_selections=()
                    local invalid_selections=()

                    # Validate all selections first
                    for idx in "${selected_indices[@]}"; do
                        # Validate index is a number
                        if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
                            invalid_selections+=("$idx")
                            continue
                        fi

                        # Convert to 0-based index and validate range
                        local array_idx=$((idx - 1))
                        if [[ $array_idx -lt 0 || $array_idx -ge ${#secret_array[@]} ]]; then
                            invalid_selections+=("$idx")
                        else
                            # Add the corresponding secret name to valid selections
                            valid_selections+=("${secret_array[$array_idx]}")
                        fi
                    done

                    # Report invalid selections
                    if [[ ${#invalid_selections[@]} -gt 0 ]]; then
                        echo -e "${ERROR_SYMBOL} Invalid selection(s): ${invalid_selections[*]}"
                        echo "Valid range: 1-${#secret_array[@]}"
                        echo ""

                        if [[ ${#valid_selections[@]} -eq 0 ]]; then
                            echo "❌ No valid secrets selected. Using default: 1 (${secret_array[0]})"
                            valid_selections=("${secret_array[0]}")
                        else
                            echo "✅ Proceeding with valid selections: ${valid_selections[*]}"
                        fi
                    fi

                    # Clone valid selections
                    echo "🔄 Cloning selected user secrets..."
                    for secret_name in "${valid_selections[@]}"; do
                        clone_user_secret "$secret_name"
                    done
                    # Set the first selected secret as the storage secret
                    SELECTED_SECRET_FOR_ISVC="${valid_selections[0]}"
                    ;;
            esac
        fi
    else
        echo "ℹ️  No additional user secrets found in source namespace '$FROM_NS'"
    fi

    # Check if there were any errors during secret cloning
    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        echo ""
        echo -e "${ERROR_SYMBOL} Errors occurred during secret cloning:"
        for error in "${ERRORS[@]}"; do
            echo "  • $error"
        done
        echo ""
        echo "💡 Common issues and solutions:"
        echo "  - Permission denied: Ensure you have access to secrets in both namespaces"
        echo "  - Secret already exists: Delete existing secrets in target namespace"
        echo "  - Invalid YAML: Check secret transformation and yq syntax"
        exit 1
    fi

    echo ""
    echo -e "${SUCCESS_SYMBOL} Secret management completed for InferenceService '$current_isvc'"
    echo ""
}

# Helper function to clone individual user secrets
clone_user_secret() {
    local secret_name="$1"

    echo "  🔍 Checking if secret '$secret_name' already exists in target namespace '$TARGET_NS'..."

    # Check if secret already exists in target namespace
    if oc get secret "$secret_name" -n "$TARGET_NS" &> /dev/null; then
        echo "  ℹ️  Secret '$secret_name' already exists in target namespace '$TARGET_NS'"

        # Also check if storage-config exists - if not, force apply
        if oc get secret "storage-config" -n "$TARGET_NS" &> /dev/null; then
            echo "  🤔 This is common when migrating multiple models that share storage configuration."
            echo "  ✅ Skipping creation and continuing with existing secret..."
            return 0
        else
            echo "  ⚠️  However, 'storage-config' secret does not exist in target namespace"
            echo "  🔄 Forcing recreation to ensure proper storage configuration..."
        fi
    fi

    echo "  🔄 Secret '$secret_name' not found in target namespace, proceeding with cloning..."

    local secret_yaml=$(oc get secret "$secret_name" -n "$FROM_NS" -o yaml 2>&1)
    if [[ $? -ne 0 ]]; then
        ERRORS+=("Failed to get secret '$secret_name' from '$FROM_NS': $secret_yaml")
        return
    fi

    # Transform the secret for target namespace
    local transformed_secret=$(echo "$secret_yaml" | \
        yq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.generation, .metadata.creationTimestamp)' | \
        yq '.metadata.namespace = "'$TARGET_NS'"' | \
        yq '.metadata.annotations."migration.kserve.io/source" = "modelmesh"' | \
        yq '.metadata.annotations."migration.kserve.io/original-namespace" = "'$FROM_NS'"')

    # Save original secret for review in dry-run mode
    save_original_resource "secret" "$secret_name" "$FROM_NS"

    # Apply the secret to target namespace
    if apply_or_save_resource "secret" "$secret_name" "$transformed_secret" "$TARGET_NS"; then
        echo -e " ${SUCCESS_SYMBOL} Cloned secret '$secret_name' to namespace '$TARGET_NS'"
    else
        ERRORS+=("Failed to clone secret '$secret_name' to namespace '$TARGET_NS': $LAST_APPLY_OUTPUT")
    fi
}

# Copy authentication resources for InferenceService from source namespace
copy_authentication_resources() {
    local isvc_name="$1"
    local original_runtime="$2"

    # Initialize variables to avoid unset variable errors
    local i=0
    local attempt=1
    local max_attempts=5
    local secret_persisted=false

    echo "🔐 Copying authentication resources for '$isvc_name' from source namespace..."

    # Expected resource names based on the pattern
    # For source namespace: use original ModelMesh runtime name
    local source_sa_name="${original_runtime}-sa"
    local source_role_name="${original_runtime}-view-role"
    local source_rolebinding_name="${original_runtime}-view"

    # For target namespace: use new InferenceService name
    local target_sa_name="${isvc_name}-sa"
    local target_role_name="${isvc_name}-view-role"
    local target_rolebinding_name="${isvc_name}-view"

    # Get InferenceService UID for owner reference
    local isvc_uid=$(oc get inferenceservice "$isvc_name" -n "$TARGET_NS" -o jsonpath='{.metadata.uid}' 2>/dev/null)
    if [[ -z "$isvc_uid" ]]; then
        echo "⚠️  Warning: Could not get UID for InferenceService '$isvc_name', creating Role without owner reference"
        local owner_ref_yaml=""
    else
        # used by the role, role_binding and service account
        local owner_ref_yaml="  ownerReferences:
        - apiVersion: serving.kserve.io/v1beta1
          kind: InferenceService
          name: ${isvc_name}
          uid: ${isvc_uid}
          blockOwnerDeletion: false"
    fi

    # Create new ServiceAccount (not copied from source namespace)
    echo "  🔄 Creating ServiceAccount '$target_sa_name'..."
    local sa_yaml="kind: ServiceAccount
apiVersion: v1
metadata:
  name: ${target_sa_name}
  namespace: ${TARGET_NS}
  labels:
    opendatahub.io/dashboard: 'true'
  annotations:
    migration.kserve.io/source: modelmesh
    migration.kserve.io/original-namespace: ${FROM_NS}
${owner_ref_yaml}"

    # Debug output for ServiceAccount
    debug_resource "ServiceAccount" "$target_sa_name" "$sa_yaml"

    # Save original service account for review in dry-run mode
    save_original_resource "serviceaccount" "$source_sa_name" "$FROM_NS"

    if apply_or_save_resource "serviceaccount" "$target_sa_name" "$sa_yaml" "$TARGET_NS"; then
        echo -e "   ${SUCCESS_SYMBOL} Created ServiceAccount '$target_sa_name' in namespace '$TARGET_NS'"
    else
        ERRORS+=("Failed to create ServiceAccount '$target_sa_name' in namespace '$TARGET_NS': $LAST_APPLY_OUTPUT")
    fi

    # Create new Role (not copied from source namespace)
    echo "🔄 Creating Role '$target_role_name'..."
    local role_yaml="kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: ${target_role_name}
  namespace: ${TARGET_NS}
  labels:
    opendatahub.io/dashboard: 'true'
  annotations:
    migration.kserve.io/source: modelmesh
    migration.kserve.io/original-namespace: ${FROM_NS}
${owner_ref_yaml}
rules:
  - verbs:
      - get
    apiGroups:
      - serving.kserve.io
    resources:
      - inferenceservices
    resourceNames:
      - ${isvc_name}"

    # Debug output for Role
    debug_resource "Role" "$target_role_name" "$role_yaml"

    # Save original role for review in dry-run mode
    save_original_resource "role" "$source_role_name" "$FROM_NS"

    if apply_or_save_resource "role" "$target_role_name" "$role_yaml" "$TARGET_NS"; then
        echo -e " ${SUCCESS_SYMBOL} Created Role '$target_role_name' in namespace '$TARGET_NS'"
    else
        ERRORS+=("Failed to create Role '$target_role_name' in namespace '$TARGET_NS': $LAST_APPLY_OUTPUT")
    fi

    # Create new RoleBinding (not copied from source namespace)
    echo "🔄 Creating RoleBinding '$target_rolebinding_name'..."
    local rolebinding_yaml="kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: ${target_rolebinding_name}
  namespace: ${TARGET_NS}
  labels:
    opendatahub.io/dashboard: 'true'
  annotations:
    migration.kserve.io/source: modelmesh
    migration.kserve.io/original-namespace: ${FROM_NS}
${owner_ref_yaml}
subjects:
  - kind: ServiceAccount
    name: ${target_sa_name}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${target_role_name}"

    # Debug output for RoleBinding
    debug_resource "RoleBinding" "$target_rolebinding_name" "$rolebinding_yaml"

    # Save original rolebinding for review in dry-run mode
    save_original_resource "rolebinding" "$source_rolebinding_name" "$FROM_NS"

    if apply_or_save_resource "rolebinding" "$target_rolebinding_name" "$rolebinding_yaml" "$TARGET_NS"; then
        echo -e "${SUCCESS_SYMBOL} Created RoleBinding '$target_rolebinding_name' in namespace '$TARGET_NS'"
    else
        ERRORS+=("Failed to create RoleBinding '$target_rolebinding_name' in namespace '$TARGET_NS': $LAST_APPLY_OUTPUT")
    fi


    # Find secrets with type kubernetes.io/service-account-token that match the pattern
    # Pattern: <name_provided_by_user>-<original-serving-runtime-name>-sa
    echo "🔍 Looking for service account token secrets for original runtime '$original_runtime'..."
    local sa_token_secrets=$(oc get secrets -n "$FROM_NS" -o yaml 2>/dev/null | \
        yq '.items[] | select(.type == "kubernetes.io/service-account-token" and (.metadata.name | test(".*-'$original_runtime'-sa$"))) | .metadata.name' 2>/dev/null || echo "")

    if [[ -n "$sa_token_secrets" ]]; then
        echo ""
        echo "📋 Found the following service account token secrets for '$isvc_name':"
        echo "=================================================================="

        local secret_array=()
        while IFS= read -r secret_name; do
            if [[ -n "$secret_name" ]]; then
                secret_array+=("$secret_name")
                echo "  • $secret_name"
            fi
        done <<< "$sa_token_secrets"

        if [[ ${#secret_array[@]} -gt 0 ]]; then
            echo ""
            if [[ ${#secret_array[@]} -eq 1 ]]; then
                # Only one secret found, use it automatically
                local selected_secret="${secret_array[0]}"
                echo "${SUCCESS_SYMBOL} Automatically selecting the only available secret: $selected_secret"
            else
                # Multiple secrets found, ask user to select
                echo "🤔 Multiple service account token secrets found. Please select one:"
                for i in "${!secret_array[@]}"; do
                    echo "  [$((i+1))] ${secret_array[$i]}"
                done
                echo ""
                read -p "Your choice (1-${#secret_array[@]}): " secret_choice

                # Validate selection
                if ! [[ "$secret_choice" =~ ^[0-9]+$ ]] || [[ $secret_choice -lt 1 ]] || [[ $secret_choice -gt ${#secret_array[@]} ]]; then
                    echo -e "${ERROR_SYMBOL} Invalid selection. Skipping authentication resource copying for '$isvc_name'"
                    return
                fi

                local selected_secret="${secret_array[$((secret_choice-1))]}"
                echo "✅ Selected secret: $selected_secret"
            fi

            # Copy the selected secret
            echo "🔄 Copying secret '$selected_secret'..."
            local secret_yaml=$(oc get secret "$selected_secret" -n "$FROM_NS" -o yaml 2>&1)
            local get_exit_code=$?
            if [[ $get_exit_code -ne 0 ]]; then
                ERRORS+=("Failed to get secret '$selected_secret' from '$FROM_NS': $secret_yaml")
                echo -e "${ERROR_SYMBOL} Failed to get secret '$selected_secret' from source namespace"
            else
                echo "  ${SUCCESS_SYMBOL} Successfully retrieved secret '$selected_secret' from source namespace"

                # Create a new service account token for the target namespace
                echo "🔄 Creating new service account token for target namespace..."

                # Encode the namespace to base64
                echo "🔄 Encoding target namespace '$TARGET_NS' to base64..."
                local encoded_ns=$(echo -n "$TARGET_NS" | openssl base64 -A 2>&1)

                echo "🔄 Creating new token secret manifest..."
                local transformed_secret=$(cat <<EOF
kind: Secret
apiVersion: v1
metadata:
  name: token-${isvc_name}-sa
  namespace: ${TARGET_NS}
  labels:
    opendatahub.io/dashboard: "true"
  annotations:
    kubernetes.io/service-account.name: ${target_sa_name}
    openshift.io/display-name: ${isvc_name}
    migration.kserve.io/source: modelmesh
    migration.kserve.io/original-namespace: ${FROM_NS}
${owner_ref_yaml}
type: kubernetes.io/service-account-token
data:
  namespace: ${encoded_ns}
EOF
)
                yq_exit_code=$?
                if [[ $yq_exit_code -ne 0 ]]; then
                    echo -e "${ERROR_SYMBOL} Failed to transform secret YAML: $transformed_secret"
                    ERRORS+=("Failed to transform secret YAML: $transformed_secret")
                    return
                fi
                echo "${SUCCESS_SYMBOL} Successfully transformed secret YAML"
                echo "🔄 Applying transformed secret to target namespace..."

                echo "$transformed_secret" > /tmp/secret.yaml
                # Debug output for secret
                debug_resource "Secret" "token-$isvc_name-sa" "$transformed_secret"

                # Apply secret with persistence checking
                local secret_name="token-$isvc_name-sa"
                local max_attempts=5
                local attempt=1
                local secret_persisted=false

                while [[ $attempt -le $max_attempts ]]; do
                    echo "🔄 Attempt $attempt/$max_attempts: Applying secret '$secret_name'..."

                    local apply_output=$(echo "$transformed_secret" | oc apply -n "$TARGET_NS" -f - 2>&1)
                    local apply_exit_code=$?
                    if [[ "$DEBUG_MODE" == "true" ]]; then
                        echo "🔍 Debug: Apply exit code: $apply_exit_code | output: $apply_output"
                    fi

                    if [[ $apply_exit_code -eq 0 ]]; then
                        echo "${SUCCESS_SYMBOL} Secret applied successfully, checking persistence..."
                        # Wait a moment for any automatic deletions to occur
                        sleep 3

                        # Check if secret still exists
                        if oc get secret "$secret_name" -n "$TARGET_NS" &> /dev/null; then
                            echo -e "${SUCCESS_SYMBOL} Secret '$secret_name' persisted successfully"
                            secret_persisted=true
                            break
                        else
                            echo "⚠️  Secret '$secret_name' was deleted after creation, retrying..."
                            attempt=$((attempt+1))
                        fi
                    else
                        echo -e "${ERROR_SYMBOL} Failed to apply secret (attempt $attempt/$max_attempts): $LAST_APPLY_OUTPUT"
                        attempt=$((attempt+1))

                        if [[ $attempt -le $max_attempts ]]; then
                            echo "⏳ Waiting 5 seconds before retry..."
                            sleep 5
                        fi
                    fi
                done

                if [[ $secret_persisted == true ]]; then
                    echo -e "${SUCCESS_SYMBOL} Successfully copied and persisted secret '$selected_secret' to namespace '$TARGET_NS' as '$secret_name'"
                else
                    echo -e "${ERROR_SYMBOL} Failed to create persistent secret after $max_attempts attempts"
                    ERRORS+=("Failed to create persistent secret '$secret_name' in namespace '$TARGET_NS' after $max_attempts attempts")
                fi
            fi
        fi
    else
        echo "ℹ️  No service account token secrets found for '$isvc_name' in source namespace '$FROM_NS'"
    fi

    echo -e "${SUCCESS_SYMBOL} Authentication resource copying completed for '$isvc_name'"

}

# Update storage secret with new storageUri
update_storage_config_secret() {
    local secret_name="$1"
    local new_storage_uri="$2"

    echo "🔐 Updating secret '$secret_name' with new storageUri..."

    # Check if the secret exists in target namespace
    if ! oc get secret "$secret_name" -n "$TARGET_NS" &> /dev/null; then
        echo "ℹ️  Secret '$secret_name' not found in target namespace '$TARGET_NS', skipping secret update"
        return
    fi

    # Encode the new storage URI to base64
    local encoded_storage_uri=$(echo -n "$new_storage_uri" | base64 -w 0)

    echo "🔄 Updating data.URI field in secret '$secret_name'..."

    # Patch the secret to update the data.URI field
    local patch_output=$(oc patch secret "$secret_name" -n "$TARGET_NS" --type='json' -p="[{\"op\": \"replace\", \"path\": \"/data/URI\", \"value\": \"$encoded_storage_uri\"}]" 2>&1)

    if [[ $? -eq 0 ]]; then
        echo -e "${SUCCESS_SYMBOL} Updated secret '$secret_name' data.URI with: $new_storage_uri"
    else
        echo -e "${ERROR_SYMBOL} Failed to update secret '$secret_name': $patch_output"
        ERRORS+=("Failed to update secret '$secret_name' data.URI: $patch_output")
    fi
}

process_inference_services() {
    echo "🔄 Processing InferenceServices for Raw Deployment migration..."

    # First pass: collect all original InferenceServices
    for isvc_name in "${SELECTED_ISVCS[@]}"; do
        echo "📋 Collecting original InferenceService '$isvc_name'..."
        local original_isvc=$(oc get inferenceservice "$isvc_name" -n "$FROM_NS" -o yaml 2>&1)
        if [[ $? -ne 0 ]]; then
            ERRORS+=("Failed to get InferenceService '$isvc_name' from '$FROM_NS': $original_isvc")
            continue
        fi
        ORIGINAL_ISVCS+=("$original_isvc")
    done

    # Exit if there were errors collecting InferenceServices
    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        echo -e "${ERROR_SYMBOL} Errors occurred while collecting InferenceServices:"
        for error in "${ERRORS[@]}"; do
            echo "  • $error"
        done
        exit 1
    fi

    echo -e "${SUCCESS_SYMBOL} Collected ${#ORIGINAL_ISVCS[@]} InferenceService(s)"
    echo ""

    # Second pass: transform each InferenceService for Raw Deployment
    local index=0
    for isvc_name in "${SELECTED_ISVCS[@]}"; do
        echo "==================================================================="
        echo "🔧 Transforming InferenceService '$isvc_name' for Raw Deployment..."

        # Get the original InferenceService from the stored array
        local original_isvc="${ORIGINAL_ISVCS[$index]}"

        echo "⚙️  Analyzing storage and runtime configuration..."
        # Get current storage configuration for this model
        local current_path=$(echo "$original_isvc" | yq '.spec.predictor.model.storage.path // ""')
        local current_storage_uri=$(echo "$original_isvc" | yq '.spec.predictor.model.storageUri // ""')
        local current_storage_key=$(echo "$original_isvc" | yq '.spec.predictor.model.storage.key // ""')

        # Handle secrets for this specific inference service
        SELECTED_SECRET_FOR_ISVC=""  # Clear previous value
        local selected_storage_secret=""
        clone_storage_secrets "$isvc_name" "$current_path" "$current_storage_uri" "$current_storage_key"
        selected_storage_secret="$SELECTED_SECRET_FOR_ISVC"

        # Check if the original ServingRuntime has route exposure and authentication enabled
        local original_runtime=$(echo "$original_isvc" | yq '.spec.predictor.model.runtime // ""')
        local route_exposed=false
        local auth_enabled=false
        if [[ -n "$original_runtime" ]]; then
            echo "🔍 Checking original ServingRuntime '$original_runtime' configuration..."
            local runtime_yaml
            if ! runtime_yaml=$(oc get servingruntime "$original_runtime" -n "$FROM_NS" -o yaml 2>&1); then
                echo "  ⚠️  Could not retrieve ServingRuntime '$original_runtime': $runtime_yaml"
                runtime_yaml=""
            fi

            # Check route exposure
            local route_annotation=$(echo "$runtime_yaml" | yq '.metadata.annotations."enable-route" // ""')
            if [[ "$route_annotation" == "true" ]]; then
                route_exposed=true
                echo "  📡 Original ServingRuntime has route exposure enabled"
            else
                echo "  🔒 Original ServingRuntime does not have route exposure enabled"
            fi

            # Check authentication
            local auth_annotation=$(echo "$runtime_yaml" | yq '.metadata.annotations."enable-auth" // ""')
            echo "  🔍 Debug: auth_annotation value = '$auth_annotation'"
            if [[ "$auth_annotation" == "true" ]]; then
                auth_enabled=true
                echo "  🔐 Original ServingRuntime has authentication enabled"
            else
                echo "  🔓 Original ServingRuntime does not have authentication enabled"
            fi
        else
            echo "  ⚠️  No original runtime specified in InferenceService"
        fi

        # Ask user about updating storage configuration for OpenVINO compatibility
        echo ""
        echo "📁 Storage Configuration for '$isvc_name':"
        echo "   Current path: ${current_path:-"(not set)"}"
        echo "   Current storageUri: ${current_storage_uri:-"(not set)"}"
        echo ""
        echo "💡 OpenVINO models typically require a versioned path structure."
        echo "   For example: /models/my-model/1/ instead of /models/my-model/"
        echo ""
        echo "🤔 Do you want to update the storage configuration for this model?"
        echo "   1) Keep current configuration"
        echo "   2) Enter a new path S3 OpenVINO versioned compatible 'storage.path'"
        echo "   3) Enter a new URI (storageUri)"
        echo "   4) Skip this model"
        echo ""
        read -p "Your choice (1/2/3/4): " storage_choice

        local final_path="$current_path"
        local final_storage_uri="$current_storage_uri"
        local storage_field_to_update=""

        case "$storage_choice" in
            "1"|"")
                echo "✅ Keeping current configuration"
                echo "   Path: ${current_path:-"(not set)"}"
                echo "   StorageUri: ${current_storage_uri:-"(not set)"}"
                ;;
            "2")
                echo "📝 Enter the new storage path (e.g., openvino/mnist/):"
                read -p " --> New path: " new_path
                if [[ -n "$new_path" ]]; then
                    final_path="$new_path"
                    storage_field_to_update="path"
                    echo "  ✅ Updated path to: $final_path"
                else
                    echo "  ⚠️  Empty path provided, keeping current configuration"
                fi
                ;;
            "3")
                echo "📝 Enter the new storage URI (e.g., https://address/my/model):"
                read -p "New URI: " new_uri
                if [[ -n "$new_uri" ]]; then
                    final_storage_uri="$new_uri"
                    storage_field_to_update="storageUri"
                    echo "✅ Updated storageUri to: $final_storage_uri"
                else
                    echo "⚠️  Empty URI provided, keeping current configuration"
                fi
                ;;
            "4")
                echo "⏭️  Skipping model '$isvc_name'"
                index=$((index+1))
                continue
                ;;
            *)
                echo "⚠️  Invalid choice, keeping current configuration"
                ;;
        esac

        # Transform the InferenceService for Raw Deployment
        local transformed_isvc=$(echo "$original_isvc" | \
            yq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.generation, .metadata.creationTimestamp, .status)' | \
            yq '.metadata.namespace = "'$TARGET_NS'"' | \
            yq '.metadata.annotations."serving.kserve.io/deploymentMode" = "RawDeployment"' | \
            yq 'del(.metadata.annotations."serving.knative.dev/creator", .metadata.annotations."serving.knative.dev/lastModifier")' | \
            yq 'del(.metadata.labels."modelmesh-enabled")' | \
            yq '.spec.predictor.model.runtime = "'$isvc_name'"' | \
            yq '.spec.predictor.model.resources.requests.cpu = "1"' | \
            yq '.spec.predictor.model.resources.requests.memory = "4Gi"' | \
            yq '.spec.predictor.model.resources.limits.cpu = "2"' | \
            yq '.spec.predictor.model.resources.limits.memory = "8Gi"' | \
            yq '.metadata.annotations."migration.kserve.io/source" = "modelmesh"' | \
            yq '.metadata.annotations."migration.kserve.io/original-namespace" = "'$FROM_NS'"')

        # Apply route exposure annotation if original ServingRuntime had it enabled
        if [[ "$route_exposed" == "true" ]]; then
            transformed_isvc=$(echo "$transformed_isvc" | yq '.metadata.labels."networking.kserve.io/visibility" = "exposed"')
            echo "  📡 Applied route exposure label: networking.kserve.io/visibility=exposed"
        fi

        # Apply authentication annotation if original ServingRuntime had it enabled
        if [[ "$auth_enabled" == "true" ]]; then
            local auth_sa_name="${isvc_name}-sa"
            transformed_isvc=$(echo "$transformed_isvc" | yq '.metadata.annotations."security.opendatahub.io/enable-auth" = "true"')
            transformed_isvc=$(echo "$transformed_isvc" | yq '.spec.predictor.serviceAccountName = "'$auth_sa_name'"')
            echo "  🔐 Applied authentication annotation: security.opendatahub.io/enable-auth=true"
            echo "  🔐 Configured custom service account: $auth_sa_name"
        fi

        # Update storage configuration based on user choice
        if [[ "$storage_field_to_update" == "path" ]]; then
            transformed_isvc=$(echo "$transformed_isvc" | yq '.spec.predictor.model.storage.path = "'$final_path'"')
            echo "📁 Updated storage path in InferenceService configuration to: $final_path"
        elif [[ "$storage_field_to_update" == "storageUri" ]]; then
            transformed_isvc=$(echo "$transformed_isvc" | yq '.spec.predictor.model.storageUri = "'$final_storage_uri'"')
            echo "📁 Updated storageUri in InferenceService configuration to: $final_storage_uri"

            # Update storage-config secret if it exists and contains storageUri
            if [[ -n "$selected_storage_secret" ]]; then
                update_storage_config_secret "$selected_storage_secret" "$final_storage_uri"
            else
                echo "ℹ️  No storage secret was selected during cloning, skipping secret update"
            fi
        fi

        # Save original InferenceService for review in dry-run mode
        save_original_resource "inferenceservice" "$isvc_name" "$FROM_NS"

        # Apply the transformed InferenceService to the target namespace
        echo "🚀 Applying transformed InferenceService '$isvc_name'..."
        echo "  💾 Resources: CPU requests: 1, limits: 2 | Memory requests: 4Gi, limits: 8Gi"
        if apply_or_save_resource "inferenceservice" "$isvc_name" "$transformed_isvc" "$TARGET_NS"; then
            echo -e "${SUCCESS_SYMBOL} Created InferenceService '$isvc_name' in namespace '$TARGET_NS'"
            if [[ "$storage_field_to_update" == "path" ]]; then
                echo "  📁 Storage path updated to: $final_path"
            elif [[ "$storage_field_to_update" == "storageUri" ]]; then
                echo "  📁 StorageUri updated to: $final_storage_uri"
            fi
            if [[ "$route_exposed" == "true" ]]; then
                echo "  📡 Route exposure: Enabled (networking.kserve.io/visibility=exposed)"
            else
                echo "  🔒 Route exposure: Disabled (cluster-local only)"
            fi
            if [[ "$auth_enabled" == "true" ]]; then
                echo "  🔐 Authentication: Enabled (security.opendatahub.io/enable-auth=true)"

                # Copy authentication resources now that InferenceService exists
                copy_authentication_resources "$isvc_name" "$original_runtime"
            else
                echo "  🔓 Authentication: Disabled"
            fi
            echo "  💾 Applied resource constraints: 1-2 CPUs, 4-8Gi Memory (Hardware Profile: Small)"
        else
            ERRORS+=("Failed to create InferenceService '$isvc_name' in namespace '$TARGET_NS': $LAST_APPLY_OUTPUT")
        fi

        echo ""
        # Increment index for next iteration
        index=$((index+1))
    done

    # Check if there were any errors during InferenceService creation
    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        echo ""
        echo -e "${ERROR_SYMBOL} Errors occurred during InferenceService migration:"
        for error in "${ERRORS[@]}"; do
            echo "  • $error"
        done
        echo ""
        echo "💡 Common issues and solutions:"
        echo "  - Permission denied: Ensure you have admin rights on the target namespace"
        echo "  - Resource already exists: Delete existing resources in target namespace"
        echo "  - Invalid YAML: Check InferenceService transformation and yq syntax"
        echo "  - Missing ServingRuntime: Ensure ServingRuntimes were created successfully"
        exit 1
    fi

    echo ""
    echo -e "${SUCCESS_SYMBOL} All InferenceServices migrated successfully to Raw Deployment"
    echo ""
}


echo "ModelMesh to KServe Raw Deployment Migration Helper"
echo "=================================================="
echo ""
echo "Source namespace (ModelMesh): $FROM_NS"
echo "Target namespace (KServe Raw): $TARGET_NS"
echo ""

# Migration logic here

# Initialize dry-run directory if needed
initialize_dry_run_directory

# Verify ModelMesh configuration
verify_modelmesh_namespace

# Create and configure target namespace
create_target_namespace

# List InferenceServices and get user selection
list_and_select_inference_services

# Cache available templates early to avoid repeated API calls
cache_available_templates
# Create serving runtimes for migration
create_serving_runtimes

# Process the models for migration, prepare the InferenceService manifests
process_inference_services

# Generate dry-run summary if in dry-run mode
generate_dry_run_summary() {
    if [[ "$DRY_RUN" != "true" ]]; then
        return
    fi

    echo ""
    echo "📋 DRY-RUN SUMMARY"
    echo "=================="
    echo ""
    echo "All YAML resources have been saved to: $DRY_RUN_DIR"
    echo ""

    # Count files in each category
    local original_count=$(find "$DRY_RUN_DIR/original-resources" -name "*.yaml" 2>/dev/null | wc -l)
    local new_count=$(find "$DRY_RUN_DIR/new-resources" -name "*.yaml" 2>/dev/null | wc -l)

    echo "📊 Resources saved:"
    echo "  • Original ModelMesh resources: $original_count files"
    echo "  • New KServe Raw resources: $new_count files"
    echo ""

    echo "📂 Directory structure:"
    echo "  $DRY_RUN_DIR/"
    echo "  ├── original-resources/     (ModelMesh resources for comparison)"
    echo "  │   ├── inferenceservice/"
    echo "  │   ├── servingruntime/"
    echo "  │   └── secret/"
    echo "  └── new-resources/          (KServe Raw resources to apply)"
    echo "      ├── inferenceservice/"
    echo "      ├── servingruntime/"
    echo "      ├── secret/"
    echo "      ├── serviceaccount/"
    echo "      ├── role/"
    echo "      └── rolebinding/"
    echo ""

    echo "💡 Next steps:"
    echo "  1. Review the generated YAML files in $DRY_RUN_DIR"
    echo "  2. Compare original vs new resources to understand the migration changes"
    echo "  3. When ready, apply the resources manually:"
    echo "     find $DRY_RUN_DIR/new-resources -name '*.yaml' -exec oc apply -f {} \\;"
    echo "  4. Or re-run this script without --dry-run to perform the actual migration"
    echo ""
}

generate_dry_run_summary

echo ""
if [[ "$DRY_RUN" == "true" ]]; then
    echo "🏁 Dry-run completed successfully!"
else
    echo "🎉 Migration completed successfully!"
    echo "======================================"
    echo ""
    echo "📊 Migration Summary:"
    echo "  • Source namespace: $FROM_NS (ModelMesh)"
    echo "  • Target namespace: $TARGET_NS (KServe Raw)"
    echo "  • InferenceServices migrated: ${#SELECTED_ISVCS[@]}"
    echo "  • Models: $(IFS=', '; echo "${SELECTED_ISVCS[*]}")"
    echo ""
    echo "💡 Next steps:"
    echo "  • Verify your migrated models are working: oc get inferenceservice -n $TARGET_NS"
    echo "  • Check ServingRuntimes: oc get servingruntime -n $TARGET_NS"
    echo "  • Test model endpoints for functionality"
    echo ""
    echo "🏁 Migration helper completed!"
fi