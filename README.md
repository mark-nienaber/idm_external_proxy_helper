# IDM External Proxy Manager

Script to manage IDM external proxy configurations for AIC (Advanced Identity Cloud) data migration.

## Overview

This script is an implementation of the **IDM External Proxy** feature documented in Ping Identity's official documentation:

**[IDM External Proxy - Ping Identity Documentation](https://docs.pingidentity.com/pingoneaic/latest/idm-objects/data-rest-proxy.html)**

The IDM External Proxy allows you to configure an external REST endpoint that IDM can use to access data from another IDM instance. This is particularly useful for:
- Cross-tenant data migration in AIC
- Querying users from one AIC instance while managing them in another
- Setting up synchronization mappings between separate AIC environments
- Testing data integration scenarios

This automation script simplifies the setup process by handling OAuth client configuration, static user mapping, external IDM proxy creation, and sync mapping configuration through an interactive menu interface.

## Prerequisites

This script requires the following tools to be installed:

- **OpenSSL**: For generating random values and cryptographic operations
- **jq**: Command-line JSON processor ([Install jq](https://stedolan.github.io/jq/download/))
- **jose**: JavaScript Object Signing and Encryption tools ([Install jose](https://command-not-found.com/jose))

### Installing Dependencies

**macOS:**
```bash
brew install jq jose
```

**Linux:**
```bash
# Debian/Ubuntu
apt-get install jq jose

# RHEL/CentOS/Fedora
dnf install jq jose
```

## Setup

1. **Create keys directory and add service account keys:**
   ```bash
   mkdir -p keys
   ```
   Place your service account private key JWK files in the `keys` folder:
   - `keys/markproxyalpha_privateKey.jwk` (or your AIC1 service account key)
   - `keys/idm2proxy_privateKey.jwk` (or your AIC2 service account key)

2. **Copy the environment template:**
   ```bash
   cp .env.template .env
   ```

3. **Edit `.env` and configure your AIC instances:**
   - `AIC1_TENANT`: Your source AIC tenant name (where the proxy will be created)
   - `AIC1_SERVICE_ACCOUNT_ID`: Service account ID for AIC1
   - `AIC1_JWK_PATH`: Path to the AIC1 private key JWK file (default: `./keys/markproxyalpha_privateKey.jwk`)
   - `AIC2_TENANT`: Your target AIC tenant name (where data will be queried from)
   - `AIC2_SERVICE_ACCOUNT_ID`: Service account ID for AIC2
   - `AIC2_JWK_PATH`: Path to the AIC2 private key JWK file (default: `./keys/idm2proxy_privateKey.jwk`)
   - `EXTERNAL_IDM_CLIENT_ID`: OAuth client ID for proxy authentication to AIC2
   - `EXTERNAL_IDM_CLIENT_SECRET`: OAuth client secret
   - `EXTERNAL_IDM_REALM`: OAuth realm on AIC2 (e.g., alpha or bravo)

4. **Make the script executable:**
   ```bash
   chmod +x idm_external_proxy_manager.sh
   ```

5. **Run the script:**
   ```bash
   ./idm_external_proxy_manager.sh
   ```

**Note**: This is a one-way proxy configuration (AIC1 → AIC2). The proxy is created on AIC1 and points to AIC2.

## Usage

Run the interactive script:
```bash
./idm_external_proxy_manager.sh
```

### Execution Mode Selection

When you first run the script, you'll be prompted to select an execution mode:

**1. Show curl commands (display only)**
- Displays the curl commands that would be executed
- Does not make any actual API calls or changes
- Useful for:
  - Learning what the script does
  - Reviewing commands before execution
  - Copying commands to run manually
  - Understanding the API interactions

**2. Run curl commands (execute)**
- Actually executes the API calls
- Makes real changes to your AIC instances
- Use this mode to perform the actual configuration

You can change the execution mode at any time by selecting **Option 6: Change Execution Mode** from the main menu.

The current mode is displayed at the top of the menu:
- `[MODE: SHOW COMMANDS]` - Display only mode
- `[MODE: RUN COMMANDS]` - Execute mode

### Quick Start - Complete Setup

For a complete end-to-end setup, follow this workflow:

**Initial Setup:**
1. Run the script: `./idm_external_proxy_manager.sh`
2. Select execution mode:
   - Start with **"Show curl commands"** to review what will happen
   - Switch to **"Run curl commands"** when ready to execute

**Configuration Workflow:**

1. **Option 1: Configure AIC2 (Target)**
   - Run this first to configure the target instance
   - Creates OAuth client and static user mapping
   - Checks for existing configurations

2. **Option 2: Configure AIC1 (Source) - Proxy Config**
   - Run this second to configure the source instance
   - Creates external IDM proxy config pointing to AIC2
   - Checks if proxy already exists

3. **Option 3: Verify/Test Proxy Configuration**
   - Test that the proxy works correctly
   - Verify data can be queried from AIC2 through AIC1

4. **Option 4: Create Sync Mapping (AIC1 → AIC2)**
   - Run this last to create the sync mapping
   - Maps local users to external users via proxy

This workflow automates the entire setup process with proper validation and error checking.

### Menu Options

**Note:** All operations are self-contained and automatically obtain the necessary access tokens before executing.

1. **Configure AIC2 (Target)**
   - **Comprehensive configuration of the target instance (AIC2)**
   - Gets service account token with `fr:am:*` and `fr:idm:*` scopes
   - **Step 1:** Creates OAuth client (if not exists)
     - Client ID from `EXTERNAL_IDM_CLIENT_ID`
     - Configured with `client_credentials` grant type
     - Scopes: `fr:idm:*`
   - **Step 2:** Configures static user mapping (if not exists)
     - Retrieves current authentication config
     - Adds static user mapping for OAuth client
     - Maps to `internal/user/openidm-admin` with full permissions
   - Checks for existing configurations before creating

2. **Configure AIC1 (Source) - Proxy Config**
   - **Creates external IDM proxy configuration on AIC1**
   - Gets service account token for AIC1
   - Creates external IDM proxy config (if not exists)
   - Points to AIC2 instance with OAuth authentication
   - Checks if proxy already exists before creating

3. **Verify/Test Proxy Configuration**
   - Tests external IDM proxy configuration by making actual API calls
   - Calls through `/openidm/external/idm/{config-name}/managed/{realm}_user`
   - Sub-options:
     - Test proxy using service account token (auto-fetches service account token)
     - Test proxy using OAuth client credentials (auto-fetches OAuth client token)

4. **Create Sync Mapping (AIC1 → AIC2)**
   - Automatically obtains service account token for AIC1
   - Creates IDM sync mapping configuration (if not exists)
   - Maps `managed/alpha_user` to `external/idm/{config}/managed/{realm}_user`
   - Includes property mappings, policies, and correlation rules
   - Correlates users based on userName

5. **Delete Configurations**
   - Submenu with granular delete options:
     - **Delete External IDM Proxy Config (AIC1)** - Removes proxy configuration
     - **Delete Sync Mapping (AIC1)** - Removes sync mapping only
     - **Delete OAuth Client (AIC2)** - Removes OAuth client from AIC2
     - **Delete Static User Mapping (AIC2)** - Removes static user mapping from AIC2
   - All deletions require confirmation
   - Automatically obtains necessary access tokens

6. **Change Execution Mode**
   - Switch between "Show curl commands" and "Run curl commands" modes
   - Allows you to preview commands before executing them
   - Or switch to execute mode to perform actual changes

7. **Exit**
   - Exit the script

## How It Works

### Service Account Authentication

The script uses the OAuth 2.0 JWT Bearer Grant flow:

1. Creates a JWT with claims:
   - `iss`: Service Account ID (issuer)
   - `sub`: Service Account ID (subject)
   - `aud`: Token endpoint URL
   - `exp`: Expiration time (current time + 3 minutes)
   - `jti`: Unique identifier for the JWT

2. Signs the JWT using RS256 algorithm with your private key

3. Exchanges the signed JWT for an access token at the OAuth2 endpoint

4. Stores the access token for use in API calls

### OAuth Client Credentials Authentication

The script also supports OAuth 2.0 Client Credentials Grant flow for the external IDM proxy client:

1. Sends a POST request to the OAuth2 token endpoint with:
   - `grant_type`: client_credentials
   - `client_id`: OAuth client ID (e.g., "idmprovisioning")
   - `client_secret`: OAuth client secret
   - `scope`: fr:idm:*

2. The token endpoint validates the client credentials

3. Returns an access token with the requested scope

4. Stores the access token in `OAUTH_CLIENT_ACCESS_TOKEN` variable

**Token Endpoint:** `https://{tenant}.forgeblocks.com/am/oauth2/realms/{realm}/access_token`

The OAuth client token is used by the external IDM configuration to authenticate when connecting to the target IDM instance.

### Access Token Testing

Makes a sample IDM API call to:
```
GET /openidm/managed/alpha_user?_queryFilter=true&_pageSize=1
```

This verifies that:
- The token is valid
- The service account has proper IDM scope (`fr:idm:*`)
- The IDM API is accessible

**Note:** This script only requests the `fr:idm:*` scope as it's specifically designed for IDM proxy operations.

### Creating External IDM Configurations

The script creates external IDM configurations using the IDM REST API:

**Important Path Distinction:**
- **Configuration storage**: `/openidm/config/external.idm-{config-name}` (uses **hyphen**)
- **Runtime access**: `/openidm/external/idm/{config-name}` (uses **slashes**)

**Endpoint:**
```
PUT /openidm/config/external.idm-{config-name}
```

**Configuration Payload:**
```json
{
  "enabled": true,
  "authType": "bearer",
  "instanceUrl": "https://{target-tenant}.forgeblocks.com/openidm/",
  "clientId": "idmprovisioning",
  "clientSecret": "password",
  "scope": [
    "fr:idm:*"
  ],
  "tokenEndpoint": "https://{target-tenant}.forgeblocks.com/am/oauth2/realms/{realm}/access_token",
  "tokenEndpointAuthMethod": "client_secret_post",
  "scopeDelimiter": " "
}
```

**How it works:**
- **Option 4** creates config on AIC1 pointing to AIC2 (one-way: AIC1 → AIC2)
- OAuth bearer authentication is used to connect to the target instance (AIC2)
- Uses `client_secret_post` method for token endpoint authentication (sends client credentials in POST body)
- The config is identified by `EXTERNAL_IDM_CONFIG_NAME` (default: "idm2")

**Environment Variables:**
- `EXTERNAL_IDM_CONFIG_NAME`: Name of the external IDM config (e.g., "idm2")
- `EXTERNAL_IDM_CLIENT_ID`: OAuth client ID for authentication to target (e.g., "idmprovisioning")
- `EXTERNAL_IDM_CLIENT_SECRET`: OAuth client secret for authentication to target
- `EXTERNAL_IDM_REALM`: OAuth realm (default: "bravo")
- `OAUTH_CLIENT_ACCESS_TOKEN`: Stores the OAuth client access token retrieved via client credentials flow

### Verifying/Testing External IDM Proxy

After creating the external IDM configurations, you can verify they're working by testing the proxy:

**Endpoint Pattern:**
```
GET /openidm/external/idm/{config-name}/managed/{realm}_user?_queryFilter=true&_pageSize=1
```

**Example:**
```
GET /openidm/external/idm/idm2/managed/alpha_user?_queryFilter=true&_pageSize=1
```

**How it works:**
1. Makes a call FROM the source instance THROUGH the external IDM config TO the target instance
2. The call goes through `/openidm/external/idm/{config-name}/` which routes to the configured target
3. Uses the OAuth client credentials configured in the external IDM config to authenticate
4. Retrieves managed users from the target instance
5. Returns results through the proxy

**Testing Options:**

Both testing options are fully self-contained and automatically obtain the necessary access tokens.

**Option 1: Using Service Account Token**
- Automatically obtains AIC1 service account access token
- Uses JWT bearer authentication
- Tests with admin-level permissions
- Good for verifying the proxy works with service account credentials

**Option 2: Using OAuth Client Credentials**
- Automatically obtains OAuth token using client credentials flow
- Uses `EXTERNAL_IDM_CLIENT_ID` and `EXTERNAL_IDM_CLIENT_SECRET` from .env
- Authenticates against `EXTERNAL_IDM_REALM` on AIC1 (e.g., alpha or bravo)
- Simulates how the external IDM proxy authenticates to the target instance
- Good for verifying the OAuth client has proper permissions

**Testing scenario:**
- **AIC1 → AIC2**: Call from AIC1 through its external config to retrieve users from AIC2

If the proxy is configured correctly, you should receive user data from AIC2. If it fails, check:
- External IDM config exists and is enabled on AIC1
- OAuth client credentials are correct
- OAuth client has `fr:idm:*` scope on AIC2
- Token endpoint is correct (realm: alpha or bravo on AIC2)
- OAuth client exists in the correct realm on AIC2
- OAuth client is mapped in staticUserMapping on AIC2

### Deleting External IDM Configurations

You can delete external IDM configurations when they're no longer needed:

**Endpoint:**
```
DELETE /openidm/config/external.idm-{config-name}
```

**How it works:**
1. Prompts for confirmation before deletion (type "yes" to confirm)
2. Sends DELETE request to remove the configuration from AIC1
3. Returns success (HTTP 200/204) or not found (HTTP 404) status
4. Configuration is permanently removed from AIC1

**Safety features:**
- Requires explicit "yes" confirmation
- Shows config name before deletion
- Handles cases where config doesn't exist

**Use cases:**
- Cleaning up test configurations
- Removing the proxy connection
- Resetting configuration before recreating
- Decommissioning data migration setup

## Project Structure

```
.
├── .env                             # Your environment configuration (not tracked)
├── .env.template                    # Environment template
├── .gitignore                       # Git ignore rules
├── idm_external_proxy_manager.sh    # Main script
├── README.md                        # This file
└── keys/                            # Directory for service account keys (not tracked)
    ├── markproxyalpha_privateKey.jwk   # AIC1 service account private key
    └── idm2proxy_privateKey.jwk        # AIC2 service account private key
```

## Security Notes

- Never commit `.env`, `keys/` folder, or `.jwk` files to version control
- Store all service account private keys in the `keys/` directory
- Access tokens expire after a set period and need to be regenerated
- Temporary JWT files are automatically cleaned up after token generation
- Private keys should be kept secure with appropriate file permissions (600)
- The `keys/` directory is included in `.gitignore` to prevent accidental commits

## Credits

Based on `service_accounts.sh` by Darinder S Shokar - ForgeRock Professional Services
