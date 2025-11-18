#!/bin/bash

################################################################################
# IDM External Proxy Manager
#
# Author: Mark Nienaber
#
# Description:
#   Script to manage IDM external proxy configurations for AIC (Advanced
#   Identity Cloud) data migration. Automates the setup of external IDM
#   connections between two AIC instances for data migration purposes.
#
# License:
#   This script is provided FOR TESTING AND INFORMATIONAL USE ONLY.
#
#   This software is provided "AS IS", WITHOUT WARRANTY OF ANY KIND, express or
#   implied, including but not limited to the warranties of merchantability,
#   fitness for a particular purpose and noninfringement. In no event shall the
#   author or copyright holders be liable for any claim, damages or other
#   liability, whether in an action of contract, tort or otherwise, arising
#   from, out of or in connection with the software or the use or other
#   dealings in the software.
#
#   USE AT YOUR OWN RISK. This script makes changes to your AIC instances.
#   Always test in a non-production environment first.
#
# Dependencies:
#   - OpenSSL: For cryptographic operations and random value generation
#   - jq: Command-line JSON processor
#   - jose: JavaScript Object Signing and Encryption tools
#
# Credits:
#   Based on service_accounts.sh by Darinder S Shokar - ForgeRock Professional Services
#
################################################################################

set -e  # Exit immediately if a command exits with a non-zero status

################################################################################
# CONFIGURATION AND GLOBAL VARIABLES
################################################################################

# Load environment variables from .env file
# Required variables: AIC1_TENANT, AIC1_SERVICE_ACCOUNT_ID, AIC1_JWK_PATH,
#                     AIC2_TENANT, AIC2_SERVICE_ACCOUNT_ID, AIC2_JWK_PATH,
#                     EXTERNAL_IDM_CLIENT_ID, EXTERNAL_IDM_CLIENT_SECRET,
#                     EXTERNAL_IDM_REALM, EXTERNAL_IDM_CONFIG_NAME
if [ -f .env ]; then
    source .env
else
    echo "Error: .env file not found. Copy .env.template to .env and configure."
    exit 1
fi

# ANSI color codes for terminal output formatting
RED='\033[0;31m'      # Error messages
GREEN='\033[0;32m'    # Success messages
YELLOW='\033[1;33m'   # Warning messages
BLUE='\033[0;34m'     # Info messages
NC='\033[0m'          # No Color - reset to default

# Global variables to store access tokens for API calls
# These are populated by get_access_token() and get_oauth_client_token()
ACCESS_TOKEN_AIC1=""              # Service account token for AIC1 (source instance)
ACCESS_TOKEN_AIC2=""              # Service account token for AIC2 (target instance)
OAUTH_CLIENT_ACCESS_TOKEN=""     # OAuth client credentials token

# Execution mode: Controls whether commands are displayed or executed
# "show" = Display curl commands without executing (safe preview mode)
# "run"  = Execute curl commands (makes actual changes to AIC instances)
EXEC_MODE="run"

################################################################################
# UTILITY FUNCTIONS
################################################################################

