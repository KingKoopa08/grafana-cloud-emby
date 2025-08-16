#!/bin/bash

# Test all possible authentication methods and endpoints
# Since the key shows "last used" but still gets 401, something else is wrong

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  TEST ALL AUTHENTICATION METHODS${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Load config
source /opt/grafana-cloud-emby/config/config.env

USER_ID="${GRAFANA_CLOUD_USER}"
API_KEY="${GRAFANA_CLOUD_LOGS_API_KEY}"

echo "Testing with:"
echo "User ID: $USER_ID"
echo "API Key: ${API_KEY:0:50}..."
echo ""

# Decode the key to see details
if [[ "$API_KEY" =~ ^glc_ ]]; then
    KEY_PAYLOAD="${API_KEY:4}"
    if echo "$KEY_PAYLOAD" | base64 -d 2>/dev/null | jq . 2>/dev/null > /dev/null; then
        echo "Key details:"
        echo "$KEY_PAYLOAD" | base64 -d | jq .
        echo ""
    fi
fi

# Test payload
TIMESTAMP=$(date +%s%N)
PAYLOAD='{"streams":[{"stream":{"job":"test","source":"test-script"},"values":[["'$TIMESTAMP'","Test message"]]}]}'

echo -e "${BLUE}1. TESTING DIFFERENT LOKI ENDPOINTS${NC}"
echo "────────────────────────────────"

ENDPOINTS=(
    "https://logs-prod-021.grafana.net/loki/api/v1/push"
    "https://logs-prod-06.grafana.net/loki/api/v1/push"
    "https://logs-prod-012.grafana.net/loki/api/v1/push"
    "https://logs-prod3.grafana.net/loki/api/v1/push"
    "https://logs-prod-us-west-0.grafana.net/loki/api/v1/push"
    "https://2607589.grafana.net/loki/api/v1/push"
)

for endpoint in "${ENDPOINTS[@]}"; do
    echo -n "Testing $endpoint ... "
    RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -u "${USER_ID}:${API_KEY}" \
        -d "$PAYLOAD" \
        "$endpoint" 2>/dev/null || echo "000")
    
    if [ "$RESULT" = "204" ] || [ "$RESULT" = "200" ]; then
        echo -e "${GREEN}SUCCESS ($RESULT)${NC} <-- THIS WORKS!"
        WORKING_ENDPOINT="$endpoint"
    elif [ "$RESULT" = "401" ]; then
        echo -e "${RED}AUTH FAILED ($RESULT)${NC}"
    elif [ "$RESULT" = "404" ]; then
        echo "NOT FOUND ($RESULT)"
    else
        echo "ERROR ($RESULT)"
    fi
done

echo ""
echo -e "${BLUE}2. TESTING DIFFERENT AUTH FORMATS${NC}"
echo "────────────────────────────────"

# Use the main endpoint
ENDPOINT="https://logs-prod-021.grafana.net/loki/api/v1/push"

echo "Testing endpoint: $ENDPOINT"
echo ""

# Test 1: Basic auth with user:key
echo -n "Basic auth (user:key): "
RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -u "${USER_ID}:${API_KEY}" \
    -d "$PAYLOAD" \
    "$ENDPOINT" 2>/dev/null)
echo "HTTP $RESULT"

# Test 2: Bearer token with user:key
echo -n "Bearer token (user:key): "
RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${USER_ID}:${API_KEY}" \
    -d "$PAYLOAD" \
    "$ENDPOINT" 2>/dev/null)
echo "HTTP $RESULT"

# Test 3: Just the API key as bearer
echo -n "Bearer token (key only): "
RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -d "$PAYLOAD" \
    "$ENDPOINT" 2>/dev/null)
echo "HTTP $RESULT"

# Test 4: X-API-Key header
echo -n "X-API-Key header: "
RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-API-Key: ${API_KEY}" \
    -H "X-Grafana-User: ${USER_ID}" \
    -d "$PAYLOAD" \
    "$ENDPOINT" 2>/dev/null)
