#!/bin/bash

# Setup NFL log collection with correct path and labels
# Matches the actual log location shown in the screenshot

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
echo -e "${CYAN}  SETUP NFL LOG COLLECTION (CORRECT PATH)${NC}"
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
echo -e "${BLUE}1. FINDING NFL LOGS${NC}"
echo "────────────────────────────────"

# Check exact log location (from screenshot it's /var/log/nfl_updater.log)
NFL_LOG_PATH=""
if [ -f /var/log/nfl_updater.log ]; then
    NFL_LOG_PATH="/var/log/nfl_updater.log"
    echo -e "${GREEN}✓${NC} Found NFL log at: $NFL_LOG_PATH"
    echo "  Size: $(du -h $NFL_LOG_PATH | cut -f1)"
    echo "  Last modified: $(stat -c %y $NFL_LOG_PATH | cut -d. -f1)"
elif [ -f /var/log/nfl-updater/nfl_updater.log ]; then
    NFL_LOG_PATH="/var/log/nfl-updater/nfl_updater.log"
    echo -e "${GREEN}✓${NC} Found NFL log at: $NFL_LOG_PATH"
else
    echo -e "${RED}✗${NC} NFL log not found!"
    echo "Please ensure NFL updater is installed and has created logs"
    exit 1
fi

echo ""
echo -e "${BLUE}2. BACKING UP CONFIG${NC}"
echo "────────────────────────────────"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
sudo cp /etc/grafana-agent/agent.yaml "/etc/grafana-agent/agent.yaml.backup.$TIMESTAMP"
echo -e "${GREEN}✓${NC} Config backed up"

echo ""
echo -e "${BLUE}3. CREATING WORKING CONFIG${NC}"
echo "────────────────────────────────"

# Create config that matches the working log collection
cat > /tmp/agent-nfl-logs.yaml <<EOF
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
        # NFL Updater Log - Main application log
        - job_name: nfl-updater
          static_configs:
            - targets:
                - localhost
              labels:
                job: nfl-updater
                __path__: ${NFL_LOG_PATH}
                
          pipeline_stages:
            # Extract timestamp if Python format
            - regex:
                expression: '^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}[,\.]\d{3})'
                
            # Extract log level
            - regex:
                expression: '(INFO|ERROR|WARNING|DEBUG|CRITICAL)'
                source: message
            - template:
                source: level
                template: '{{ or .Value "INFO" }}'
            - labels:
                level:
                
            # Extract game info from lines like "Game KC @ SEA: 16-23 (FINAL 4th)"
            - regex:
                expression: 'Game (?P<away>\\w+) @ (?P<home>\\w+): (?P<away_score>\\d+)-(?P<home_score>\\d+) \\((?P<status>\\w+)'
            - labels:
                game_status:
                  
            # Extract sports API info
            - regex:
                expression: 'sports_api.*Game (?P<game_id>\\w+ @ \\w+)'
            
            # Output the log line
            - output:
                source: message
                
        # System journal for NFL service (if exists)
        - job_name: nfl-journal
          journal:
            matches: 
              - _SYSTEMD_UNIT=nfl-updater.service
              - _SYSTEMD_UNIT=nfl_updater.service
            labels:
              job: nfl-journal
          pipeline_stages:
            - output:
                source: message
EOF

echo -e "${GREEN}✓${NC} Configuration created"

echo ""
echo -e "${BLUE}4. SETTING PERMISSIONS${NC}"
echo "────────────────────────────────"

# Make sure log is readable
sudo chmod 644 ${NFL_LOG_PATH}* 2>/dev/null || true
echo -e "${GREEN}✓${NC} Log permissions set"

# Ensure positions directory
sudo mkdir -p /var/lib/grafana-agent
sudo chown grafana-agent:grafana-agent /var/lib/grafana-agent
echo -e "${GREEN}✓${NC} Positions directory ready"

echo ""
echo -e "${BLUE}5. APPLYING CONFIG${NC}"
echo "────────────────────────────────"

sudo cp /tmp/agent-nfl-logs.yaml /etc/grafana-agent/agent.yaml
echo -e "${GREEN}✓${NC} Configuration applied"

echo ""
echo -e "${BLUE}6. RESTARTING AGENT${NC}"
echo "────────────────────────────────"

sudo systemctl restart grafana-agent
sleep 5

if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Grafana Agent restarted"
    
    # Show recent agent logs
    echo ""
    echo "Recent agent activity:"
    sudo journalctl -u grafana-agent --since "10 seconds ago" --no-pager | grep -E "(nfl|tail|log)" | head -5 || true
else
    echo -e "${RED}✗${NC} Agent failed to start"
    sudo journalctl -u grafana-agent -n 20 --no-pager
    
    # Revert
    sudo cp "/etc/grafana-agent/agent.yaml.backup.$TIMESTAMP" /etc/grafana-agent/agent.yaml
    sudo systemctl restart grafana-agent
    exit 1
fi

echo ""
echo -e "${BLUE}7. TESTING QUERIES${NC}"
echo "────────────────────────────────"

echo "Wait 30 seconds for logs to be ingested, then test these queries in Grafana Explore:"
echo ""
echo -e "${CYAN}All NFL logs:${NC}"
echo '{job="nfl-updater"}'
echo ""
echo -e "${CYAN}Game updates:${NC}"
echo '{job="nfl-updater"} |~ "Game .* @ .*:"'
echo ""
echo -e "${CYAN}Errors:${NC}"
echo '{job="nfl-updater"} |= "ERROR"'
echo ""
echo -e "${CYAN}By game status:${NC}"
echo '{job="nfl-updater"} |~ "FINAL|LIVE|SCHEDULED"'
echo ""

# Show sample of recent logs
echo -e "${BLUE}8. RECENT LOG SAMPLE${NC}"
echo "────────────────────────────────"
echo "Last 5 lines from NFL log:"
tail -5 $NFL_LOG_PATH | sed 's/^/  /'

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  LOG COLLECTION CONFIGURED${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${GREEN}Setup complete!${NC}"
echo ""
echo "Log source: $NFL_LOG_PATH"
echo "Job name: nfl-updater"
echo ""
echo "The logs should appear in Grafana Cloud within 1-2 minutes."
echo "You can import the NFL dashboard from:"
echo "  dashboards/nfl-updater-monitoring.json"
echo ""
echo -e "${CYAN}Verify with:${NC}"
echo "• Grafana Explore: {job=\"nfl-updater\"}"
echo "• Agent status: sudo systemctl status grafana-agent"
echo "• Agent logs: sudo journalctl -u grafana-agent -f | grep nfl"