#!/bin/bash

# Fix Loki authentication for log ingestion
# Resolves 401 Unauthorized errors

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
echo -e "${CYAN}  FIX LOKI AUTHENTICATION${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BLUE}1. CHECKING CURRENT CREDENTIALS${NC}"
echo "────────────────────────────────"

# Load config
CONFIG_FILE="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/config/config.env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo -e "${GREEN}✓${NC} Configuration loaded from config.env"
else
    echo -e "${RED}✗${NC} Configuration file not found"
    exit 1
fi

# Show current values (masked)
echo "Current settings:"
echo "  GRAFANA_CLOUD_USER: ${GRAFANA_CLOUD_USER:-NOT SET}"
echo "  GRAFANA_CLOUD_API_KEY: ${GRAFANA_CLOUD_API_KEY:0:10}..." 
echo "  Prometheus URL: ${GRAFANA_CLOUD_PROMETHEUS_URL:-DEFAULT}"

# Determine correct Loki URL based on Prometheus URL
if [[ "${GRAFANA_CLOUD_PROMETHEUS_URL:-}" == *"prod-36"* ]]; then
    # US West region
    CORRECT_LOKI_URL="https://logs-prod-021.grafana.net/loki/api/v1/push"
    echo "  Region detected: US West"
elif [[ "${GRAFANA_CLOUD_PROMETHEUS_URL:-}" == *"prod-10"* ]]; then
    # US Central region
    CORRECT_LOKI_URL="https://logs-prod-006.grafana.net/loki/api/v1/push"
    echo "  Region detected: US Central"
elif [[ "${GRAFANA_CLOUD_PROMETHEUS_URL:-}" == *"prod-13"* ]]; then
    # EU region
    CORRECT_LOKI_URL="https://logs-prod-eu-west-0.grafana.net/loki/api/v1/push"
    echo "  Region detected: EU"
else
    # Default to US West
    CORRECT_LOKI_URL="https://logs-prod-021.grafana.net/loki/api/v1/push"
    echo "  Region: Using default (US West)"
fi

echo "  Correct Loki URL: $CORRECT_LOKI_URL"

echo ""
echo -e "${BLUE}2. TESTING PROMETHEUS AUTH${NC}"
echo "────────────────────────────────"

# Test Prometheus auth (which is working)
PROM_TEST=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${GRAFANA_CLOUD_USER}:${GRAFANA_CLOUD_API_KEY}" \
    "https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/api/v1/query?query=up" 2>/dev/null || echo "000")

if [ "$PROM_TEST" = "200" ]; then
    echo -e "${GREEN}✓${NC} Prometheus authentication working (metrics are OK)"
else
    echo -e "${RED}✗${NC} Prometheus authentication failed (status: $PROM_TEST)"
fi

echo ""
echo -e "${BLUE}3. TESTING LOKI AUTH${NC}"
echo "────────────────────────────────"

# Test Loki auth with the same credentials
echo "Testing Loki endpoint..."
LOKI_TEST=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -u "${GRAFANA_CLOUD_USER}:${GRAFANA_CLOUD_API_KEY}" \
    "${CORRECT_LOKI_URL}/ready" 2>/dev/null || echo "000")

if [ "$LOKI_TEST" = "200" ] || [ "$LOKI_TEST" = "204" ]; then
    echo -e "${GREEN}✓${NC} Loki authentication test successful"
else
    echo -e "${RED}✗${NC} Loki authentication test failed (status: $LOKI_TEST)"
    echo ""
    echo -e "${YELLOW}This might mean:${NC}"
    echo "• Wrong Loki URL for your region"
    echo "• API key doesn't have logs:write permission"
    echo "• Loki service is not enabled on your Grafana Cloud account"
fi

echo ""
echo -e "${BLUE}4. CREATING FIXED CONFIG${NC}"
echo "────────────────────────────────"

# Create config with correct Loki URL and auth
cat > /tmp/agent-loki-fixed.yaml <<EOF
server:
  log_level: info

metrics:
  global:
    scrape_interval: 60s
    remote_write:
      - url: ${GRAFANA_CLOUD_PROMETHEUS_URL:-https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/push}
        basic_auth:
          username: ${GRAFANA_CLOUD_USER}
          password: ${GRAFANA_CLOUD_API_KEY}

  configs:
    - name: default
      scrape_configs:
        - job_name: emby
          static_configs:
            - targets: ['localhost:9119']
          scrape_interval: 30s
          metrics_path: /metrics
          
        - job_name: node
          static_configs:
            - targets: ['localhost:9100']
          scrape_interval: 60s