echo "HTTP $RESULT"

# Test 5: Grafana-specific headers
echo -n "X-Grafana-Token header: "
RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-Grafana-Token: ${API_KEY}" \
    -d "$PAYLOAD" \
    "$ENDPOINT" 2>/dev/null)
echo "HTTP $RESULT"

echo ""
echo -e "${BLUE}3. TESTING WITH TENANT ID${NC}"
echo "────────────────────────────────"

# Test with tenant ID in header
echo -n "With X-Scope-OrgID: "
RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-Scope-OrgID: ${USER_ID}" \
    -u "${USER_ID}:${API_KEY}" \
    -d "$PAYLOAD" \
    "$ENDPOINT" 2>/dev/null)
echo "HTTP $RESULT"

echo -n "With X-Org-ID: "
RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-Org-ID: 1504078" \
    -u "${USER_ID}:${API_KEY}" \
    -d "$PAYLOAD" \
    "$ENDPOINT" 2>/dev/null)
echo "HTTP $RESULT"

echo ""
echo -e "${BLUE}4. TESTING PROMETHEUS ENDPOINT${NC}"
echo "────────────────────────────────"

# Test if metrics auth works
echo -n "Testing metrics auth: "
METRICS_KEY="${GRAFANA_CLOUD_API_KEY}"
RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${USER_ID}:${METRICS_KEY}" \
    "https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/api/v1/query?query=up" 2>/dev/null)

if [ "$RESULT" = "200" ]; then
    echo -e "${GREEN}Metrics auth works!${NC}"
else
    echo -e "${RED}Metrics auth failed ($RESULT)${NC}"
fi

echo ""
echo -e "${BLUE}5. TESTING DIFFERENT USER IDS${NC}"
echo "────────────────────────────────"

# Sometimes the org ID is different from user ID
echo -n "With org ID 1504078: "
RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -u "1504078:${API_KEY}" \
    -d "$PAYLOAD" \
    "$ENDPOINT" 2>/dev/null)
echo "HTTP $RESULT"

echo -n "With no user ID: "
RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Basic $(echo -n ":${API_KEY}" | base64)" \
    -d "$PAYLOAD" \
    "$ENDPOINT" 2>/dev/null)
echo "HTTP $RESULT"

echo ""
echo -e "${BLUE}6. VERBOSE TEST WITH FULL RESPONSE${NC}"
echo "────────────────────────────────"

echo "Making verbose request to see full error..."
echo ""

RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -u "${USER_ID}:${API_KEY}" \
    -d "$PAYLOAD" \
    "$ENDPOINT" 2>&1)

HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
BODY=$(echo "$RESPONSE" | grep -v "HTTP_CODE:")

echo "Response code: $HTTP_CODE"
echo "Response body:"
echo "$BODY" | jq . 2>/dev/null || echo "$BODY"

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  SUMMARY${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

if [ -n "${WORKING_ENDPOINT:-}" ]; then
    echo -e "${GREEN}FOUND WORKING ENDPOINT: $WORKING_ENDPOINT${NC}"
    echo ""
    echo "Update your agent.yaml to use this endpoint!"
    echo ""
    echo "Run:"
    echo "sudo sed -i 's|url: .*grafana.net.*|url: $WORKING_ENDPOINT|g' /etc/grafana-agent/agent.yaml"
    echo "sudo systemctl restart grafana-agent"
else
    echo -e "${RED}No working endpoint found.${NC}"
    echo ""
    echo "This suggests either:"
    echo "1. The API key doesn't have logs:write permission (despite what the UI shows)"
    echo "2. The account doesn't have Loki/logs enabled"
    echo "3. There's an account/org mismatch"
    echo ""
    echo "Try creating a brand new API key with these EXACT permissions:"
    echo "- metrics:write"
    echo "- logs:write"
    echo "- traces:write (optional)"
    echo ""
    echo "Make sure you're in the right organization in Grafana Cloud."
fi