# Print success message in green with checkmark
# Usage: print_success "Operation completed successfully"
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Print error message in red with X mark
# Usage: print_error "Operation failed"
print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Print informational message in blue with info symbol
# Usage: print_info "Processing request..."
print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Print warning message in yellow with warning symbol
# Usage: print_warning "This action cannot be undone"
print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Execute or display curl commands based on EXEC_MODE
# In "show" mode: Displays formatted curl command to stderr (for user review)
# In "run" mode: Executes the actual curl command
# Returns mock JSON in "show" mode to allow script to continue
# Usage: execute_curl [curl arguments...]
execute_curl() {
    if [ "$EXEC_MODE" == "show" ]; then
        # Display to stderr so it doesn't interfere with command substitution
        echo "" >&2
        echo "================================================================================" >&2
        echo -e "${BLUE}CURL COMMAND (copy/paste ready):${NC}" >&2
        echo "================================================================================" >&2

        # Build array of arguments and check for -w flag
        local args=("$@")
        local output="curl"
        local i=0
        local has_write_out=false

        while [ $i -lt ${#args[@]} ]; do
            local arg="${args[$i]}"

            # Check if this is the -w flag with http_code
            if [[ "$arg" == "-w" ]] && [ $((i + 1)) -lt ${#args[@]} ]; then
                local next_arg="${args[$((i + 1))]}"
                if [[ "$next_arg" == *"http_code"* ]]; then
                    has_write_out=true
                fi
            fi

            # Check if this is a flag that takes a value
            if [[ "$arg" =~ ^-- ]] && [ $((i + 1)) -lt ${#args[@]} ]; then
                local next_arg="${args[$((i + 1))]}"
                # If next arg doesn't start with -, it's the value for this flag
                if [[ ! "$next_arg" =~ ^- ]]; then
                    # Special handling for --data flag with JSON
                    if [[ "$arg" == "--data" ]] && [[ "$next_arg" =~ ^\{ ]]; then
                        # Pretty-print JSON data using jq if it's valid JSON
                        local formatted_json=$(echo "$next_arg" | jq -c '.' 2>/dev/null)
                        if [ $? -eq 0 ]; then
                            # Successfully validated JSON - display as single-quoted string
                            # Escape single quotes in the JSON for proper shell quoting
                            local escaped_json=$(echo "$formatted_json" | sed "s/'/'\\\\''/g")
                            output="$output \\\\\n  $arg '$escaped_json'"
                        else
                            # Not valid JSON or jq failed, display as-is with proper quoting
                            if [[ "$next_arg" =~ [[:space:]] ]] || [[ "$next_arg" == *$'\n'* ]]; then
                                output="$output \\\\\n  $arg \"$next_arg\""
                            else
                                output="$output \\\\\n  $arg $next_arg"
                            fi
                        fi
                    # Quote the value if it contains spaces or newlines
                    elif [[ "$next_arg" =~ [[:space:]] ]] || [[ "$next_arg" == *$'\n'* ]]; then
                        output="$output \\\\\n  $arg \"$next_arg\""
                    else
                        output="$output \\\\\n  $arg $next_arg"
                    fi
                    i=$((i + 2))
                    continue
                fi
            fi

            # Standalone argument (single flags like -s, or URLs)
            if [[ "$arg" =~ [[:space:]] ]] || [[ "$arg" == *$'\n'* ]]; then
                output="$output \\\\\n  \"$arg\""
            else
                output="$output \\\\\n  $arg"
            fi
            i=$((i + 1))
        done

        # Display with actual line breaks
        echo -e "$output" >&2
        echo "================================================================================" >&2
        echo "" >&2

        # Return context-appropriate mock response based on the API endpoint
        # This allows the script to continue in show mode
        local mock_response='{"_id":"mock","enabled":true}'

        # Detect endpoint type from URL and return appropriate mock
        local url="${args[-1]}"  # Last argument is usually the URL

        if [[ "$url" == *"/oauth2/access_token"* ]] || [[ "$url" == *"/am/oauth2/"* ]]; then
            # OAuth token endpoint - return token response
            mock_response='{"access_token":"MOCK_TOKEN_SHOW_MODE","token_type":"Bearer","expires_in":3600,"scope":"fr:idm:*"}'
        elif [[ "$url" == *"/config/authentication"* ]]; then
            # Authentication config endpoint - return realistic auth config structure
            mock_response='{"serverAuthContext":{"authModules":[]},"clientAuthContext":{"authModules":[]},"staticUserMapping":[]}'
        elif [[ "$url" == *"/config/sync"* ]]; then
            # Sync config endpoint - return sync structure
            mock_response='{"mappings":[]}'
        elif [[ "$url" == *"/managed/"*"_user"* ]] || [[ "$url" == *"/external/idm/"* ]]; then
            # User query endpoint - return empty result set
            mock_response='{"result":[],"resultCount":0,"pagedResultsCookie":null,"totalPagedResultsPolicy":"NONE","totalPagedResults":-1,"remainingPagedResults":-1}'
        elif [[ "$url" == *"/realm-config/agents/OAuth2Client/"* ]]; then
            # OAuth client config - return client structure
            mock_response='{"_id":"'"${EXTERNAL_IDM_CLIENT_ID:-mock-client}"'","coreOAuth2ClientConfig":{"clientType":"Confidential","scopes":["fr:idm:*"]}}'
        elif [[ "$url" == *"/config/external.idm-"* ]]; then
            # External IDM config - return proxy structure
            mock_response='{"enabled":true,"authType":"bearer","instanceUrl":"https://mock.forgeblocks.com/openidm/"}'
        fi

        # Return mock response with HTTP code if -w flag was used
        if [ "$has_write_out" = true ]; then
            echo "$mock_response"
            echo "200"
        else
            echo "$mock_response"
        fi
    else
        # Execute the curl command in run mode
        curl "$@"
    fi
}

################################################################################
# DEPENDENCY CHECKING FUNCTIONS
################################################################################

# Check if OpenSSL is installed
# OpenSSL is required for generating random values and cryptographic operations
check_openssl() {
    hash openssl &> /dev/null
    if [ $? -eq 1 ]; then
        print_error "OpenSSL is not installed. Please install and re-run"
        exit 1
    fi
}

# Check if jq is installed
# jq is required for parsing and manipulating JSON responses from API calls
# Install: brew install jq (macOS) or apt-get install jq (Linux)
check_jq() {
    hash jq &> /dev/null
    if [ $? -eq 1 ]; then
        print_error "jq Command-line JSON processor is not installed. Please install and re-run"
        exit 1
    fi
}

# Check if jose is installed
# jose is required for JWT signing operations (service account authentication)
# Install: brew install jose (macOS) or apt-get install jose (Linux)
check_jose() {
    hash jose &> /dev/null
    if [ $? -eq 1 ]; then
        print_error "jose is not installed. Please install from: https://command-not-found.com/jose"
        exit 1
    fi
}

# Run all dependency checks at startup
# Exits script if any required tool is missing
check_dependencies() {
    check_openssl
    check_jq
    check_jose
}

################################################################################
# AUTHENTICATION FUNCTIONS
################################################################################

# Get service account access token using JWT Bearer authentication flow
# Implements OAuth 2.0 JWT Bearer Grant (RFC 7523) for service account authentication
#
# Parameters:
#   $1 - tenant: AIC tenant name (e.g., "openam-example")
#   $2 - service_account_id: UUID of the service account
#   $3 - jwk_path: Path to the private key JWK file
#   $4 - instance_name: Name for temp files (e.g., "aic1" or "aic2")
#   $5 - scope: OAuth scope to request (default: "fr:idm:*")
#
# Returns: Access token (via echo), or empty string on failure
#
# How it works:
#   1. Creates a JWT with service account claims (iss, sub, aud, exp, jti)
#   2. Signs the JWT with the service account's private key (RS256)
#   3. Exchanges signed JWT for access token at OAuth2 endpoint
#   4. Cleans up temporary files
get_access_token() {
    local tenant=$1
    local service_account_id=$2
    local jwk_path=$3
    local instance_name=$4
    local scope=${5:-"fr:idm:*"}  # Default to fr:idm:* scope if not specified

    print_info "Getting access token for service account: $service_account_id"
    print_info "Tenant: https://${tenant}.forgeblocks.com"
    print_info "Scope: ${scope}"

    # Verify the private key file exists before proceeding
    if [ ! -f "${jwk_path}" ]; then
        print_error "JWK file not found: ${jwk_path}"
        return 1
    fi

    # OAuth2 token endpoint for the AIC instance
    local aud="https://${tenant}.forgeblocks.com:443/am/oauth2/access_token"

    # JWT expiration time (current time + 180 seconds)
    local exp=$(($(date -u +%s) + 180))

    # Unique JWT identifier to prevent replay attacks
    local jti=$(openssl rand -base64 16)

    # Temporary files for JWT creation (will be cleaned up after use)
    local temp_jwt="./temp_payload_${instance_name}.json"
    local temp_signed_jwt="./temp_jwt_${instance_name}.txt"

    # Create JWT payload with required claims
    # iss (issuer): Service account ID
    # sub (subject): Service account ID
    # aud (audience): OAuth2 token endpoint
    # exp (expiration): Unix timestamp when JWT expires
    # jti (JWT ID): Unique identifier for this JWT
    echo -n "{
    \"iss\":\"${service_account_id}\",
    \"sub\":\"${service_account_id}\",
    \"aud\":\"${aud}\",
    \"exp\":${exp},
    \"jti\":\"${jti}\"
    }" > ${temp_jwt}

    # Sign the JWT using the service account's private key with RS256 algorithm
    print_info "Signing JWT with private key from ${jwk_path}"
    jose jws sig -I ${temp_jwt} -k ${jwk_path} -s '{"alg":"RS256"}' -c -o ${temp_signed_jwt}

    # Exchange the signed JWT for an access token
    print_info "Generating access token from signed JWT"
    local access_token_output=$(execute_curl -s \
        --request POST ${aud} \
        --data "client_id=service-account" \
        --data "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        --data "assertion=$(< ${temp_signed_jwt})" \
        --data "scope=${scope}")

    # Check if token request was successful
    if echo "${access_token_output}" | jq -e '.access_token' > /dev/null 2>&1; then
        local access_token=$(echo ${access_token_output} | jq -r .access_token)

        # Store token in global variable
        if [ "$instance_name" == "AIC1" ]; then
            ACCESS_TOKEN_AIC1="${access_token}"
        elif [ "$instance_name" == "AIC2" ]; then
            ACCESS_TOKEN_AIC2="${access_token}"
        fi

        if [ "$EXEC_MODE" == "show" ]; then
            print_info "SHOW MODE: Command displayed above (not executed)"
        else
            print_success "Access token retrieved successfully"
            print_info "Token (first 50 chars): ${access_token:0:50}..."
            echo "${access_token_output}" | jq .
        fi
    else
        print_error "Failed to get access token"
        echo "${access_token_output}" | jq .
        rm -f ${temp_jwt} ${temp_signed_jwt}
        return 1
    fi

    # Clean up temporary files
    rm -f ${temp_jwt} ${temp_signed_jwt}
}

# Get OAuth client access token using client credentials flow
# Implements OAuth 2.0 Client Credentials Grant (RFC 6749 Section 4.4)
#
# Parameters:
#   $1 - tenant: AIC tenant name
#   $2 - client_id: OAuth client ID (e.g., "idmprovisioning")
#   $3 - client_secret: OAuth client secret
#   $4 - realm: OAuth realm (e.g., "alpha" or "bravo")
#
# Returns: Sets OAUTH_CLIENT_ACCESS_TOKEN global variable
#
# This flow is used to authenticate the external IDM proxy to the target instance
get_oauth_client_token() {
    local tenant=$1
    local client_id=$2
    local client_secret=$3
    local realm=$4

    print_info "Getting OAuth client access token using client credentials flow"
    print_info "Client ID: ${client_id}"
    print_info "Realm: ${realm}"
    print_info "Tenant: https://${tenant}.forgeblocks.com"

    # OAuth2 token endpoint for the specified realm
    local token_endpoint="https://${tenant}.forgeblocks.com/am/oauth2/realms/${realm}/access_token"

    print_info "Token endpoint: ${token_endpoint}"

    # Request access token using client credentials flow
    # This is a simpler flow than JWT Bearer - just sends client ID and secret
    local access_token_output=$(execute_curl -s \
        --request POST "${token_endpoint}" \
        --data "grant_type=client_credentials" \
        --data "client_id=${client_id}" \
        --data "client_secret=${client_secret}" \
        --data "scope=fr:idm:*")

    # Check if token request was successful
    if echo "${access_token_output}" | jq -e '.access_token' > /dev/null 2>&1; then
        local access_token=$(echo ${access_token_output} | jq -r .access_token)

        # Store token in global variable
        OAUTH_CLIENT_ACCESS_TOKEN="${access_token}"

        if [ "$EXEC_MODE" == "show" ]; then
            print_info "SHOW MODE: Command displayed above (not executed)"
        else
            print_success "OAuth client access token retrieved successfully"
            print_info "Token (first 50 chars): ${access_token:0:50}..."
            echo "${access_token_output}" | jq .
        fi
    else
        print_error "Failed to get OAuth client access token"
        echo "${access_token_output}" | jq .
        return 1
    fi
}

# Function to test access token with a sample IDM call
test_access_token() {
    local tenant=$1
    local access_token=$2
    local instance_name=$3

    if [ -z "${access_token}" ]; then
        print_error "No access token available for ${instance_name}. Please get token first (Option 1)"
        return 1
    fi

    print_info "Testing access token for ${instance_name} (${tenant})"

    # Make a sample IDM call to get managed users (limited to 50)
    local idm_endpoint="https://${tenant}.forgeblocks.com/openidm/managed/alpha_user?_fields=userName&_prettyPrint=true&_queryFilter=true&_pageSize=50"

    print_info "Calling IDM endpoint: ${idm_endpoint}"

    local response=$(execute_curl -s \
        --request GET \
        --header "Authorization: Bearer ${access_token}" \
        "${idm_endpoint}")

    # Check if call was successful
    if echo "${response}" | jq -e '.result' > /dev/null 2>&1; then
        print_success "IDM API call successful"
        echo "${response}" | jq .
    else
        print_error "IDM API call failed"
        echo "${response}" | jq .
        return 1
    fi
}

# Function to test external IDM proxy
test_external_idm_proxy() {
    print_info "Getting service account token for AIC1..."

    # Get access token
    get_access_token "$AIC1_TENANT" "$AIC1_SERVICE_ACCOUNT_ID" "$AIC1_JWK_PATH" "AIC1"

    if [ -z "${ACCESS_TOKEN_AIC1}" ]; then
        print_error "Failed to obtain access token for AIC1"
        return 1
    fi

    echo ""
    print_info "Testing external IDM proxy for AIC1 (${AIC1_TENANT})"
    print_info "Calling through external config: ${EXTERNAL_IDM_CONFIG_NAME}"
    print_info "Target realm: ${EXTERNAL_IDM_REALM}"

    # Call the external IDM endpoint through the proxy
    local external_endpoint="https://${AIC1_TENANT}.forgeblocks.com/openidm/external/idm/${EXTERNAL_IDM_CONFIG_NAME}/managed/${EXTERNAL_IDM_REALM}_user?_fields=userName&_queryFilter=true&_pageSize=50"

    print_info "External endpoint: ${external_endpoint}"

    local response=$(execute_curl -s \
        --request GET \
        --header "Authorization: Bearer ${ACCESS_TOKEN_AIC1}" \
        --header "Accept-API-Version: resource=1.0" \
        "${external_endpoint}")

    # Check if call was successful
    if echo "${response}" | jq -e '.result' > /dev/null 2>&1; then
        local result_count=$(echo "${response}" | jq '.result | length')
        print_success "External IDM proxy call successful - Retrieved ${result_count} user(s)"
        echo "${response}" | jq .
    else
        print_error "External IDM proxy call failed"
        echo "${response}" | jq .
        return 1
    fi
}

# Function to test external IDM proxy using OAuth client credentials
test_external_idm_proxy_with_client() {
    print_info "Getting OAuth client credentials token from AIC1..."

    # Get OAuth client token from AIC1
    local token_endpoint="https://${AIC1_TENANT}.forgeblocks.com/am/oauth2/realms/${EXTERNAL_IDM_REALM}/access_token"

    local token_response=$(execute_curl -s \
        --request POST "${token_endpoint}" \
        --data "grant_type=client_credentials" \
        --data "client_id=${EXTERNAL_IDM_CLIENT_ID}" \
        --data "client_secret=${EXTERNAL_IDM_CLIENT_SECRET}" \
        --data "scope=fr:idm:*")

    local client_token=$(echo "${token_response}" | jq -r '.access_token')

    if [ "${client_token}" == "null" ] || [ -z "${client_token}" ]; then
        print_error "Failed to get OAuth client token"
        echo "${token_response}" | jq .
        return 1
    fi

    print_success "Successfully obtained OAuth client token"

    echo ""
    print_info "Testing external IDM proxy for AIC1 (${AIC1_TENANT})"
    print_info "Using OAuth client: ${EXTERNAL_IDM_CLIENT_ID} in realm: ${EXTERNAL_IDM_REALM}"
    print_info "Calling through external config: ${EXTERNAL_IDM_CONFIG_NAME}"
    print_info "Target realm: ${EXTERNAL_IDM_REALM}"

    # Call the external IDM endpoint through the proxy
    local external_endpoint="https://${AIC1_TENANT}.forgeblocks.com/openidm/external/idm/${EXTERNAL_IDM_CONFIG_NAME}/managed/${EXTERNAL_IDM_REALM}_user?_fields=userName&_queryFilter=true&_pageSize=50"

    print_info "External endpoint: ${external_endpoint}"

    local response=$(execute_curl -s \
        --request GET \
        --header "Authorization: Bearer ${client_token}" \
        --header "Accept-API-Version: resource=1.0" \
        "${external_endpoint}")

    # Check if call was successful
    if echo "${response}" | jq -e '.result' > /dev/null 2>&1; then
        local result_count=$(echo "${response}" | jq '.result | length')
        print_success "External IDM proxy call successful - Retrieved ${result_count} user(s)"
        echo "${response}" | jq .
    else
        print_error "External IDM proxy call failed"
        echo "${response}" | jq .
        return 1
    fi
}

# Function to create sync mapping on AIC1
create_sync_mapping() {
    print_info "Getting service account token for AIC1..."

    # Get access token
    get_access_token "$AIC1_TENANT" "$AIC1_SERVICE_ACCOUNT_ID" "$AIC1_JWK_PATH" "AIC1"

    if [ -z "${ACCESS_TOKEN_AIC1}" ]; then
        print_error "Failed to obtain access token for AIC1"
        return 1
    fi

    echo ""
    print_info "Creating sync mapping on AIC1 (${AIC1_TENANT})"
    print_info "Source: managed/alpha_user (local AIC1)"
    print_info "Target: external/idm/${EXTERNAL_IDM_CONFIG_NAME}/managed/${EXTERNAL_IDM_REALM}_user (AIC2 via proxy)"

    if [ "$EXEC_MODE" == "show" ]; then
        echo "" >&2
        print_warning "IMPORTANT: This creates a sync mapping configuration:" >&2
        print_warning "  The PUT request below contains the complete sync mapping definition" >&2
        print_warning "  If you have existing mappings, you'll need to GET current config first" >&2
        print_warning "  and ADD this mapping to the existing mappings array" >&2
        echo "" >&2
    fi

    local sync_endpoint="https://${AIC1_TENANT}.forgeblocks.com/openidm/config/sync"
    local mapping_name="aic1_to_aic2_user_sync"
    local target_path="external/idm/${EXTERNAL_IDM_CONFIG_NAME}/managed/${EXTERNAL_IDM_REALM}_user"

    print_info "Sync endpoint: ${sync_endpoint}"
    print_info "Mapping name: ${mapping_name}"

    local payload=$(cat <<'EOF'
{
  "mappings": [
    {
      "target": "TARGET_PATH",
      "source": "managed/alpha_user",
      "name": "MAPPING_NAME",
      "consentRequired": false,
      "icon": null,
      "displayName": "MAPPING_NAME",
      "properties": [
        {
          "target": "givenName",
          "source": "givenName"
        },
        {
          "target": "mail",
          "source": "mail"
        },
        {
          "target": "sn",
          "source": "sn"
        },
        {
          "target": "userName",
          "source": "userName"
        },
        {
          "target": "password",
          "source": "password"
        }
      ],
      "policies": [
        {
          "action": "ASYNC",
          "situation": "ABSENT"
        },
        {
          "action": "ASYNC",
          "situation": "ALL_GONE"
        },
        {
          "action": "ASYNC",
          "situation": "AMBIGUOUS"
        },
        {
          "action": "ASYNC",
          "situation": "CONFIRMED"
        },
        {
          "action": "ASYNC",
          "situation": "FOUND"
        },
        {
          "action": "ASYNC",
          "situation": "FOUND_ALREADY_LINKED"
        },
        {
          "action": "ASYNC",
          "situation": "LINK_ONLY"
        },
        {
          "action": "ASYNC",
          "situation": "MISSING"
        },
        {
          "action": "ASYNC",
          "situation": "SOURCE_IGNORED"
        },
        {
          "action": "ASYNC",
          "situation": "SOURCE_MISSING"
        },
        {
          "action": "ASYNC",
          "situation": "TARGET_IGNORED"
        },
        {
          "action": "ASYNC",
          "situation": "UNASSIGNED"
        },
        {
          "action": "ASYNC",
          "situation": "UNQUALIFIED"
        }
      ],
      "linkQualifiers": [
        "default"
      ],
      "correlationQuery": [
        {
          "linkQualifier": "default",
          "expressionTree": {
            "any": [
              "userName"
            ]
          },
          "mapping": "MAPPING_NAME",
          "type": "text/javascript",
          "file": "ui/correlateTreeToQueryFilter.js"
        }
      ]
    }
  ]
}
EOF
)

    # Replace placeholders with actual values
    payload=$(echo "${payload}" | sed "s|TARGET_PATH|${target_path}|g" | sed "s|MAPPING_NAME|${mapping_name}|g")

    print_info "Sending PUT request to create sync mapping..."

    local response=$(execute_curl -s -w "\n%{http_code}" \
        --request PUT \
        --header "Authorization: Bearer ${ACCESS_TOKEN_AIC1}" \
        --header "Content-Type: application/json" \
        --header "Accept-API-Version: resource=1.0" \
        --data "${payload}" \
        "${sync_endpoint}")

    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')

    if [ "$EXEC_MODE" == "show" ]; then
        print_info "SHOW MODE: Command displayed above (not executed)"
    elif [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
        print_success "Sync mapping created successfully (HTTP ${http_code})"
        echo "${body}" | jq .
    else
        print_error "Failed to create sync mapping (HTTP ${http_code})"
        echo "${body}" | jq .
        return 1
    fi
}

################################################################################
# AIC CONFIGURATION FUNCTIONS
################################################################################

# Configure AIC2 (Target Instance)
# Sets up the target AIC instance to receive proxy connections from AIC1
#
# What this function does:
#   1. Obtains service account token for AIC2 (with fr:am:* and fr:idm:* scopes)
#   2. Creates OAuth client for external IDM authentication (if not exists)
#   3. Configures static user mapping to grant OAuth client admin permissions
#
# The OAuth client created here will be used by AIC1's external IDM proxy
# to authenticate to AIC2 when querying data.
#
# Prerequisites:
#   - AIC2 service account with appropriate permissions
#   - Service account private key in keys/ directory
#   - .env file configured with AIC2 details
configure_aic2() {
    echo ""
    echo "========================================="
    echo "   Configure AIC2 (Target)"
    echo "========================================="

    print_info "Getting service account token for AIC2 with fr:am:* and fr:idm:* scopes..."

    # Get access token with both scopes
    get_access_token "$AIC2_TENANT" "$AIC2_SERVICE_ACCOUNT_ID" "$AIC2_JWK_PATH" "AIC2" "fr:am:* fr:idm:*"

    if [ -z "${ACCESS_TOKEN_AIC2}" ]; then
        print_error "Failed to obtain access token for AIC2"
        return 1
    fi

    echo ""
    print_info "Step 1: Configuring OAuth Client on AIC2..."

    # Step 1.1: Check if OAuth client already exists
    print_info "STEP 1.1: Checking if OAuth client exists..."
    local client_check=$(execute_curl -s \
        --request GET \
        --header "Authorization: Bearer ${ACCESS_TOKEN_AIC2}" \
        "https://${AIC2_TENANT}.forgeblocks.com/am/json/realms/root/realms/${EXTERNAL_IDM_REALM}/realm-config/agents/OAuth2Client/${EXTERNAL_IDM_CLIENT_ID}")

    if [ "$EXEC_MODE" == "show" ]; then
        # In show mode, display both the check and create commands
        echo "" >&2
        print_info "STEP 1.2: Create OAuth client if not exists:" >&2
        echo "" >&2
    fi

    if echo "${client_check}" | jq -e '._id' > /dev/null 2>&1; then
        if [ "$EXEC_MODE" != "show" ]; then
            print_warning "OAuth client '${EXTERNAL_IDM_CLIENT_ID}' already exists on AIC2"
            echo "${client_check}" | jq -r '._id, .coreOAuth2ClientConfig.scopes'
        fi
    fi

    # Always prepare and show/execute the create command (in show mode we show it, in run mode we only execute if needed)
    local client_payload=$(cat <<EOF
{
  "_id": "${EXTERNAL_IDM_CLIENT_ID}",
  "coreOAuth2ClientConfig": {
    "clientType": "Confidential",
    "redirectionUris": [],
    "scopes": ["fr:idm:*"],
    "defaultScopes": ["fr:idm:*"],
    "clientName": {
      "en": "IDM Provisioning Client"
    },
    "userpassword": "${EXTERNAL_IDM_CLIENT_SECRET}"
  },
  "advancedOAuth2ClientConfig": {
    "tokenEndpointAuthMethod": "client_secret_post",
    "grantTypes": ["client_credentials"]
  }
}
EOF
)

    # In show mode, always display the create command; in run mode, only if client doesn't exist
    if [ "$EXEC_MODE" == "show" ] || ! echo "${client_check}" | jq -e '._id' > /dev/null 2>&1; then
        if [ "$EXEC_MODE" != "show" ]; then
            print_info "Creating OAuth client '${EXTERNAL_IDM_CLIENT_ID}' on AIC2..."
        fi

        local client_response=$(execute_curl -s -w "\n%{http_code}" \
            --request PUT \
            --header "Authorization: Bearer ${ACCESS_TOKEN_AIC2}" \
            --header "Content-Type: application/json" \
            --header "Accept-API-Version: resource=1.0" \
            --data "${client_payload}" \
            "https://${AIC2_TENANT}.forgeblocks.com/am/json/realms/root/realms/${EXTERNAL_IDM_REALM}/realm-config/agents/OAuth2Client/${EXTERNAL_IDM_CLIENT_ID}")

        if [ "$EXEC_MODE" != "show" ]; then
            local http_code=$(echo "$client_response" | tail -n1)
            local body=$(echo "$client_response" | sed '$d')

            if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
                print_success "OAuth client created successfully on AIC2"
            else
                print_error "Failed to create OAuth client (HTTP ${http_code})"
                echo "${body}" | jq .
                return 1
            fi
        fi
    fi

    echo ""
    print_info "Step 2: Configuring Static User Mapping on AIC2..."

    if [ "$EXEC_MODE" == "show" ]; then
        echo "" >&2
        print_warning "IMPORTANT: This operation requires TWO steps:" >&2
        print_warning "  1. GET the current authentication configuration" >&2
        print_warning "  2. ADD the new mapping to the existing config" >&2
        print_warning "  3. PUT the COMPLETE updated configuration back" >&2
        echo "" >&2
        print_warning "⚠️  DO NOT PUT just the mapping snippet below!" >&2
        print_warning "⚠️  You MUST include the entire authentication config!" >&2
        echo "" >&2
    fi

    # Get current authentication config
    print_info "STEP 2.1: Getting current authentication configuration..."
    local auth_config=$(execute_curl -s \
        --request GET \
        --header "Authorization: Bearer ${ACCESS_TOKEN_AIC2}" \
        --header "Accept-API-Version: resource=1.0" \
        "https://${AIC2_TENANT}.forgeblocks.com/openidm/config/authentication")

    if ! echo "${auth_config}" | jq -e '.' > /dev/null 2>&1; then
        print_error "Failed to retrieve authentication config from AIC2"
        return 1
    fi

    # Check if static user mapping already exists
    local mapping_exists=$(echo "${auth_config}" | jq -e --arg subject "${EXTERNAL_IDM_CLIENT_ID}" '.staticUserMapping[]? | select(.subject == $subject)')

    if [ -n "${mapping_exists}" ]; then
        print_warning "Static user mapping for '${EXTERNAL_IDM_CLIENT_ID}' already exists"
        echo "${mapping_exists}" | jq .
    else
        if [ "$EXEC_MODE" == "show" ]; then
            echo "" >&2
            print_info "STEP 2.2: The following mapping will be ADDED to the config above:" >&2
            echo '{
  "subject": "'"${EXTERNAL_IDM_CLIENT_ID}"'",
  "localUser": "internal/user/openidm-admin",
  "roles": [
    "internal/role/openidm-authorized",
    "internal/role/openidm-admin",
    "internal/role/platform-provisioning"
  ],
  "userRoles": "authzRoles/*"
}' >&2
            echo "" >&2
            print_warning "STEP 2.3: Putting back the COMPLETE authentication config with new mapping:" >&2
            print_warning "  (The --data below contains the FULL config, not just the snippet above)" >&2
            echo "" >&2
        else
            print_info "Adding static user mapping for '${EXTERNAL_IDM_CLIENT_ID}'..."
        fi

        # Add new static user mapping
        local updated_config=$(echo "${auth_config}" | jq \
            --arg subject "${EXTERNAL_IDM_CLIENT_ID}" \
            '.staticUserMapping += [{
                "subject": $subject,
                "localUser": "internal/user/openidm-admin",
                "roles": [
                    "internal/role/openidm-authorized",
                    "internal/role/openidm-admin",
                    "internal/role/platform-provisioning"
                ],
                "userRoles": "authzRoles/*"
            }]')

        local auth_response=$(execute_curl -s -w "\n%{http_code}" \
            --request PUT \
            --header "Authorization: Bearer ${ACCESS_TOKEN_AIC2}" \
            --header "Content-Type: application/json" \
            --header "Accept-API-Version: resource=1.0" \
            --data "${updated_config}" \
            "https://${AIC2_TENANT}.forgeblocks.com/openidm/config/authentication")

        local http_code=$(echo "$auth_response" | tail -n1)
        local body=$(echo "$auth_response" | sed '$d')

        if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
            print_success "Static user mapping added successfully on AIC2"
        else
            print_error "Failed to update authentication config (HTTP ${http_code})"
            echo "${body}" | jq .
            return 1
        fi
    fi

    echo ""
    if [ "$EXEC_MODE" == "show" ]; then
        print_success "SHOW MODE: All commands for AIC2 configuration displayed above"
    else
        print_success "AIC2 configuration completed successfully!"
    fi
}

################################################################################

# Configure AIC1 (Source Instance) - External IDM Proxy Configuration
# Sets up AIC1 to connect to AIC2 through an external IDM proxy
#
# What this function does:
#   1. Obtains service account token for AIC1
#   2. Creates external IDM proxy configuration (if not exists)
#   3. Configures OAuth bearer authentication to AIC2
#
# The external IDM proxy allows AIC1 to query data from AIC2 as if it were
# local. API calls to /openidm/external/idm/{config-name}/ are proxied to AIC2.
#
# Important paths:
#   - Configuration storage: /openidm/config/external.idm-{config-name}
#   - Runtime access: /openidm/external/idm/{config-name}/
#
# Prerequisites:
#   - AIC2 must be configured first (run configure_aic2())
#   - OAuth client must exist on AIC2
#   - Static user mapping must be configured on AIC2
configure_aic1() {
    echo ""
    echo "========================================="
    echo "   Configure AIC1 (Source)"
    echo "========================================="

    print_info "Getting service account token for AIC1..."

    # Get access token
    get_access_token "$AIC1_TENANT" "$AIC1_SERVICE_ACCOUNT_ID" "$AIC1_JWK_PATH" "AIC1"

    if [ -z "${ACCESS_TOKEN_AIC1}" ]; then
        print_error "Failed to obtain access token for AIC1"
        return 1
    fi

    echo ""
    print_info "Creating External IDM Proxy Config..."

    # Check if proxy config already exists
    print_info "STEP 1: Checking if proxy config exists..."
    local config_check=$(execute_curl -s \
        --request GET \
        --header "Authorization: Bearer ${ACCESS_TOKEN_AIC1}" \
        --header "Accept-API-Version: resource=1.0" \
        "https://${AIC1_TENANT}.forgeblocks.com/openidm/config/external.idm-${EXTERNAL_IDM_CONFIG_NAME}")

    if [ "$EXEC_MODE" == "show" ]; then
        # In show mode, display both the check and create commands
        echo "" >&2
        print_info "STEP 2: Create proxy config if not exists:" >&2
        echo "" >&2
    fi

    if echo "${config_check}" | jq -e '.enabled' > /dev/null 2>&1; then
        if [ "$EXEC_MODE" != "show" ]; then
            print_warning "External IDM proxy config 'external.idm-${EXTERNAL_IDM_CONFIG_NAME}' already exists"
            echo "${config_check}" | jq -r '.instanceUrl, .tokenEndpoint'
        fi
    fi

    # Always prepare the payload
    local target_instance_url="https://${AIC2_TENANT}.forgeblocks.com/openidm/"
    local target_token_endpoint="https://${AIC2_TENANT}.forgeblocks.com/am/oauth2/realms/${EXTERNAL_IDM_REALM}/access_token"

    local proxy_payload=$(cat <<EOF
{
  "enabled": true,
  "authType": "bearer",
  "instanceUrl": "${target_instance_url}",
  "clientId": "${EXTERNAL_IDM_CLIENT_ID}",
  "clientSecret": "${EXTERNAL_IDM_CLIENT_SECRET}",
  "scope": [
    "fr:idm:*"
  ],
  "tokenEndpoint": "${target_token_endpoint}",
  "tokenEndpointAuthMethod": "client_secret_post",
  "scopeDelimiter": " "
}
EOF
)

    # In show mode, always display the create command; in run mode, only if config doesn't exist
    if [ "$EXEC_MODE" == "show" ] || ! echo "${config_check}" | jq -e '.enabled' > /dev/null 2>&1; then
        if [ "$EXEC_MODE" != "show" ]; then
            print_info "Creating external IDM proxy config..."
        fi

        local proxy_response=$(execute_curl -s -w "\n%{http_code}" \
            --request PUT \
            --header "Authorization: Bearer ${ACCESS_TOKEN_AIC1}" \
            --header "Content-Type: application/json" \
            --header "Accept: application/json" \
            --data "${proxy_payload}" \
            "https://${AIC1_TENANT}.forgeblocks.com/openidm/config/external.idm-${EXTERNAL_IDM_CONFIG_NAME}")

        if [ "$EXEC_MODE" != "show" ]; then
            local http_code=$(echo "$proxy_response" | tail -n1)
            local body=$(echo "$proxy_response" | sed '$d')

            if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
                print_success "External IDM proxy config created successfully"
            else
                print_error "Failed to create external IDM proxy config (HTTP ${http_code})"
                echo "${body}" | jq .
                return 1
            fi
        fi
    fi

    echo ""
    if [ "$EXEC_MODE" == "show" ]; then
        print_success "SHOW MODE: All commands for AIC1 proxy configuration displayed above"
    else
        print_success "AIC1 proxy configuration completed successfully!"
    fi
}

# Function to delete external IDM proxy config
delete_proxy_config() {
    print_info "Getting service account token for AIC1..."
    get_access_token "$AIC1_TENANT" "$AIC1_SERVICE_ACCOUNT_ID" "$AIC1_JWK_PATH" "AIC1"

    if [ -z "${ACCESS_TOKEN_AIC1}" ]; then
        print_error "Failed to obtain access token for AIC1"
        return 1
    fi

    echo ""
    print_warning "This will delete external IDM proxy config: external.idm-${EXTERNAL_IDM_CONFIG_NAME}"

    if [ "$1" != "auto" ]; then
        echo -n "Are you sure? (yes/no): "
        read -r confirmation

        if [ "$confirmation" != "yes" ]; then
            print_info "Deletion cancelled"
            return 0
        fi
    fi

    local response=$(execute_curl -s -w "\n%{http_code}" \
        --request DELETE \
        --header "Authorization: Bearer ${ACCESS_TOKEN_AIC1}" \
        --header "Accept: application/json" \
        "https://${AIC1_TENANT}.forgeblocks.com/openidm/config/external.idm-${EXTERNAL_IDM_CONFIG_NAME}")

    local http_code=$(echo "$response" | tail -n1)

    if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 204 ]; then
        print_success "External IDM proxy config deleted successfully"
    elif [ "$http_code" -eq 404 ]; then
        print_warning "Config not found (already deleted)"
    else
        print_error "Failed to delete config (HTTP ${http_code})"
    fi
}

# Function to delete sync mapping
delete_sync_mapping() {
    print_info "Getting service account token for AIC1..."
    get_access_token "$AIC1_TENANT" "$AIC1_SERVICE_ACCOUNT_ID" "$AIC1_JWK_PATH" "AIC1"

    if [ -z "${ACCESS_TOKEN_AIC1}" ]; then
        print_error "Failed to obtain access token for AIC1"
        return 1
    fi

    echo ""
    print_warning "This will delete sync mapping: aic1_to_aic2_user_sync"

    if [ "$1" != "auto" ]; then
        echo -n "Are you sure? (yes/no): "
        read -r confirmation

        if [ "$confirmation" != "yes" ]; then
            print_info "Deletion cancelled"
            return 0
        fi
    fi

    if [ "$EXEC_MODE" == "show" ]; then
        echo "" >&2
        print_warning "IMPORTANT: This operation requires multiple steps:" >&2
        print_warning "  1. GET the current sync configuration" >&2
        print_warning "  2. REMOVE the mapping from the config" >&2
        print_warning "  3. PUT the COMPLETE updated configuration back" >&2
        echo "" >&2
        print_warning "⚠️  The PUT must contain ALL remaining mappings!" >&2
        echo "" >&2
    fi

    # Get current sync config
    print_info "Getting current sync configuration..."
    local sync_config=$(execute_curl -s \
        --request GET \
        --header "Authorization: Bearer ${ACCESS_TOKEN_AIC1}" \
        --header "Accept-API-Version: resource=1.0" \
        "https://${AIC1_TENANT}.forgeblocks.com/openidm/config/sync")

    # Remove the mapping
    local updated_sync=$(echo "${sync_config}" | jq 'del(.mappings[] | select(.name == "aic1_to_aic2_user_sync"))')

    if [ "$EXEC_MODE" == "show" ]; then
        echo "" >&2
        print_warning "Putting back the COMPLETE sync config with mapping removed:" >&2
        print_warning "  (The --data below contains ALL remaining mappings)" >&2
        echo "" >&2
    fi

    local response=$(execute_curl -s -w "\n%{http_code}" \
        --request PUT \
        --header "Authorization: Bearer ${ACCESS_TOKEN_AIC1}" \
        --header "Content-Type: application/json" \
        --header "Accept-API-Version: resource=1.0" \
        --data "${updated_sync}" \
        "https://${AIC1_TENANT}.forgeblocks.com/openidm/config/sync")

    local http_code=$(echo "$response" | tail -n1)

    if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
        print_success "Sync mapping deleted successfully"
    else
        print_error "Failed to delete sync mapping (HTTP ${http_code})"
    fi
}

# Function to delete OAuth client
delete_oauth_client() {
    print_info "Getting service account token for AIC2..."
    get_access_token "$AIC2_TENANT" "$AIC2_SERVICE_ACCOUNT_ID" "$AIC2_JWK_PATH" "AIC2" "fr:am:*"

    if [ -z "${ACCESS_TOKEN_AIC2}" ]; then
        print_error "Failed to obtain access token for AIC2"
        return 1
    fi

    echo ""
    print_warning "This will delete OAuth client: ${EXTERNAL_IDM_CLIENT_ID} on AIC2"

    if [ "$1" != "auto" ]; then
        echo -n "Are you sure? (yes/no): "
        read -r confirmation

        if [ "$confirmation" != "yes" ]; then
            print_info "Deletion cancelled"
            return 0
        fi
    fi

    local response=$(execute_curl -s -w "\n%{http_code}" \
        --request DELETE \
        --header "Authorization: Bearer ${ACCESS_TOKEN_AIC2}" \
        --header "Accept-API-Version: resource=1.0" \
        "https://${AIC2_TENANT}.forgeblocks.com/am/json/realms/root/realms/${EXTERNAL_IDM_REALM}/realm-config/agents/OAuth2Client/${EXTERNAL_IDM_CLIENT_ID}")

    local http_code=$(echo "$response" | tail -n1)

    if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 204 ]; then
        print_success "OAuth client deleted successfully"
    elif [ "$http_code" -eq 404 ]; then
        print_warning "OAuth client not found (already deleted)"
    else
        print_error "Failed to delete OAuth client (HTTP ${http_code})"
    fi
}

# Function to delete static user mapping
delete_static_user_mapping() {
    print_info "Getting service account token for AIC2..."
    get_access_token "$AIC2_TENANT" "$AIC2_SERVICE_ACCOUNT_ID" "$AIC2_JWK_PATH" "AIC2" "fr:idm:*"

    if [ -z "${ACCESS_TOKEN_AIC2}" ]; then
        print_error "Failed to obtain access token for AIC2"
        return 1
    fi

    echo ""
    print_warning "This will remove static user mapping for: ${EXTERNAL_IDM_CLIENT_ID} on AIC2"

    if [ "$1" != "auto" ]; then
        echo -n "Are you sure? (yes/no): "
        read -r confirmation

        if [ "$confirmation" != "yes" ]; then
            print_info "Deletion cancelled"
            return 0
        fi
    fi

    if [ "$EXEC_MODE" == "show" ]; then
        echo "" >&2
        print_warning "IMPORTANT: This operation requires multiple steps:" >&2
        print_warning "  1. GET the current authentication configuration" >&2
        print_warning "  2. REMOVE the static user mapping from the config" >&2
        print_warning "  3. PUT the COMPLETE updated configuration back" >&2
        echo "" >&2
        print_warning "⚠️  The PUT must contain the ENTIRE auth config!" >&2
        echo "" >&2
    fi

    # Get current authentication config
    print_info "Getting current authentication configuration..."
    local auth_config=$(execute_curl -s \
        --request GET \
        --header "Authorization: Bearer ${ACCESS_TOKEN_AIC2}" \
        --header "Accept-API-Version: resource=1.0" \
        "https://${AIC2_TENANT}.forgeblocks.com/openidm/config/authentication")

    # Remove the static user mapping
    local updated_auth=$(echo "${auth_config}" | jq --arg subject "${EXTERNAL_IDM_CLIENT_ID}" 'del(.staticUserMapping[] | select(.subject == $subject))')

    if [ "$EXEC_MODE" == "show" ]; then
        echo "" >&2
        print_warning "Putting back the COMPLETE authentication config with mapping removed:" >&2
        print_warning "  (The --data below contains the FULL config, not just a snippet)" >&2
        echo "" >&2
    fi

    local response=$(execute_curl -s -w "\n%{http_code}" \
        --request PUT \
        --header "Authorization: Bearer ${ACCESS_TOKEN_AIC2}" \
        --header "Content-Type: application/json" \
        --header "Accept-API-Version: resource=1.0" \
        --data "${updated_auth}" \
        "https://${AIC2_TENANT}.forgeblocks.com/openidm/config/authentication")

    local http_code=$(echo "$response" | tail -n1)

    if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
        print_success "Static user mapping removed successfully"
    else
        print_error "Failed to remove static user mapping (HTTP ${http_code})"
    fi
}

# Function to delete all configurations in proper order
delete_all_configurations() {
    echo ""
    echo "========================================="
    echo "   Delete ALL Configurations"
    echo "========================================="
    print_warning "This will delete ALL configurations in the following order:"
    echo "  1. Sync Mapping (AIC1)"
    echo "  2. External IDM Proxy Config (AIC1)"
    echo "  3. Static User Mapping (AIC2)"
    echo "  4. OAuth Client (AIC2)"
    echo ""
    print_warning "⚠️  This action will remove all configurations created by this script!"
    echo -n "Are you ABSOLUTELY sure? (yes/no): "
    read -r confirmation

    if [ "$confirmation" != "yes" ]; then
        print_info "Deletion cancelled"
        return 0
    fi

    echo ""
    print_info "Starting deletion of all configurations..."
    echo ""

    # Delete in reverse order of creation
    print_info "=== Step 1/4: Deleting Sync Mapping (AIC1) ==="
    delete_sync_mapping "auto"

    echo ""
    print_info "=== Step 2/4: Deleting External IDM Proxy Config (AIC1) ==="
    delete_proxy_config "auto"

    echo ""
    print_info "=== Step 3/4: Deleting Static User Mapping (AIC2) ==="
    delete_static_user_mapping "auto"

    echo ""
    print_info "=== Step 4/4: Deleting OAuth Client (AIC2) ==="
    delete_oauth_client "auto"

    echo ""
    print_success "All delete operations completed!"
}

################################################################################
# DELETION FUNCTIONS
################################################################################

# Delete Configurations Menu
# Provides submenu for deleting various AIC configurations
#
# Options:
#   1. Delete External IDM Proxy Config (AIC1) - Removes proxy connection
#   2. Delete Sync Mapping (AIC1) - Removes user sync configuration
#   3. Delete OAuth Client (AIC2) - Removes OAuth client from target
#   4. Delete Static User Mapping (AIC2) - Removes authentication mapping
#   5. Delete ALL Configurations - Runs deletions in proper order (2,1,4,3)
#   6. Back to Main Menu - Returns without deleting
#
# All deletions require "yes" confirmation and automatically obtain
# necessary access tokens before executing.
delete_configurations() {
    echo ""
    echo "========================================="
    echo "   Delete Configurations"
    echo "========================================="
    echo "1. Delete External IDM Proxy Config (AIC1)"
    echo "2. Delete Sync Mapping (AIC1)"
    echo "3. Delete OAuth Client (AIC2)"
    echo "4. Delete Static User Mapping (AIC2)"
    echo "5. Delete ALL Configurations (runs 2,1,4,3 in order)"
    echo "6. Back to Main Menu"
    echo "========================================="
    echo -n "Select what to delete [1-6]: "
    read -r delete_choice

    case $delete_choice in
        1)
            delete_proxy_config
            ;;

        2)
            delete_sync_mapping
            ;;

        3)
            delete_oauth_client
            ;;

        4)
            delete_static_user_mapping
            ;;

        5)
            delete_all_configurations
            ;;

        6)
            return 0
            ;;

        *)
            print_error "Invalid option"
            ;;
    esac
}


