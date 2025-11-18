#!/bin/bash

# Fix the authentication config on AIC2
# Move staticUserMapping from root level to rsFilter.staticUserMapping

source .env

echo "Fixing Authentication Config on AIC2..."
echo "========================================"
echo ""

# Get token for AIC2
aud="https://${AIC2_TENANT}.forgeblocks.com:443/am/oauth2/access_token"
exp=$(($(date -u +%s) + 180))
jti=$(openssl rand -base64 16)

echo -n "{\"iss\":\"${AIC2_SERVICE_ACCOUNT_ID}\",\"sub\":\"${AIC2_SERVICE_ACCOUNT_ID}\",\"aud\":\"${aud}\",\"exp\":${exp},\"jti\":\"${jti}\"}" > temp_fix.json

jose jws sig -I temp_fix.json -k ${AIC2_JWK_PATH} -s '{"alg":"RS256"}' -c -o temp_fix_signed.txt 2>/dev/null

token_response=$(curl -s --request POST ${aud} \
  --data "client_id=service-account" \
  --data "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
  --data "assertion=$(< temp_fix_signed.txt)" \
  --data "scope=fr:idm:*")

access_token=$(echo ${token_response} | jq -r .access_token)

if [ "$access_token" = "null" ] || [ -z "$access_token" ]; then
  echo "❌ Failed to get access token"
  rm -f temp_fix.json temp_fix_signed.txt
  exit 1
fi

echo "✓ Got access token"
echo ""

# Get current auth config
echo "Getting current authentication config..."
auth_config=$(curl -s \
  --request GET \
  --header "Authorization: Bearer ${access_token}" \
  --header "Accept-API-Version: resource=1.0" \
  "https://${AIC2_TENANT}.forgeblocks.com/openidm/config/authentication")

echo "Current config has:"
echo "  - Root level staticUserMapping: $(echo "$auth_config" | jq '.staticUserMapping | length') entries"
echo "  - rsFilter.staticUserMapping: $(echo "$auth_config" | jq '.rsFilter.staticUserMapping | length') entries"
echo ""

# Move mapping from root to rsFilter.staticUserMapping
echo "Moving staticUserMapping from root to rsFilter..."

fixed_config=$(echo "$auth_config" | jq '
  # Get the mapping from root level (if it exists)
  if .staticUserMapping then
    # Add it to rsFilter.staticUserMapping
    .rsFilter.staticUserMapping = (.rsFilter.staticUserMapping + .staticUserMapping)
    # Remove from root level
    | del(.staticUserMapping)
  else
    .
  end
')

echo "Fixed config has:"
echo "  - Root level staticUserMapping: $(echo "$fixed_config" | jq 'has("staticUserMapping")')"
echo "  - rsFilter.staticUserMapping: $(echo "$fixed_config" | jq '.rsFilter.staticUserMapping | length') entries"
echo ""

echo "Mapping that will be in rsFilter.staticUserMapping:"
echo "$fixed_config" | jq '.rsFilter.staticUserMapping'
echo ""

# Put the fixed config back
echo "Updating authentication config..."
response=$(curl -s -w "\n%{http_code}" \
  --request PUT \
  --header "Authorization: Bearer ${access_token}" \
  --header "Content-Type: application/json" \
  --header "Accept-API-Version: resource=1.0" \
  --data "${fixed_config}" \
  "https://${AIC2_TENANT}.forgeblocks.com/openidm/config/authentication")

http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

if [ "$http_code" = "200" ]; then
  echo "✅ SUCCESS! Authentication config fixed"
  echo ""
  echo "Static user mapping is now in the correct location (rsFilter.staticUserMapping)"
else
  echo "❌ FAILED with HTTP $http_code"
  echo "$body" | jq .
fi

# Clean up
rm -f temp_fix.json temp_fix_signed.txt

echo ""
echo "Now test the proxy again with Option 3!"
