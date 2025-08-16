#!/bin/bash

# Comprehensive troubleshooting script for Grafana logs authentication issues
# This gathers all configuration and tests to diagnose 401 errors

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
echo -e "${CYAN}  COMPREHENSIVE LOGS AUTHENTICATION TROUBLESHOOTING${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Generated: $(date)"
echo ""

# Create output file
OUTPUT_FILE="/tmp/grafana-logs-troubleshoot-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee -a "$OUTPUT_FILE")
exec 2>&1

echo -e "${BLUE}1. SYSTEM INFORMATION${NC}"
echo "────────────────────────────────"
echo "Hostname: $(hostname)"
echo "Date: $(date)"
echo "Timezone: $(timedatectl show --property=Timezone --value 2>/dev/null || echo "Unknown")"
echo "Agent Version:"
grafana-agent --version 2>/dev/null | head -1 || echo "Unable to get version"
echo ""

echo -e "${BLUE}2. CONFIGURATION FILES${NC}"
echo "────────────────────────────────"

# Check config.env
CONFIG_FILE="/opt/grafana-cloud-emby/config/config.env"
if [ -f "$CONFIG_FILE" ]; then
    echo -e "${GREEN}✓${NC} config.env exists"
    echo ""
    echo "config.env contents (keys masked):"
    echo "-----------------------------------"
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "$line" ]]; then
            echo "$line"
        elif [[ "$line" =~ = ]]; then
            key="${line%%=*}"
            value="${line#*=}"
            if [[ "$key" =~ (KEY|TOKEN|PASSWORD|SECRET) ]]; then
                # Show first 20 chars and last 4
                if [ ${#value} -gt 24 ]; then
                    masked="${value:0:20}...${value: -4}"
                else
                    masked="${value:0:10}..."
                fi
                echo "${key}=${masked}"
            else
                echo "$line"
            fi
        else
            echo "$line"
        fi
    done < "$CONFIG_FILE"
    echo "-----------------------------------"
    
    # Source it for use in tests
    source "$CONFIG_FILE"
else
    echo -e "${RED}✗${NC} config.env not found"
fi
echo ""

echo -e "${BLUE}3. AGENT CONFIGURATION${NC}"
echo "────────────────────────────────"

AGENT_CONFIG="/etc/grafana-agent/agent.yaml"
if [ -f "$AGENT_CONFIG" ]; then
    echo -e "${GREEN}✓${NC} agent.yaml exists"
    echo ""
    echo "Logs section of agent.yaml:"
    echo "-----------------------------------"
    # Extract just the logs section
    awk '/^logs:/{flag=1} flag{print} /^[a-z_]+:/{if(flag && !/^logs:/)exit}' "$AGENT_CONFIG" | head -50
    echo "-----------------------------------"
    
    echo ""
    echo "Remote write URLs in config:"
    grep -E "url:|username:" "$AGENT_CONFIG" | sed 's/password:.*/password: [MASKED]/'
else
    echo -e "${RED}✗${NC} agent.yaml not found"
fi
echo ""

echo -e "${BLUE}4. API KEY VALIDATION${NC}"
echo "────────────────────────────────"

# Get keys from environment
LOGS_API_KEY="${GRAFANA_CLOUD_LOGS_API_KEY:-${GRAFANA_CLOUD_API_KEY:-}}"
METRICS_API_KEY="${GRAFANA_CLOUD_API_KEY:-}"

if [ -n "$LOGS_API_KEY" ]; then
    echo "Logs API Key: ${LOGS_API_KEY:0:20}...${LOGS_API_KEY: -4}"
    
    # Decode the key to check structure (if it's base64)
    if [[ "$LOGS_API_KEY" =~ ^glc_ ]]; then
        echo "Key format: Grafana Cloud token (glc_)"
        # Try to decode the base64 part
        KEY_PAYLOAD="${LOGS_API_KEY:4}"
        if echo "$KEY_PAYLOAD" | base64 -d 2>/dev/null | jq . 2>/dev/null > /dev/null; then
            echo "Key structure: Valid base64 JSON"
            DECODED=$(echo "$KEY_PAYLOAD" | base64 -d 2>/dev/null | jq -r '.m.r // .r // "unknown"' 2>/dev/null)
            echo "Region in key: $DECODED"
        else
            echo "Key structure: Cannot decode (may be encrypted)"
        fi
    elif [[ "$LOGS_API_KEY" =~ ^eyJ ]]; then
        echo "Key format: Basic auth token"
    else
        echo "Key format: Unknown"
    fi
else
    echo -e "${RED}✗${NC} No logs API key found"
fi
echo ""

echo -e "${BLUE}5. ENDPOINT DETECTION${NC}"
echo "────────────────────────────────"

# Detect endpoints
PROMETHEUS_URL="${GRAFANA_CLOUD_PROMETHEUS_URL:-}"
echo "Prometheus URL: $PROMETHEUS_URL"

if [[ "$PROMETHEUS_URL" == *"prod-36"* ]] || [[ "$PROMETHEUS_URL" == *"prod-us-west-0"* ]]; then
    LOKI_URL="https://logs-prod-021.grafana.net/loki/api/v1/push"
    REGION="US West (prod-36)"
elif [[ "$PROMETHEUS_URL" == *"prod-10"* ]] || [[ "$PROMETHEUS_URL" == *"prod-us-central"* ]]; then
    LOKI_URL="https://logs-prod-006.grafana.net/loki/api/v1/push"
    REGION="US Central (prod-10)"
elif [[ "$PROMETHEUS_URL" == *"prod-13"* ]] || [[ "$PROMETHEUS_URL" == *"prod-eu"* ]]; then
    LOKI_URL="https://logs-prod-eu-west-0.grafana.net/loki/api/v1/push"
    REGION="EU (prod-13)"
else
    LOKI_URL="https://logs-prod-021.grafana.net/loki/api/v1/push"
    REGION="Default (US West)"
fi

echo "Detected Region: $REGION"
echo "Loki URL: $LOKI_URL"

# Check what's actually in the agent config
echo ""
echo "URLs in agent.yaml:"
grep -A1 "clients:" "$AGENT_CONFIG" 2>/dev/null | grep "url:" | awk '{print $3}'
echo ""

echo -e "${BLUE}6. AUTHENTICATION TESTS${NC}"
echo "────────────────────────────────"

USER_ID="${GRAFANA_CLOUD_USER:-}"
echo "User ID: $USER_ID"
echo ""

# Test 1: Metrics auth
if [ -n "$METRICS_API_KEY" ] && [ -n "$USER_ID" ]; then
    echo "Testing METRICS authentication..."
    METRICS_TEST=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "${USER_ID}:${METRICS_API_KEY}" \
        "${PROMETHEUS_URL/\/api\/prom\/push/}/api/v1/query?query=up" 2>/dev/null || echo "000")
    
    if [ "$METRICS_TEST" = "200" ]; then
        echo -e "${GREEN}✓${NC} Metrics auth SUCCESS (200)"
    else
        echo -e "${RED}✗${NC} Metrics auth FAILED ($METRICS_TEST)"
    fi
else
    echo "⚠ Skipping metrics test (missing credentials)"
fi
echo ""

# Test 2: Logs auth with direct push
if [ -n "$LOGS_API_KEY" ] && [ -n "$USER_ID" ]; then
    echo "Testing LOGS authentication with direct push..."
    
    # Create test payload
    TIMESTAMP=$(date +%s%N)
    PAYLOAD=$(cat <<EOF
{
  "streams": [
    {
      "stream": {
        "job": "test",
        "host": "$(hostname)"
      },
      "values": [
        ["${TIMESTAMP}", "Test log from troubleshooting script"]
      ]
    }
  ]
}
EOF
)
    
    echo "Sending test log to: $LOKI_URL"
    echo "Using User: $USER_ID"
    echo "Using Key: ${LOGS_API_KEY:0:20}...${LOGS_API_KEY: -4}"
    echo ""
    
    # Try with basic auth
    echo "Test 1: Basic auth format (user:key)"
    RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -u "${USER_ID}:${LOGS_API_KEY}" \
        -d "$PAYLOAD" \
        "$LOKI_URL" 2>&1)
    
    HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
    BODY=$(echo "$RESPONSE" | grep -v "HTTP_CODE:")
    
    if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
        echo -e "${GREEN}✓${NC} Logs push SUCCESS ($HTTP_CODE)"
    else
        echo -e "${RED}✗${NC} Logs push FAILED ($HTTP_CODE)"
        echo "Response body: $BODY"
    fi
    echo ""
    
    # Try with Bearer token
    echo "Test 2: Bearer token format"
    RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${USER_ID}:${LOGS_API_KEY}" \
        -d "$PAYLOAD" \
        "$LOKI_URL" 2>&1)
    
    HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
    BODY=$(echo "$RESPONSE" | grep -v "HTTP_CODE:")
    
    if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
        echo -e "${GREEN}✓${NC} Bearer auth SUCCESS ($HTTP_CODE)"
    else
        echo -e "${RED}✗${NC} Bearer auth FAILED ($HTTP_CODE)"
        if [ "$HTTP_CODE" != "401" ]; then
            echo "Response: $BODY"
        fi
    fi
    echo ""
    
    # Try without user ID (just key)
    echo "Test 3: API key only (no user ID)"
    RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${LOGS_API_KEY}" \
        -d "$PAYLOAD" \
        "$LOKI_URL" 2>&1)
    
    HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
    
    if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
        echo -e "${GREEN}✓${NC} Key-only auth SUCCESS ($HTTP_CODE)"
    else
        echo -e "${RED}✗${NC} Key-only auth FAILED ($HTTP_CODE)"
    fi