################################################################################
# MENU AND USER INTERFACE FUNCTIONS
################################################################################

# Select Execution Mode
# Prompts user to choose between display mode and execute mode
#
# Modes:
#   1. Show curl commands (display only)
#      - Displays formatted curl commands without executing
#      - Safe for learning and reviewing what will happen
#      - Returns mock responses to allow script to continue
#
#   2. Run curl commands (execute)
#      - Actually executes all API calls
#      - Makes real changes to AIC instances
#      - USE WITH CAUTION in production environments
#
# Sets global EXEC_MODE variable which controls execute_curl() behavior
select_execution_mode() {
    echo ""
    echo "========================================="
    echo "   Execution Mode Selection"
    echo "========================================="
    echo "1. Show curl commands (display only)"
    echo "2. Run curl commands (execute)"
    echo "========================================="
    echo -n "Select mode [1-2]: "
    read -r mode_choice

    case $mode_choice in
        1)
            EXEC_MODE="show"
            print_info "Mode: SHOW COMMANDS (display only)"
            ;;
        2)
            EXEC_MODE="run"
            print_info "Mode: RUN COMMANDS (execute)"
            ;;
        *)
            print_warning "Invalid option. Defaulting to RUN mode"
            EXEC_MODE="run"
            ;;
    esac
    echo ""
}

