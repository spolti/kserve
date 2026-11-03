#!/usr/bin/env bash
# Security scan for KServe PR diffs.
# Scans the git diff between the PR branch and its base for suspicious patterns.
#
# Tuned to minimise false positives on Go / Python / Kubernetes codebases:
#   - Base64 check requires at least one +, / or = (pure alpha strings ignored)
#   - Shell-injection backtick check skips Go struct tags
#   - Crypto-address patterns use word boundaries
#
# Usage: security-scan.sh <repo_dir> <base_branch>
# Exit 0 = clean, Exit 1 = findings detected

set -euo pipefail

REPO_DIR="${1:?Usage: security-scan.sh <repo_dir> <base_branch>}"
BASE_BRANCH="${2:-origin/master}"
FINDINGS=()
DIFF_FILE=$(mktemp)

trap 'rm -f "$DIFF_FILE"' EXIT

cd "$REPO_DIR"
git diff "$BASE_BRANCH"...HEAD > "$DIFF_FILE"

if [ ! -s "$DIFF_FILE" ]; then
    echo "[SCAN] No diff found between HEAD and $BASE_BRANCH — nothing to scan."
    exit 0
fi

echo "[SCAN] Scanning PR diff against $BASE_BRANCH..."

add_finding() {
    local category="$1"
    local detail="$2"
    FINDINGS+=("[$category] $detail")
}

# 1. Base64-encoded blobs
# Requires either: a + char between long alphanumeric runs, or trailing = padding.
# The / char is NOT used as a base64 indicator because it appears in file paths,
# Go imports, and URLs, causing massive false positives.
BASE64_RE='[A-Za-z0-9]{8,}\+[A-Za-z0-9+/]{8,}={0,2}|[A-Za-z0-9+/]{20,}={1,2}'
if grep -Pn "^\+.*($BASE64_RE)" "$DIFF_FILE" \
    | grep -v '^\+\+\+' \
    | grep -Pv '^\d+:\+\+\+ ' \
    | head -20 | grep -q .; then
    matches=$(grep -Pn "^\+.*($BASE64_RE)" "$DIFF_FILE" \
        | grep -v '^\+\+\+' \
        | grep -Pv '^\d+:\+\+\+ ' \
        | head -20)
    add_finding "BASE64" "Potential base64-encoded blobs found in added lines:\n$matches"
fi

# 2. Hex-encoded sequences (40+ chars, require 0x prefix or standalone hex block)
if grep -Pn '^[+].*\b0x[0-9a-fA-F]{40,}\b' "$DIFF_FILE" | grep -v '^[+]{3}' | head -10 | grep -q .; then
    matches=$(grep -Pn '^[+].*\b0x[0-9a-fA-F]{40,}\b' "$DIFF_FILE" | grep -v '^[+]{3}' | head -10)
    add_finding "HEX_BLOB" "Long hex-encoded sequences found:\n$matches"
fi

# 3. AWS credentials patterns
if grep -Pn '^[+].*(AKIA[0-9A-Z]{16}|aws_secret_access_key|aws_access_key_id)\s*[:=]' "$DIFF_FILE" | grep -v '^[+]{3}' | head -10 | grep -q .; then
    matches=$(grep -Pn '^[+].*(AKIA[0-9A-Z]{16}|aws_secret_access_key|aws_access_key_id)\s*[:=]' "$DIFF_FILE" | grep -v '^[+]{3}' | head -10)
    add_finding "AWS_CREDS" "Potential AWS credentials found:\n$matches"
fi

# 4. Generic secrets / tokens / passwords in assignments
if grep -Pin '^[+].*(password|secret|token|api_key|apikey)\s*[:=]\s*["\x27][^"\x27]{8,}' "$DIFF_FILE" \
    | grep -v '^[+]{3}' \
    | grep -vi '(example|placeholder|changeme|TODO|FIXME|xxx|test)' \
    | head -10 | grep -q .; then
    matches=$(grep -Pin '^[+].*(password|secret|token|api_key|apikey)\s*[:=]\s*["\x27][^"\x27]{8,}' "$DIFF_FILE" \
        | grep -v '^[+]{3}' \
        | grep -vi '(example|placeholder|changeme|TODO|FIXME|xxx|test)' \
        | head -10)
    add_finding "SECRETS" "Potential hardcoded secrets/tokens:\n$matches"
fi

