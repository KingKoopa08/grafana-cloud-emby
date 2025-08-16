#!/bin/bash

# Fix YAML error in agent config and restore working configuration
# Fixes the journal matches syntax issue

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
echo -e "${CYAN}  FIX NFL YAML ERROR${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Load config
CONFIG_FILE="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/config/config.env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo -e "${GREEN}✓${NC} Configuration loaded"
else
    echo -e "${RED}✗${NC} Configuration file not found"
    exit 1
fi

# Set default Loki URL if not provided
GRAFANA_CLOUD_LOKI_URL=${GRAFANA_CLOUD_LOKI_URL:-"https://logs-prod-021.grafana.net/loki/api/v1/push"}

echo ""
echo -e "${BLUE}1. STOPPING AGENT${NC}"
echo "────────────────────────────────"

sudo systemctl stop grafana-agent 2>/dev/null || true
echo -e "${GREEN}✓${NC} Agent stopped"

echo ""
echo -e "${BLUE}2. CREATING FIXED CONFIG${NC}"
echo "────────────────────────────────"

# Create working config without journal section (causing the error)
cat > /tmp/agent-fixed.yaml <<EOF
server:
  log_level: info

metrics:
  global:
    scrape_interval: 60s
    remote_write:
      - url: https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/push
        basic_auth:
          username: ${GRAFANA_CLOUD_USER}
          password: ${GRAFANA_CLOUD_API_KEY}

  configs:
    - name: default
      scrape_configs:
        # Emby Live TV exporter
        - job_name: emby
          static_configs:
            - targets: ['localhost:9119']
          scrape_interval: 30s
          metrics_path: /metrics
          
        # Node exporter
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
        - url: ${GRAFANA_CLOUD_LOKI_URL}
          basic_auth:
            username: ${GRAFANA_CLOUD_USER}
            password: ${GRAFANA_CLOUD_API_KEY}
            
      positions:
        filename: /var/lib/grafana-agent/positions.yaml
        
      scrape_configs:
        # NFL Updater Log
        - job_name: nfl-updater
          static_configs:
            - targets:
                - localhost
              labels:
                job: nfl-updater
                service: nfl
                __path__: /var/log/nfl_updater.log
                
          pipeline_stages:
            # Parse log lines
            - regex:
                expression: '^(?P<timestamp>\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}[,\\.]\\d{3})?\\s*-?\\s*(?P<level>INFO|ERROR|WARNING|DEBUG)?\\s*-?\\s*(?P<content>.*)'
                
            # Extract game info
            - regex:
                expression: 'Game (?P<teams>[^:]+):\\s+(?P<score>[\\d-]+)\\s+\\((?P<status>[^)]+)\\)'
                source: content
                
            # Set labels
            - labels:
                level:
                status:
                
            # Output
            - output:
                source: content
EOF

echo -e "${GREEN}✓${NC} Fixed configuration created"

echo ""
echo -e "${BLUE}3. APPLYING CONFIG${NC}"
echo "────────────────────────────────"

sudo cp /tmp/agent-fixed.yaml /etc/grafana-agent/agent.yaml
echo -e "${GREEN}✓${NC} Configuration applied"

echo ""
echo -e "${BLUE}4. STARTING AGENT${NC}"
echo "────────────────────────────────"

sudo systemctl start grafana-agent
sleep 3

if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Grafana Agent started successfully!"
else
    echo -e "${RED}✗${NC} Failed to start agent"
    echo "Error logs:"
    sudo journalctl -u grafana-agent -n 10 --no-pager
    exit 1
fi

echo ""
echo -e "${BLUE}5. VERIFYING OPERATION${NC}"
echo "────────────────────────────────"

# Check metrics
if curl -s http://localhost:12345/metrics 2>/dev/null | grep -q 'up{.*job="emby"'; then
    echo -e "${GREEN}✓${NC} Emby metrics are being scraped"
else
    echo -e "${YELLOW}⚠${NC} Emby metrics not confirmed yet"
fi

# Check if logs are being tailed
if [ -f /var/log/nfl_updater.log ]; then
    echo -e "${GREEN}✓${NC} NFL log file exists"
    echo "  Last update: $(stat -c %y /var/log/nfl_updater.log | cut -d. -f1)"
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  AGENT FIXED AND RUNNING${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${GREEN}Success!${NC} The agent is now running with:"
echo "• Emby metrics collection (port 9119)"
echo "• NFL log collection from /var/log/nfl_updater.log"
echo ""
echo "Test queries in Grafana Explore:"
echo ""
echo -e "${CYAN}NFL logs:${NC}"
echo '{job="nfl-updater"}'
echo '{service="nfl"}'
echo ""
echo -e "${CYAN}Games:${NC}"
echo '{job="nfl-updater"} |~ "Game"'
echo ""
echo -e "${CYAN}Errors:${NC}"
echo '{job="nfl-updater", level="ERROR"}'
echo ""
echo -e "${CYAN}Commands:${NC}"
echo "• Status: sudo systemctl status grafana-agent"
echo "• Logs: sudo journalctl -u grafana-agent -f"
echo "• Config: cat /etc/grafana-agent/agent.yaml"