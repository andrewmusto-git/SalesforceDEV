#!/usr/bin/env bash
# preflight.sh — Pre-deployment validation for the Salesforce → Veza OAA integration
#
# Usage:
#   bash preflight.sh           # interactive menu
#   bash preflight.sh --all     # run all checks non-interactively (CI/CD)
#
# The script validates every prerequisite before running salesforce.py.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_FILE="${SCRIPT_DIR}/salesforce.py"
REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements.txt"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"
VENV_DIR="${SCRIPT_DIR}/venv"
PYTHON="${VENV_DIR}/bin/python3"
LOG_FILE="${SCRIPT_DIR}/preflight_$(date +%Y%m%d_%H%M%S).log"

# ---------------------------------------------------------------------------
# Colours and counters
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

TESTS_PASSED=0; TESTS_FAILED=0; TESTS_WARNING=0

print_success() { echo -e "${GREEN}✓${NC} $1" | tee -a "${LOG_FILE}"; ((TESTS_PASSED++)); }
print_fail()    { echo -e "${RED}✗${NC} $1"   | tee -a "${LOG_FILE}"; ((TESTS_FAILED++));  }
print_warning() { echo -e "${YELLOW}⚠${NC} $1" | tee -a "${LOG_FILE}"; ((TESTS_WARNING++)); }
print_info()    { echo -e "${BLUE}ℹ${NC} $1"  | tee -a "${LOG_FILE}"; }
print_header()  { echo -e "\n${BOLD}── $1 ──${NC}" | tee -a "${LOG_FILE}"; }

# Fall back to system python if venv does not exist
if [[ ! -f "${PYTHON}" ]]; then
    PYTHON="$(command -v python3 2>/dev/null || echo python3)"
fi