# 5. Private keys
if grep -Pn '^[+].*(BEGIN (RSA |DSA |EC |OPENSSH )?PRIVATE KEY)' "$DIFF_FILE" | head -5 | grep -q .; then
    matches=$(grep -Pn '^[+].*(BEGIN (RSA |DSA |EC |OPENSSH )?PRIVATE KEY)' "$DIFF_FILE" | head -5)
    add_finding "PRIVATE_KEY" "Private key material detected:\n$matches"
fi

# 6. Shell injection (eval, curl|sh, wget|sh — skip Go struct tags and test files)
if grep -Pn '^[+].*(eval\s*\(|eval\s+["\x27$]|\$\([^)]+\)\s*\|.*sh\b|\bcurl\b.*\|\s*(ba)?sh|\bwget\b.*\|\s*(ba)?sh)' "$DIFF_FILE" \
    | grep -v '^[+]{3}' \
    | grep -v '\.md:' \
    | grep -v '_test\.go:' \
    | head -10 | grep -q .; then
    matches=$(grep -Pn '^[+].*(eval\s*\(|eval\s+["\x27$]|\$\([^)]+\)\s*\|.*sh\b|\bcurl\b.*\|\s*(ba)?sh|\bwget\b.*\|\s*(ba)?sh)' "$DIFF_FILE" \
        | grep -v '^[+]{3}' \
        | grep -v '\.md:' \
        | grep -v '_test\.go:' \
        | head -10)
    add_finding "SHELL_INJECTION" "Suspicious shell patterns (eval/curl|sh):\n$matches"
fi

# 7. Binary files in the diff
if grep -Pn '^Binary files' "$DIFF_FILE" | head -10 | grep -q .; then
    matches=$(grep -Pn '^Binary files' "$DIFF_FILE" | head -10)
    add_finding "BINARY_FILES" "Binary files introduced:\n$matches"
fi

# 8. Cryptocurrency wallet addresses (word-boundary-delimited)
if grep -Pn '^[+].*\b(bc1[a-zA-HJ-NP-Z0-9]{25,39}|[13][a-km-zA-HJ-NP-Z1-9]{25,34})\b' "$DIFF_FILE" \
    | grep -v '^[+]{3}' \
    | grep -v '\.(go|py|java|ts|js):' \
    | head -5 | grep -q .; then
    matches=$(grep -Pn '^[+].*\b(bc1[a-zA-HJ-NP-Z0-9]{25,39}|[13][a-km-zA-HJ-NP-Z1-9]{25,34})\b' "$DIFF_FILE" \
        | grep -v '^[+]{3}' \
        | grep -v '\.(go|py|java|ts|js):' \
        | head -5)
    add_finding "CRYPTO_ADDR" "Possible cryptocurrency addresses:\n$matches"
fi

# 9. Ethereum addresses (standalone 0x + 40 hex)
if grep -Pn '^[+].*\b0x[0-9a-fA-F]{40}\b' "$DIFF_FILE" \
    | grep -v '^[+]{3}' \
    | grep -v '\.(go|py|java|ts|js):' \
    | head -5 | grep -q .; then
    matches=$(grep -Pn '^[+].*\b0x[0-9a-fA-F]{40}\b' "$DIFF_FILE" \
        | grep -v '^[+]{3}' \
        | grep -v '\.(go|py|java|ts|js):' \
        | head -5)
    add_finding "CRYPTO_ADDR" "Possible Ethereum addresses:\n$matches"
fi

# 10. Prompt injection — role/identity override attempts
if grep -Pin '^[+].*(you are now|act as|pretend to be|roleplay as|from now on you|your new (role|instructions?|personality)|you must (obey|comply|follow)|system:\s*you are)' "$DIFF_FILE" | grep -v '^[+]{3}' | head -10 | grep -q .; then
    matches=$(grep -Pin '^[+].*(you are now|act as|pretend to be|roleplay as|from now on you|your new (role|instructions?|personality)|you must (obey|comply|follow)|system:\s*you are)' "$DIFF_FILE" | grep -v '^[+]{3}' | head -10)
    add_finding "PROMPT_INJECTION" "LLM prompt injection — role/identity override attempt:\n$matches"
fi

