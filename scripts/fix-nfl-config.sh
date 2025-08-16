#!/bin/bash

# Fix NFL monitoring configuration and restore working agent
# This script fixes compatibility issues with the NFL config

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
echo -e "${CYAN}  FIX NFL MONITORING CONFIG${NC}"
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

echo ""
echo -e "${BLUE}1. RESTORING WORKING CONFIG${NC}"
echo "────────────────────────────────"

# Find a working backup (before NFL config)
WORKING_BACKUP=$(ls -t /etc/grafana-agent/agent.yaml.backup.* 2>/dev/null | grep -v "nfl" | head -2 | tail -1 || echo "")

if [ -n "$WORKING_BACKUP" ]; then
    echo "Found working backup: $WORKING_BACKUP"
    sudo cp "$WORKING_BACKUP" /etc/grafana-agent/agent.yaml
    echo -e "${GREEN}✓${NC} Restored working configuration"
else
    echo -e "${YELLOW}⚠${NC} No backup found, creating minimal config"
    
    # Create minimal working config
    cat > /tmp/agent-working.yaml <<EOF
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
EOF
    
    sudo cp /tmp/agent-working.yaml /etc/grafana-agent/agent.yaml
    echo -e "${GREEN}✓${NC} Created minimal working config"
fi

echo ""
echo -e "${BLUE}2. STARTING GRAFANA AGENT${NC}"
echo "────────────────────────────────"

sudo systemctl restart grafana-agent
sleep 3

if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Grafana Agent is running!"
else
    echo -e "${RED}✗${NC} Failed to start agent"
    sudo journalctl -u grafana-agent -n 10 --no-pager
    exit 1
fi

echo ""
echo -e "${BLUE}3. CREATING NFL LOG CONFIG${NC}"
echo "────────────────────────────────"

# Create a separate NFL log config file for manual integration
cat > /tmp/nfl-logs-config.yaml <<'EOF'
# NFL Log Collection Config
# Add this to your working agent.yaml under the logs section

logs:
  configs:
    - name: default
      clients:
        - url: ${GRAFANA_CLOUD_LOKI_URL}
          basic_auth:
            username: ${GRAFANA_CLOUD_USER}
            password: ${GRAFANA_CLOUD_API_KEY}
          external_labels:
            environment: 'prod'
            hostname: 'ns1017440'
            
      positions:
        filename: /var/lib/grafana-agent/positions.yaml
        
      scrape_configs:
        # NFL Updater Application Logs
        - job_name: nfl-updater
          static_configs:
            - targets:
                - localhost
              labels:
                job: nfl-updater
                service: nfl-updater
                log_type: application
                __path__: /home/emby/py/nfl-updater/nfl_updater.log*
                
          pipeline_stages:
            # Parse Python log format
            - regex:
                expression: '^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3}) - (?P<logger>\S+) - (?P<level>\w+) - (?P<message>.*)'
            
            # Set timestamp
            - timestamp:
                source: timestamp
                format: '2006-01-02 15:04:05,000'
                location: UTC
            
            # Set severity label
            - labels:
                level:
                logger:
            
            # Extract game updates
            - regex:
                expression: 'Updated: (?P<away_team>[\w\s]+) \((?P<away_score>\d+)\) at (?P<home_team>[\w\s]+) \((?P<home_score>\d+)\)'
            - labels:
                away_team:
                home_team:
                
            # Extract game state
            - regex:
                expression: 'Game.*:\s+\d+-\d+\s+\((?P<game_state>LIVE|HALFTIME|FINAL|SCHEDULED)\)'
            - labels:
                game_state:
            
            # Output final log line
            - output:
                source: message
EOF

echo -e "${GREEN}✓${NC} NFL log config template created at: /tmp/nfl-logs-config.yaml"

echo ""
echo -e "${BLUE}4. NFL MONITORING STATUS${NC}"
echo "────────────────────────────────"

echo -e "${YELLOW}Note:${NC} The NFL updater service is not installed yet."
echo ""
echo "To set up NFL monitoring:"
echo ""
echo "1. Install the NFL updater service first"
echo "2. Ensure log file exists at: /home/emby/py/nfl-updater/nfl_updater.log"
echo "3. Manually add the logs section from /tmp/nfl-logs-config.yaml to your agent config"
echo "4. Or wait for a compatible agent version that supports all features"
echo ""

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  AGENT RESTORED${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${GREEN}Status:${NC}"
echo "• Grafana Agent is running with Emby monitoring"
echo "• NFL log config template saved for future use"
echo "• Dashboard and alerts can still be imported"
echo ""

echo -e "${CYAN}Commands:${NC}"
echo "• Check agent: sudo systemctl status grafana-agent"
echo "• View logs: sudo journalctl -u grafana-agent -f"
echo "• Test metrics: curl http://localhost:12345/metrics | grep up"