# Display Main Menu
# Shows primary menu options and current execution mode
#
# Menu Options:
#   1. Configure AIC2 (Target) - Setup target instance for proxy connections
#   2. Configure AIC1 (Source) - Create external IDM proxy to AIC2
#   3. Verify/Test Proxy - Test that proxy works correctly
#   4. Create Sync Mapping - Setup user sync from AIC1 to AIC2
#   5. Delete Configurations - Remove configurations (submenu)
#   6. Change Execution Mode - Switch between show/run modes
#   7. Exit - Quit the script
show_menu() {
    echo ""
    echo "========================================="
    echo "   IDM External Proxy Manager"
    echo "========================================="
    if [ "$EXEC_MODE" == "show" ]; then
        echo -e "${YELLOW}[MODE: SHOW COMMANDS]${NC}"
    else
        echo -e "${GREEN}[MODE: RUN COMMANDS]${NC}"
    fi
    echo "========================================="
    echo "1. Configure AIC2 (Target)"
    echo "2. Configure AIC1 (Source) - Proxy Config"
    echo "3. Verify/Test Proxy Configuration"
    echo "4. Create Sync Mapping (AIC1 -> AIC2)"
    echo "5. Delete Configurations"
    echo "6. Change Execution Mode"
    echo "7. Exit"
    echo "========================================="
    echo -n "Select an option [1-7]: "
}