# ---------------------------------------------------------------------------
# check_env_var helper
# ---------------------------------------------------------------------------
check_env_var() {
    local var_name="$1"
    local var_value="$2"
    local optional="${3:-required}"

    if [[ -z "${var_value}" ]]; then
        if [[ "${optional}" == "optional" ]]; then
            print_info "${var_name} not set (optional)"
        else
            print_fail "${var_name} is not set"
        fi
    elif [[ "${var_value}" =~ ^your_.* ]] || [[ "${var_value}" =~ ^https://your-.* ]]; then
        print_warning "${var_name} contains placeholder value"
    else
        if [[ "${var_name}" =~ PASSWORD|KEY|TOKEN|SECRET ]]; then
            print_success "${var_name} set (${var_value:0:8}...)"
        else
            print_success "${var_name} = ${var_value}"
        fi
    fi
}

# ---------------------------------------------------------------------------
# 1 — System Requirements
# ---------------------------------------------------------------------------
check_system_requirements() {
    print_header "1 — System Requirements"

    # OS detection
    OS_ID=""
    if [[ -f /etc/os-release ]]; then
        OS_ID=$(grep -E "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        print_info "OS: ${OS_ID}"
    elif [[ "$(uname)" == "Darwin" ]]; then
        print_info "OS: macOS"
    else
        print_info "OS: unknown"
    fi

    # Python version ≥ 3.9
    if command -v python3 &>/dev/null; then
        PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        PY_MAJOR=$(echo "${PY_VER}" | cut -d. -f1)
        PY_MINOR=$(echo "${PY_VER}" | cut -d. -f2)
        if [[ "${PY_MAJOR}" -gt 3 ]] || [[ "${PY_MAJOR}" -eq 3 && "${PY_MINOR}" -ge 9 ]]; then
            print_success "Python ${PY_VER} (≥ 3.9 required)"
        else
            print_fail "Python ${PY_VER} found — 3.9+ required"
        fi
    else
        print_fail "python3 not found in PATH"
    fi

    # pip3
    if python3 -m pip --version &>/dev/null; then
        print_success "pip3 available"
    else
        print_fail "pip3 not available — install python3-pip"
    fi

    # venv
    if [[ -d "${VENV_DIR}" ]]; then
        print_success "Virtual environment found: ${VENV_DIR}"
    else
        print_warning "Virtual environment not found at ${VENV_DIR} — run Option 11 to create it"
    fi

    # curl
    if command -v curl &>/dev/null; then
        print_success "curl available"
    else
        print_warning "curl not found — required for network connectivity checks"
    fi

    # jq (optional)
    if command -v jq &>/dev/null; then
        print_success "jq available"
    else
        print_warning "jq not found (optional — improves JSON display in auth tests)"
    fi

    # No extra system deps needed for REST API source
    print_info "Data source: Salesforce REST API — no additional system dependencies required"
}

# ---------------------------------------------------------------------------
# 2 — Python Dependencies
# ---------------------------------------------------------------------------
check_python_dependencies() {
    print_header "2 — Python Dependencies"

    if [[ ! -f "${REQUIREMENTS_FILE}" ]]; then
        print_fail "requirements.txt not found at ${REQUIREMENTS_FILE}"
        return
    fi

    print_info "Using Python: ${PYTHON}"

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Skip blank lines and comments
        [[ -z "${line}" || "${line}" =~ ^# ]] && continue

        # Extract package name (strip version specifier)
        pkg_name=$(echo "${line}" | sed 's/[>=<!\[].*//' | tr '[:upper:]' '[:lower:]' | tr '-' '_')

        version=$("${PYTHON}" -c "import importlib.metadata; print(importlib.metadata.version('${line%%[>=<!]*}'))" 2>/dev/null || echo "")
        if [[ -n "${version}" ]]; then
            print_success "${pkg_name} ${version}"
        else
            # Try direct import
            if "${PYTHON}" -c "import ${pkg_name}" 2>/dev/null; then
                print_success "${pkg_name} (importable)"
            else
                print_fail "${pkg_name} not installed — run: ${VENV_DIR}/bin/pip install -r ${REQUIREMENTS_FILE}"
            fi
        fi
    done < "${REQUIREMENTS_FILE}"
}

# ---------------------------------------------------------------------------
# 3 — Configuration File
# ---------------------------------------------------------------------------
check_configuration() {
    print_header "3 — Configuration File"

    if [[ ! -f "${ENV_FILE}" ]]; then
        print_fail ".env file not found at ${ENV_FILE}"
        print_info "Run Option 10 to generate a template .env file"
        return
    fi
    print_success ".env file found"

    # Check permissions
    perms=$(stat -c "%a" "${ENV_FILE}" 2>/dev/null || stat -f "%A" "${ENV_FILE}" 2>/dev/null || echo "")
    if [[ "${perms}" == "600" ]]; then
        print_success ".env permissions: 600"
    else
        print_warning ".env permissions: ${perms} — fix with: chmod 600 ${ENV_FILE}"
    fi

    # Load env vars (suppress errors from the file; only read variables)
    set +u
    # shellcheck disable=SC1090
    source "${ENV_FILE}" 2>/dev/null || true
    set -u

    print_info "Validating required environment variables..."

    check_env_var "SF_INSTANCE_URL"  "${SF_INSTANCE_URL:-}"
    check_env_var "SF_TOKEN_URL"     "${SF_TOKEN_URL:-}"
    check_env_var "SF_CLIENT_ID"     "${SF_CLIENT_ID:-}"
    check_env_var "SF_CLIENT_SECRET" "${SF_CLIENT_SECRET:-}"
    check_env_var "VEZA_URL"         "${VEZA_URL:-}"
    check_env_var "VEZA_API_KEY"     "${VEZA_API_KEY:-}"
    check_env_var "SF_API_VERSION"   "${SF_API_VERSION:-}" optional
}

# ---------------------------------------------------------------------------
# 4 — Network Connectivity
# ---------------------------------------------------------------------------
check_network_connectivity() {
    print_header "4 — Network Connectivity"

    set +u
    # shellcheck disable=SC1090
    [[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}" 2>/dev/null || true
    set -u

    _https_check() {
        local label="$1"
        local url="$2"
        if ! command -v curl &>/dev/null; then
            print_warning "curl not available — skipping ${label} check"
            return
        fi
        result=$(curl -s -o /dev/null -w "%{http_code}|%{time_total}" -m 10 "${url}" 2>/dev/null || echo "000|error")
        http_code=$(echo "${result}" | cut -d'|' -f1)
        latency=$(echo "${result}" | cut -d'|' -f2)
        if [[ "${http_code}" =~ ^[2-4][0-9][0-9]$ ]]; then
            print_success "${label} reachable (HTTP ${http_code}, ${latency}s)"
        else
            print_fail "${label} unreachable (HTTP ${http_code}) — check network/firewall"
        fi
    }

    # Salesforce instance HTTPS
    SF_INSTANCE="${SF_INSTANCE_URL:-}"
    if [[ -n "${SF_INSTANCE}" ]]; then
        _https_check "Salesforce instance (${SF_INSTANCE})" "${SF_INSTANCE}"
    else
        print_warning "SF_INSTANCE_URL not set — skipping Salesforce connectivity check"
    fi

    # Salesforce token URL
    SF_TOKEN="${SF_TOKEN_URL:-}"
    if [[ -n "${SF_TOKEN}" && "${SF_TOKEN}" != "${SF_INSTANCE}" ]]; then
        _https_check "Salesforce token endpoint (${SF_TOKEN})" "${SF_TOKEN}"
    fi

    # Veza HTTPS
    VEZA="${VEZA_URL:-}"
    if [[ -n "${VEZA}" ]]; then
        _https_check "Veza (${VEZA})" "${VEZA}"
    else
        print_warning "VEZA_URL not set — skipping Veza connectivity check"
    fi
}

# ---------------------------------------------------------------------------
# 5 — API Authentication
# ---------------------------------------------------------------------------
check_api_authentication() {
    print_header "5 — API Authentication"

    set +u
    # shellcheck disable=SC1090
    [[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}" 2>/dev/null || true
    set -u

    SF_INSTANCE="${SF_INSTANCE_URL:-}"
    SF_TOKEN="${SF_TOKEN_URL:-}"
    SF_CID="${SF_CLIENT_ID:-}"
    SF_CSECRET="${SF_CLIENT_SECRET:-}"
    VEZA="${VEZA_URL:-}"
    VEZA_KEY="${VEZA_API_KEY:-}"

    # -- Salesforce OAuth2 token test --
    if [[ -z "${SF_TOKEN}" || -z "${SF_CID}" || -z "${SF_CSECRET}" ]]; then
        print_warning "Salesforce credentials incomplete — skipping auth test"
    elif ! command -v curl &>/dev/null; then
        print_warning "curl not available — skipping Salesforce auth test"
    else
        print_info "[DEBUG] POST ${SF_TOKEN} client_id=${SF_CID:0:8}... grant_type=client_credentials"
        sf_response=$(curl -s -w "\n%{http_code}" -X POST "${SF_TOKEN}" \
            -d "grant_type=client_credentials" \
            -d "client_id=${SF_CID}" \
            -d "client_secret=${SF_CSECRET}" 2>/dev/null || echo -e "{}\n000")
        sf_body=$(echo "${sf_response}" | head -n -1)
        sf_code=$(echo "${sf_response}" | tail -n 1)

        if [[ "${sf_code}" == "200" ]]; then
            token_present=$(echo "${sf_body}" | "${PYTHON}" -c "import sys,json; d=json.load(sys.stdin); print('yes' if d.get('access_token') else 'no')" 2>/dev/null || echo "unknown")
            if [[ "${token_present}" == "yes" ]]; then
                print_success "Salesforce OAuth2 authentication successful (HTTP 200, token received)"
            else
                print_warning "HTTP 200 but no access_token in response — check Connected App settings"
            fi
        else
            print_fail "Salesforce OAuth2 authentication failed (HTTP ${sf_code})"
            print_info "Response: $(echo "${sf_body}" | head -c 200)"
        fi
    fi

    # -- Veza API key test --
    if [[ -z "${VEZA}" || -z "${VEZA_KEY}" ]]; then
        print_warning "Veza credentials incomplete — skipping Veza auth test"
    elif ! command -v curl &>/dev/null; then
        print_warning "curl not available — skipping Veza auth test"
    else
        print_info "[DEBUG] GET ${VEZA}/api/v1/providers Authorization: Bearer ${VEZA_KEY:0:8}..."
        veza_response=$(curl -s -o /dev/null -w "%{http_code}" -m 15 \
            -H "Authorization: Bearer ${VEZA_KEY}" \
            "${VEZA}/api/v1/providers" 2>/dev/null || echo "000")
        if [[ "${veza_response}" == "200" ]]; then
            print_success "Veza API key authentication successful (HTTP 200)"
        else
            print_fail "Veza API key authentication failed (HTTP ${veza_response}) — check VEZA_URL and VEZA_API_KEY"
        fi
    fi
}

# ---------------------------------------------------------------------------
# 6 — API Endpoint Accessibility
# ---------------------------------------------------------------------------
check_api_endpoints() {
    print_header "6 — API Endpoint Accessibility"

    set +u
    # shellcheck disable=SC1090
    [[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}" 2>/dev/null || true
    set -u

    VEZA="${VEZA_URL:-}"
    VEZA_KEY="${VEZA_API_KEY:-}"

    if [[ -n "${VEZA}" && -n "${VEZA_KEY}" ]] && command -v curl &>/dev/null; then
        query_body='{"query":"nodes{InstanceId first:1}"}'
        veza_query_response=$(curl -s -o /dev/null -w "%{http_code}" -m 15 -X POST \
            -H "Authorization: Bearer ${VEZA_KEY}" \
            -H "Content-Type: application/json" \
            -d "${query_body}" \
            "${VEZA}/api/v1/assessments/query_spec:nodes" 2>/dev/null || echo "000")
        if [[ "${veza_query_response}" =~ ^2 ]]; then
            print_success "Veza query endpoint accessible (HTTP ${veza_query_response})"
        else
            print_warning "Veza query endpoint returned HTTP ${veza_query_response} (may need read permission)"
        fi
    else
        print_info "Veza credentials not set or curl unavailable — skipping query endpoint check"
    fi

    # Salesforce REST API identity endpoint (requires a valid access token; use a quick check)
    SF_INSTANCE="${SF_INSTANCE_URL:-}"
    if [[ -n "${SF_INSTANCE}" ]] && command -v curl &>/dev/null; then
        rest_response=$(curl -s -o /dev/null -w "%{http_code}" -m 10 \
            "${SF_INSTANCE}/services/data/" 2>/dev/null || echo "000")
        if [[ "${rest_response}" =~ ^2 ]]; then
            print_success "Salesforce REST API discovery endpoint accessible (HTTP ${rest_response})"
        else
            print_info "Salesforce REST API discovery: HTTP ${rest_response} (expected without auth token)"
        fi
    fi
}

# ---------------------------------------------------------------------------
# 7 — Deployment Structure
# ---------------------------------------------------------------------------
check_deployment_structure() {
    print_header "7 — Deployment Structure"

    # Main script
    if [[ -f "${SCRIPT_FILE}" ]]; then
        print_success "salesforce.py found: ${SCRIPT_FILE}"
    else
        print_fail "salesforce.py not found at ${SCRIPT_FILE}"
    fi

    # requirements.txt
    if [[ -f "${REQUIREMENTS_FILE}" ]]; then
        print_success "requirements.txt found"
    else
        print_fail "requirements.txt not found at ${REQUIREMENTS_FILE}"
    fi

    # logs/ directory
    LOGS_DIR="${SCRIPT_DIR}/logs"
    if [[ -d "${LOGS_DIR}" ]]; then
        if [[ -w "${LOGS_DIR}" ]]; then
            print_success "logs/ directory writable"
        else
            print_warning "logs/ directory not writable — fix with: chmod 755 ${LOGS_DIR}"
        fi
    else
        print_info "logs/ directory not present — will be created automatically on first run"
    fi

    # Current user
    CURRENT_USER=$(id -un 2>/dev/null || echo "unknown")
    if [[ "${CURRENT_USER}" == "salesforce-veza" ]]; then
        print_success "Running as dedicated service account: ${CURRENT_USER}"
    else
        print_warning "Running as '${CURRENT_USER}' — recommended to use a dedicated service account (salesforce-veza)"
    fi

    # Recommended install path check
    RECOMMENDED_PATH="/opt/VEZA/salesforce-veza/scripts"
    if [[ "${SCRIPT_DIR}" == "${RECOMMENDED_PATH}" ]]; then
        print_success "Install path matches recommended: ${RECOMMENDED_PATH}"
    else
        print_info "Install path: ${SCRIPT_DIR} (recommended: ${RECOMMENDED_PATH})"
    fi

    # Test --help flag
    if "${PYTHON}" "${SCRIPT_FILE}" --help &>/dev/null; then
        print_success "python3 salesforce.py --help executes without errors"
    else
        print_fail "python3 salesforce.py --help failed — check Python environment and dependencies"
    fi
}

# ---------------------------------------------------------------------------
# Utility: Display current configuration
# ---------------------------------------------------------------------------
display_configuration() {
    print_header "Current Configuration"

    if [[ ! -f "${ENV_FILE}" ]]; then
        print_info ".env not found at ${ENV_FILE}"
        return
    fi

    set +u
    # shellcheck disable=SC1090
    source "${ENV_FILE}" 2>/dev/null || true
    set -u

    local show_masked
    show_masked() {
        local val="$1"
        if [[ -z "${val}" ]]; then echo "(not set)"
        elif [[ "${val}" =~ ^your_.* ]]; then echo "(placeholder)"
        else echo "${val:0:8}..."
        fi
    }

    echo -e "  SF_INSTANCE_URL  : ${SF_INSTANCE_URL:-  (not set)}"
    echo -e "  SF_TOKEN_URL     : ${SF_TOKEN_URL:-(not set)}"
    echo -e "  SF_CLIENT_ID     : $(show_masked "${SF_CLIENT_ID:-}")"
    echo -e "  SF_CLIENT_SECRET : $(show_masked "${SF_CLIENT_SECRET:-}")"
    echo -e "  SF_API_VERSION   : ${SF_API_VERSION:-60.0 (default)}"
    echo -e "  VEZA_URL         : ${VEZA_URL:-(not set)}"
    echo -e "  VEZA_API_KEY     : $(show_masked "${VEZA_API_KEY:-}")"
}

# ---------------------------------------------------------------------------
# Utility: Generate .env template
# ---------------------------------------------------------------------------
generate_env_template() {
    print_header "Generate .env Template"

    if [[ -f "${ENV_FILE}" ]]; then
        read -r -p ".env already exists. Overwrite? [y/N]: " confirm </dev/tty
        [[ "${confirm}" =~ ^[Yy]$ ]] || { print_info "Skipped."; return; }
    fi

    if [[ -f "${ENV_EXAMPLE}" ]]; then
        cp "${ENV_EXAMPLE}" "${ENV_FILE}"
    else
        cat > "${ENV_FILE}" <<'EOF'
# Salesforce → Veza OAA Integration — Configuration
SF_INSTANCE_URL=https://your-org.my.salesforce.com
SF_TOKEN_URL=https://your-org.my.salesforce.com/services/oauth2/token
SF_CLIENT_ID=your_connected_app_client_id_here
SF_CLIENT_SECRET=your_connected_app_client_secret_here
# SF_API_VERSION=60.0
VEZA_URL=https://your-company.veza.com
VEZA_API_KEY=your_veza_api_key_here
EOF
    fi

    chmod 600 "${ENV_FILE}"
    print_success ".env template written to ${ENV_FILE} (mode 600)"
    print_info "Edit ${ENV_FILE} and replace placeholder values with real credentials"
}

# ---------------------------------------------------------------------------
# Utility: Install Python dependencies
# ---------------------------------------------------------------------------
install_dependencies() {
    print_header "Install Python Dependencies"

    if [[ ! -d "${VENV_DIR}" ]]; then
        print_info "Creating virtual environment: ${VENV_DIR}"
        python3 -m venv "${VENV_DIR}" || { print_fail "Failed to create venv"; return; }
        print_success "Virtual environment created"
    fi

    "${VENV_DIR}/bin/pip" install --quiet --upgrade pip
    "${VENV_DIR}/bin/pip" install -r "${REQUIREMENTS_FILE}" \
        && print_success "Dependencies installed successfully" \
        || print_fail "pip install failed — check ${REQUIREMENTS_FILE}"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    print_header "Validation Summary"
    echo -e "${GREEN}Passed:${NC}   ${TESTS_PASSED}"
    echo -e "${RED}Failed:${NC}   ${TESTS_FAILED}"
    echo -e "${YELLOW}Warnings:${NC} ${TESTS_WARNING}"
    echo ""
    if [[ "${TESTS_FAILED}" -eq 0 ]]; then
        echo -e "${GREEN}All checks passed.${NC} Recommended dry-run command:"
        echo ""
        echo -e "  ${PYTHON} ${SCRIPT_FILE} --env-file ${ENV_FILE} --dry-run --save-json"
        echo ""
        return 0
    else
        echo -e "${RED}✗ Some checks failed. Please address the issues above before deployment.${NC}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Run all checks
# ---------------------------------------------------------------------------
run_all_checks() {
    TESTS_PASSED=0; TESTS_FAILED=0; TESTS_WARNING=0
    echo "Preflight log: ${LOG_FILE}" | tee -a "${LOG_FILE}"
    echo ""

    check_system_requirements
    check_python_dependencies
    check_configuration
    check_network_connectivity
    check_api_authentication
    check_api_endpoints
    check_deployment_structure
    print_summary
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
interactive_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}Salesforce → Veza OAA — Preflight Validation${NC}"
        echo "────────────────────────────────────────────"
        echo " 1) System Requirements       7) Deployment Structure"
        echo " 2) Python Dependencies       8) Run ALL Checks (recommended)"
        echo " 3) Configuration File        9) Display Current Configuration"
        echo " 4) Network Connectivity     10) Generate Template .env File"
        echo " 5) API Authentication       11) Install Python Dependencies"
        echo " 6) API Endpoint Access       0) Exit"
        echo "────────────────────────────────────────────"
        read -r -p "Select option [0-11]: " choice </dev/tty

        case "${choice}" in
            1)  check_system_requirements ;;
            2)  check_python_dependencies ;;
            3)  check_configuration ;;
            4)  check_network_connectivity ;;
            5)  check_api_authentication ;;
            6)  check_api_endpoints ;;
            7)  check_deployment_structure ;;
            8)  run_all_checks ;;
            9)  display_configuration ;;
            10) generate_env_template ;;
            11) install_dependencies ;;
            0)  echo "Exiting."; exit 0 ;;
            *)  warn "Invalid option: ${choice}" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
    # Ensure log file is created
    touch "${LOG_FILE}" 2>/dev/null || LOG_FILE="/tmp/salesforce_preflight_$(date +%Y%m%d_%H%M%S).log"

    if [[ "${1:-}" == "--all" ]]; then
        run_all_checks
        exit $?
    else
        interactive_menu
    fi
}

main "$@"