else
    echo "⚠ Skipping logs test (missing credentials)"
fi
echo ""

echo -e "${BLUE}7. ALTERNATIVE LOKI ENDPOINTS${NC}"
echo "────────────────────────────────"

# Try different Loki endpoints
LOKI_ENDPOINTS=(
    "https://logs-prod-021.grafana.net/loki/api/v1/push"
    "https://logs-prod-006.grafana.net/loki/api/v1/push"
    "https://logs-prod-012.grafana.net/loki/api/v1/push"
    "https://logs-prod3.grafana.net/loki/api/v1/push"
)

echo "Testing alternative Loki endpoints..."
for endpoint in "${LOKI_ENDPOINTS[@]}"; do
    echo -n "Testing $endpoint ... "
    TEST=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -u "${USER_ID}:${LOGS_API_KEY}" \
        -d '{"streams":[{"stream":{"job":"test"},"values":[["'$(date +%s%N)'","test"]]}]}' \
        "$endpoint" 2>/dev/null || echo "000")
    
    if [ "$TEST" = "204" ] || [ "$TEST" = "200" ]; then
        echo -e "${GREEN}SUCCESS ($TEST)${NC}"
        echo "  ^^^ THIS ENDPOINT WORKS! ^^^"
    elif [ "$TEST" = "401" ]; then
        echo -e "${YELLOW}AUTH FAILED ($TEST)${NC}"
    else
        echo "ERROR ($TEST)"
    fi
