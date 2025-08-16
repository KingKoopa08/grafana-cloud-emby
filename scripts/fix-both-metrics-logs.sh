#!/bin/bash

# Fix Grafana Agent to have both metrics AND logs working
# This ensures Emby metrics continue while also collecting NFL logs

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
echo -e "${CYAN}  FIX METRICS AND LOGS${NC}"
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
echo -e "${BLUE}1. CHECKING CURRENT STATUS${NC}"
echo "────────────────────────────────"

# Check if metrics are working
if curl -s http://localhost:12345/metrics 2>/dev/null | grep -q "up"; then
    echo -e "${GREEN}✓${NC} Metrics endpoint is accessible"
else
    echo -e "${YELLOW}⚠${NC} Metrics endpoint not responding"
fi

# Check if Emby exporter is running
if curl -s http://localhost:9119/metrics 2>/dev/null | grep -q "emby_livetv"; then
    echo -e "${GREEN}✓${NC} Emby exporter is running"
else
    echo -e "${YELLOW}⚠${NC} Emby exporter not responding"
fi

# Check for NFL logs
if [ -f /var/log/nfl_updater.log ]; then
    echo -e "${GREEN}✓${NC} NFL logs found at /var/log/nfl_updater.log"
elif [ -f /var/log/nfl-updater/nfl_updater.log ]; then
    echo -e "${GREEN}✓${NC} NFL logs found at /var/log/nfl-updater/nfl_updater.log"
else
    echo -e "${YELLOW}⚠${NC} NFL logs not found yet"
fi

echo ""
echo -e "${BLUE}2. BACKING UP CURRENT CONFIG${NC}"
echo "────────────────────────────────"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
sudo cp /etc/grafana-agent/agent.yaml "/etc/grafana-agent/agent.yaml.backup.$TIMESTAMP"
echo -e "${GREEN}✓${NC} Config backed up"

echo ""
echo -e "${BLUE}3. CREATING COMPLETE CONFIG${NC}"
echo "────────────────────────────────"

# Determine NFL log path
NFL_LOG_PATH="/var/log/nfl_updater.log*"
if [ -d /var/log/nfl-updater ]; then
    NFL_LOG_PATH="/var/log/nfl-updater/*.log"
fi

# Create complete config with both metrics and logs
cat > /tmp/agent-complete.yaml <<EOF
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
        # Emby Live TV exporter - CRITICAL FOR DASHBOARDS
        - job_name: emby
          static_configs:
            - targets: ['localhost:9119']
          scrape_interval: 30s
          metrics_path: /metrics
          
        # Node exporter for system metrics
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
          external_labels:
            environment: 'prod'
            hostname: 'ns1017440'
            
      positions:
        filename: /var/lib/grafana-agent/positions.yaml
        
      scrape_configs:
        # NFL Updater Logs
        - job_name: nfl_updater_log
          static_configs:
            - targets:
                - localhost
              labels:
                job: nfl_updater_log
                service: nfl-updater
                filename: "/var/log/nfl_updater.log"
                __path__: ${NFL_LOG_PATH}
                
          pipeline_stages:
            # Parse Python log format if present
            - regex:
                expression: '^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3}) - (?P<logger>\S+) - (?P<level>\w+) - (?P<message>.*)'
                
            # Try to set timestamp if regex matched
            - timestamp:
                source: timestamp
                format: '2006-01-02 15:04:05,000'
                location: UTC
                action_on_failure: skip
                
            # Set labels if they exist
            - labels:
                level:
                logger:
            
            # Extract game info
            - regex:
                expression: 'Game (?P<teams>[\w\s@]+):\s+(?P<score>[\d-]+)\s+\((?P<game_state>\w+)'
            - labels:
                game_state:
                
            # Extract specific game updates
            - regex:
                expression: 'Updated: (?P<away_team>[\w\s]+) \((?P<away_score>\d+)\) at (?P<home_team>[\w\s]+) \((?P<home_score>\d+)\)'
                
            # Output
            - output:
                source: message
EOF