################################################################################
# MAIN PROGRAM ENTRY POINT
################################################################################

# Main Function - Program Entry Point
# Orchestrates the interactive menu-driven workflow for configuring AIC external
# IDM proxy connections.
#
# Workflow:
#   1. Checks for required dependencies (openssl, jq, jose)
#   2. Prompts user to select execution mode (show/run)
#   3. Displays interactive menu in a loop
#   4. Executes selected operations
#   5. Waits for user confirmation before returning to menu
#
# The script runs in an infinite loop until user selects Exit (option 7)
# or terminates with Ctrl+C.
#
# Recommended workflow for first-time setup:
#   1. Start with "Show commands" mode to preview operations
#   2. Configure AIC2 (Target) first
#   3. Configure AIC1 (Source) second
#   4. Verify/Test the proxy configuration
#   5. Create Sync Mapping if needed
#   6. Switch to "Run commands" mode when ready to execute
main() {
    # Verify all required tools are installed before proceeding
    check_dependencies

    # Let user choose between display mode (safe preview) or execute mode
    select_execution_mode

    # Main interactive loop - continues until user exits
    while true; do
        show_menu
        read -r choice

        case $choice in
            1)
                configure_aic2
                ;;
            2)
                configure_aic1
                ;;
            3)
                echo ""
                echo "--- Verify/Test External IDM Proxy (AIC1 -> AIC2) ---"
                echo "1. Test proxy using service account token"
                echo "2. Test proxy using OAuth client credentials"
                echo -n "Select [1-2]: "
                read -r verify_choice

                case $verify_choice in
                    1)
                        test_external_idm_proxy
                        ;;
                    2)
                        test_external_idm_proxy_with_client
                        ;;
                    *)
                        print_error "Invalid option"
                        ;;
                esac
                ;;
            4)
                create_sync_mapping
                ;;
            5)
                delete_configurations
                ;;
            6)
                select_execution_mode
                ;;
            7)
                print_info "Exiting..."
                exit 0
                ;;
            *)
                print_error "Invalid option. Please select 1-7."
                ;;
        esac

        echo ""
        read -p "Press Enter to continue..."
    done
}

################################################################################
# SCRIPT EXECUTION
################################################################################

# Start the script by calling main function
# This is the entry point - execution begins here
main

################################################################################
# END OF SCRIPT
################################################################################