# 11. Prompt injection — instruction override / ignore patterns
if grep -Pin '^[+].*(ignore (all )?(previous|prior|above|earlier|preceding) (instructions?|prompts?|rules?|context)|disregard (all )?(previous|prior|above)|forget (all )?(previous|prior|your) (instructions?|rules?|context)|do not follow (previous|prior|the above)|override (previous|prior|system) (instructions?|prompt))' "$DIFF_FILE" | grep -v '^[+]{3}' | head -10 | grep -q .; then
    matches=$(grep -Pin '^[+].*(ignore (all )?(previous|prior|above|earlier|preceding) (instructions?|prompts?|rules?|context)|disregard (all )?(previous|prior|above)|forget (all )?(previous|prior|your) (instructions?|rules?|context)|do not follow (previous|prior|the above)|override (previous|prior|system) (instructions?|prompt))' "$DIFF_FILE" | grep -v '^[+]{3}' | head -10)
    add_finding "PROMPT_INJECTION" "LLM prompt injection — instruction override/ignore pattern:\n$matches"
fi

# 12. Prompt injection — hidden/invisible text and zero-width characters
if grep -Pn '^[+].*(\xe2\x80\x8b|\xe2\x80\x8c|\xe2\x80\x8d|\xe2\x81\xa0|\xef\xbb\xbf|\\u200[bcd]|\\u2060|\\ufeff)' "$DIFF_FILE" | grep -v '^[+]{3}' | head -10 | grep -q .; then
    matches=$(grep -Pn '^[+].*(\xe2\x80\x8b|\xe2\x80\x8c|\xe2\x80\x8d|\xe2\x81\xa0|\xef\xbb\xbf|\\u200[bcd]|\\u2060|\\ufeff)' "$DIFF_FILE" | grep -v '^[+]{3}' | head -10)
    add_finding "PROMPT_INJECTION" "Zero-width / invisible Unicode characters (possible hidden prompt injection):\n$matches"
fi

# 13. Prompt injection — common jailbreak delimiters and markup
if grep -Pin '^[+].*(<<\s*SYS\s*>>|<\|im_start\|>|<\|im_end\|>|\[INST\]|\[\/INST\]|\[SYSTEM\]|<\|system\|>|<\|user\|>|<\|assistant\|>|### ?(instruction|system|human|assistant):)' "$DIFF_FILE" | grep -v '^[+]{3}' | head -10 | grep -q .; then
    matches=$(grep -Pin '^[+].*(<<\s*SYS\s*>>|<\|im_start\|>|<\|im_end\|>|\[INST\]|\[\/INST\]|\[SYSTEM\]|<\|system\|>|<\|user\|>|<\|assistant\|>|### ?(instruction|system|human|assistant):)' "$DIFF_FILE" | grep -v '^[+]{3}' | head -10)
    add_finding "PROMPT_INJECTION" "LLM chat/prompt delimiters detected (jailbreak markers):\n$matches"
fi

# 14. Prompt injection — data exfiltration via prompt
if grep -Pin '^[+].*(output (all|the|your) (instructions?|system prompt|rules?|config)|reveal (your|the) (system |hidden )?(prompt|instructions?|rules?)|print (your|the) (system |initial )?(prompt|instructions?)|show me (your|the) (system |hidden )?(prompt|instructions?)|what (are|is) your (system )?(prompt|instructions?|rules?))' "$DIFF_FILE" | grep -v '^[+]{3}' | head -10 | grep -q .; then
    matches=$(grep -Pin '^[+].*(output (all|the|your) (instructions?|system prompt|rules?|config)|reveal (your|the) (system |hidden )?(prompt|instructions?|rules?)|print (your|the) (system |initial )?(prompt|instructions?)|show me (your|the) (system |hidden )?(prompt|instructions?)|what (are|is) your (system )?(prompt|instructions?|rules?))' "$DIFF_FILE" | grep -v '^[+]{3}' | head -10)
    add_finding "PROMPT_INJECTION" "Prompt exfiltration attempt — tries to extract system/hidden instructions:\n$matches"
fi

echo ""
if [ ${#FINDINGS[@]} -eq 0 ]; then
    echo "========================================"
    echo "  SECURITY SCAN: PASSED"
    echo "========================================"
    echo "No suspicious patterns found in the PR diff."
    exit 0
else
    echo "========================================"
    echo "  SECURITY SCAN: FINDINGS DETECTED"
    echo "========================================"
    echo ""
    echo "Found ${#FINDINGS[@]} category(ies) of potential issues:"
    echo ""
    for finding in "${FINDINGS[@]}"; do
        echo -e "  $finding"
        echo ""
    done
    echo "Review these findings before proceeding."
    echo "To skip this check, pass: -e skip_security_scan=true"
    exit 1
fi