echo -e "${GREEN}✓${NC} Complete configuration created"

echo ""
echo -e "${BLUE}4. APPLYING CONFIG${NC}"
echo "────────────────────────────────"

sudo cp /tmp/agent-complete.yaml /etc/grafana-agent/agent.yaml
echo -e "${GREEN}✓${NC} Configuration applied"

echo ""
echo -e "${BLUE}5. FIXING PERMISSIONS${NC}"
echo "────────────────────────────────"

# Ensure log file is readable
if [ -f /var/log/nfl_updater.log ]; then
    sudo chmod 644 /var/log/nfl_updater.log* 2>/dev/null || true
    echo -e "${GREEN}✓${NC} NFL log permissions fixed"
fi

if [ -d /var/log/nfl-updater ]; then
    sudo chmod 755 /var/log/nfl-updater
    sudo chmod 644 /var/log/nfl-updater/*.log 2>/dev/null || true
    echo -e "${GREEN}✓${NC} NFL log directory permissions fixed"
fi

# Ensure positions directory exists
sudo mkdir -p /var/lib/grafana-agent
sudo chown grafana-agent:grafana-agent /var/lib/grafana-agent
echo -e "${GREEN}✓${NC} Positions directory ready"

echo ""
echo -e "${BLUE}6. RESTARTING AGENT${NC}"
echo "────────────────────────────────"

sudo systemctl restart grafana-agent
sleep 5

if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Grafana Agent restarted successfully"
else
    echo -e "${RED}✗${NC} Failed to restart agent"
    echo "Recent logs:"
    sudo journalctl -u grafana-agent -n 20 --no-pager
    
    echo ""
    echo "Reverting to backup..."
    sudo cp "/etc/grafana-agent/agent.yaml.backup.$TIMESTAMP" /etc/grafana-agent/agent.yaml
    sudo systemctl restart grafana-agent
    echo -e "${YELLOW}⚠${NC} Reverted to previous config"
    exit 1
fi

echo ""
echo -e "${BLUE}7. VERIFYING EVERYTHING WORKS${NC}"
echo "────────────────────────────────"

sleep 5

# Check metrics
echo "Checking metrics collection..."
if curl -s http://localhost:12345/metrics 2>/dev/null | grep -q 'up{.*job="emby".*} 1'; then
    echo -e "${GREEN}✓${NC} Emby metrics are being scraped"
else
    echo -e "${YELLOW}⚠${NC} Emby metrics not confirmed yet"
fi

# Check logs
echo ""
echo "Checking log collection..."
if sudo journalctl -u grafana-agent --since "30 seconds ago" --no-pager | grep -q "nfl_updater_log"; then
    echo -e "${GREEN}✓${NC} NFL logs are being collected"
else
    echo -e "${YELLOW}⚠${NC} NFL log collection not confirmed yet"
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  BOTH METRICS AND LOGS CONFIGURED${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${GREEN}Success!${NC} Your agent is now collecting:"
echo "• Emby Live TV metrics (port 9119)"
echo "• System metrics (port 9100)"
echo "• NFL updater logs from $NFL_LOG_PATH"
echo ""
echo "Verify in Grafana:"
echo ""
echo -e "${CYAN}Metrics (Prometheus):${NC}"
echo "• emby_livetv_streams_active"
echo "• emby_livetv_channels_total"
echo ""
echo -e "${CYAN}Logs (Loki):${NC}"
echo '• {filename="/var/log/nfl_updater.log"}'
echo '• {job="nfl_updater_log"}'
echo ""
echo -e "${YELLOW}Dashboards:${NC}"
echo "• Emby Live TV Ultimate - Should show metrics"
echo "• NFL Updater Monitoring - Should show logs"
echo ""
echo -e "${CYAN}Commands:${NC}"
echo "• Check status: sudo systemctl status grafana-agent"
echo "• View logs: sudo journalctl -u grafana-agent -f"
echo "• Test metrics: curl http://localhost:12345/metrics | grep emby"
echo "• View config: cat /etc/grafana-agent/agent.yaml"