done
echo ""

echo -e "${BLUE}8. AGENT SERVICE STATUS${NC}"
echo "────────────────────────────────"

systemctl status grafana-agent --no-pager | head -20
echo ""

echo -e "${BLUE}9. RECENT AGENT LOGS${NC}"
echo "────────────────────────────────"

echo "Last 10 error messages:"
sudo journalctl -u grafana-agent --since "10 minutes ago" --no-pager | grep -E "level=error|401|authentication" | tail -10
echo ""

echo -e "${BLUE}10. AGENT PROCESS INFO${NC}"
echo "────────────────────────────────"

AGENT_PID=$(pgrep grafana-agent | head -1)
if [ -n "$AGENT_PID" ]; then
    echo "Agent PID: $AGENT_PID"
    echo "Command line:"
    ps -p $AGENT_PID -o args= | head -1
    echo ""
    echo "Open files (logs):"
    sudo lsof -p $AGENT_PID 2>/dev/null | grep -E "\.log|\.txt" | awk '{print $9}'
else
    echo "Agent not running"
fi
echo ""

echo -e "${BLUE}11. DNS RESOLUTION${NC}"
echo "────────────────────────────────"

# Check DNS resolution
for host in "logs-prod-021.grafana.net" "prometheus-prod-36-prod-us-west-0.grafana.net"; do
    echo -n "$host: "
    if host "$host" > /dev/null 2>&1; then
        IP=$(dig +short "$host" | head -1)
        echo "$IP"
    else
        echo "FAILED"
    fi
done
echo ""

echo -e "${BLUE}12. CONNECTIVITY TEST${NC}"
echo "────────────────────────────────"

# Test connectivity to Grafana Cloud
echo "Testing connectivity to Grafana Cloud..."
for host in "grafana.net" "grafana.com"; do
    echo -n "$host: "
    if ping -c 1 -W 2 "$host" > /dev/null 2>&1; then
        echo "OK"
    else
        echo "FAILED"
    fi
done
echo ""

echo -e "${BLUE}13. POSITIONS FILE${NC}"
echo "────────────────────────────────"

POSITIONS_FILE="/var/lib/grafana-agent/positions.yaml"
if [ -f "$POSITIONS_FILE" ]; then
    echo "Positions file exists"
    echo "Last modified: $(stat -c %y "$POSITIONS_FILE")"
    echo "Content:"
    cat "$POSITIONS_FILE" | head -20
else
    echo "Positions file not found"
fi
echo ""

echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  TROUBLESHOOTING SUMMARY${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Summary
echo "Key Findings:"
echo "-------------"

# Check if any auth worked
if grep -q "SUCCESS" "$OUTPUT_FILE"; then
    echo -e "${GREEN}✓${NC} At least one authentication method worked"
    echo "  Check which endpoint/method succeeded above"
else
    echo -e "${RED}✗${NC} All authentication attempts failed"
fi

# Check for config issues
if [ -f "$CONFIG_FILE" ] && [ -f "$AGENT_CONFIG" ]; then
    echo -e "${GREEN}✓${NC} Configuration files present"
else
    echo -e "${RED}✗${NC} Missing configuration files"
fi

# Check agent status
if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Agent is running"
else
    echo -e "${RED}✗${NC} Agent is not running"
fi

echo ""
echo "Output saved to: $OUTPUT_FILE"
echo ""
echo "Please share the contents of $OUTPUT_FILE for further assistance."
echo "You can view it with: cat $OUTPUT_FILE"
echo ""
echo "To send to support:"
echo "cat $OUTPUT_FILE | nc termbin.com 9999"
echo "This will give you a URL to share."