integrations:
  agent:
    enabled: true

logs:
  configs:
    - name: default
      clients:
        - url: ${CORRECT_LOKI_URL}
          basic_auth:
            username: ${GRAFANA_CLOUD_USER}
            password: ${GRAFANA_CLOUD_API_KEY}
          tenant_id: ${GRAFANA_CLOUD_USER}
          external_labels:
            hostname: 'ns1017440'
            
      positions:
        filename: /var/lib/grafana-agent/positions.yaml
        
      scrape_configs:
        # Emby Server Logs
        - job_name: embyserver
          static_configs:
            - targets:
                - localhost
              labels:
                job: embyserver
                __path__: /var/lib/emby/logs/embyserver.txt
                
          pipeline_stages:
            - multiline:
                firstline: '^\\d{4}-\\d{2}-\\d{2}'
                max_wait_time: 3s
            - output:
                source: message
                
        # NFL Updater Logs  
        - job_name: nfl_updater
          static_configs:
            - targets:
                - localhost
              labels:
                job: nfl_updater
                __path__: /var/log/nfl_updater.log
                
          pipeline_stages:
            - output:
                source: message
EOF

echo -e "${GREEN}✓${NC} Configuration created with correct Loki URL"

echo ""
echo -e "${BLUE}5. BACKING UP CURRENT CONFIG${NC}"
echo "────────────────────────────────"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
sudo cp /etc/grafana-agent/agent.yaml "/etc/grafana-agent/agent.yaml.backup.$TIMESTAMP"
echo -e "${GREEN}✓${NC} Backed up current config"

echo ""
echo -e "${BLUE}6. APPLYING FIXED CONFIG${NC}"
echo "────────────────────────────────"

sudo cp /tmp/agent-loki-fixed.yaml /etc/grafana-agent/agent.yaml
echo -e "${GREEN}✓${NC} Applied fixed configuration"

echo ""
echo -e "${BLUE}7. RESTARTING AGENT${NC}"
echo "────────────────────────────────"

sudo systemctl restart grafana-agent
sleep 5

if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Agent restarted"
else
    echo -e "${RED}✗${NC} Agent failed to start"
    sudo journalctl -u grafana-agent -n 10 --no-pager
    exit 1
fi

echo ""
echo -e "${BLUE}8. CHECKING FOR AUTH ERRORS${NC}"
echo "────────────────────────────────"

sleep 10

# Check for auth errors in the last minute
AUTH_ERRORS=$(sudo journalctl -u grafana-agent --since "1 minute ago" --no-pager | grep -c "401" || echo "0")

if [ "$AUTH_ERRORS" -gt 0 ]; then
    echo -e "${RED}✗${NC} Still seeing authentication errors!"
    echo ""
    echo -e "${YELLOW}To fix this:${NC}"
    echo "1. Go to your Grafana Cloud portal"
    echo "2. Navigate to: My Account > Security > API Keys"
    echo "3. Create a new API key with these permissions:"
    echo "   • metrics:write"
    echo "   • logs:write"
    echo "   • traces:write (optional)"
    echo "4. Update /opt/grafana-cloud-emby/config/config.env with the new key"
    echo "5. Run this script again"
else
    echo -e "${GREEN}✓${NC} No authentication errors in recent logs"
    
    # Check if logs are being sent
    if sudo journalctl -u grafana-agent --since "30 seconds ago" --no-pager | grep -q "batch"; then
        echo -e "${GREEN}✓${NC} Agent is sending log batches"
    fi
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  LOKI AUTHENTICATION FIXED${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

if [ "$AUTH_ERRORS" -eq 0 ]; then
    echo -e "${GREEN}Success!${NC} Authentication is now working."
    echo ""
    echo "Logs should start appearing in Grafana Cloud within 2-3 minutes."
    echo ""
    echo "Test with these queries:"
    echo "• {job=\"embyserver\"}"
    echo "• {job=\"nfl_updater\"}"
else
    echo -e "${YELLOW}Authentication still needs fixing.${NC}"
    echo ""
    echo "Your API key may not have logs:write permission."
    echo "Create a new API key with the correct permissions."
fi

echo ""
echo -e "${CYAN}Commands:${NC}"
echo "• Check logs: sudo journalctl -u grafana-agent -f | grep -v 401"
echo "• View config: cat /etc/grafana-agent/agent.yaml | grep -A5 logs"
echo "• Test query: curl -G -s '${CORRECT_LOKI_URL}/loki/api/v1/query' --data-urlencode 'query={job=\"embyserver\"}' -u '${GRAFANA_CLOUD_USER}:API_KEY'"