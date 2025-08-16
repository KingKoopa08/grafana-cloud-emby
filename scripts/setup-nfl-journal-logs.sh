#!/bin/bash

# Setup NFL logs collection from systemd journal

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
echo -e "${CYAN}  SETUP NFL LOGS FROM SYSTEMD JOURNAL${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BLUE}1. CHECKING NFL SERVICE${NC}"
echo "────────────────────────────────"

# Check if service exists and is running
if systemctl list-units --all | grep -q "nfl-updater.service"; then
    echo -e "${GREEN}✓${NC} NFL updater service exists"
    
    STATUS=$(systemctl is-active nfl-updater || echo "inactive")
    if [ "$STATUS" = "active" ]; then
        echo -e "${GREEN}✓${NC} Service is active"
    else
        echo -e "${YELLOW}⚠${NC} Service is $STATUS"
    fi
    
    # Show recent logs
    echo ""
    echo "Recent NFL service logs:"
    echo "---"
    journalctl -u nfl-updater --since "10 minutes ago" --no-pager | tail -5 | sed 's/^/  /'
    echo "---"
else
    echo -e "${RED}✗${NC} NFL updater service not found"
fi

echo ""
echo -e "${BLUE}2. OPTION 1: REDIRECT JOURNAL TO FILE${NC}"
echo "────────────────────────────────"

echo "Creating script to export journal logs to file..."

# Create log export script
sudo tee /usr/local/bin/nfl-journal-to-file.sh > /dev/null << 'EOF'
#!/bin/bash
# Export NFL updater journal logs to file for Grafana agent

LOG_FILE="/var/log/nfl_updater.log"

# Ensure log file exists and has correct permissions
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

# Follow journal and append to file
exec journalctl -u nfl-updater -f --no-hostname -o short-iso | while IFS= read -r line; do
    echo "$line" >> "$LOG_FILE"
done
EOF

sudo chmod +x /usr/local/bin/nfl-journal-to-file.sh
echo -e "${GREEN}✓${NC} Created journal export script"

# Create systemd service for the exporter
sudo tee /etc/systemd/system/nfl-log-exporter.service > /dev/null << 'EOF'
[Unit]
Description=NFL Journal to File Exporter
After=nfl-updater.service

[Service]
Type=simple
ExecStart=/usr/local/bin/nfl-journal-to-file.sh
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

echo -e "${GREEN}✓${NC} Created exporter service"

# Start the exporter
sudo systemctl daemon-reload
sudo systemctl enable nfl-log-exporter.service
sudo systemctl restart nfl-log-exporter.service

echo -e "${GREEN}✓${NC} Started log exporter service"

# Wait for it to create some logs
sleep 3

echo ""
echo -e "${BLUE}3. VERIFYING LOG FILE${NC}"
echo "────────────────────────────────"

if [ -f /var/log/nfl_updater.log ]; then
    echo -e "${GREEN}✓${NC} Log file created"
    
    # Check content
    LINES=$(wc -l < /var/log/nfl_updater.log)
    echo "  Lines in file: $LINES"
    
    if [ $LINES -gt 0 ]; then
        echo ""
        echo "Sample content:"
        echo "---"
        tail -3 /var/log/nfl_updater.log | sed 's/^/  /'
        echo "---"
    fi
else
    echo -e "${YELLOW}⚠${NC} Log file not created yet"
fi

echo ""
echo -e "${BLUE}4. UPDATING AGENT CONFIGURATION${NC}"
echo "────────────────────────────────"

# Check if NFL job already exists
if sudo grep -q "job_name: nfl_updater" /etc/grafana-agent/agent.yaml; then
    echo -e "${GREEN}✓${NC} NFL job already configured"
    
    # Update the path if needed
    sudo sed -i 's|__path__: .*nfl.*|__path__: /var/log/nfl_updater.log|' /etc/grafana-agent/agent.yaml
    echo -e "${GREEN}✓${NC} Updated log path"
else
    echo "Adding NFL job to agent configuration..."
    
    # Load config for user IDs
    source /opt/grafana-cloud-emby/config/config.env
    LOGS_USER="${GRAFANA_CLOUD_LOGS_USER:-1299471}"
    
    # Add NFL job to the logs section
    # This is tricky with sed, so we'll use a different approach
    
    # Create a temporary file with the NFL job config
    cat > /tmp/nfl-job.yaml << 'EOF'
        
        # NFL Updater Logs from Journal
        - job_name: nfl_updater
          static_configs:
            - targets:
                - localhost
              labels:
                job: nfl_updater
                service: nfl
                source: journal
                __path__: /var/log/nfl_updater.log
                
          pipeline_stages:
            - regex:
                expression: '^(?P<timestamp>\S+) \S+ (?P<level>\S+) (?P<message>.*)'
            - timestamp:
                source: timestamp
                format: '2006-01-02T15:04:05.000'
                location: UTC
                action_on_failure: skip
            - labels:
                level:
            - output:
                source: message
EOF
    
    # Insert the NFL job into agent.yaml
    # Find the line with "scrape_configs:" under logs and append after the last job
    sudo cp /etc/grafana-agent/agent.yaml /etc/grafana-agent/agent.yaml.bak
    
    # Use awk to insert the NFL job
    sudo awk '
    /^logs:/ { in_logs=1 }
    /^[a-z_]*:/ && in_logs && !/^logs:/ { in_logs=0 }
    { print }
    in_logs && /job_name: embyserver/ { found_emby=1 }
    in_logs && found_emby && /^[[:space:]]*$/ && !added {
        while ((getline line < "/tmp/nfl-job.yaml") > 0) print line
        added=1
    }
    ' /etc/grafana-agent/agent.yaml.bak > /tmp/agent-new.yaml
    
    sudo mv /tmp/agent-new.yaml /etc/grafana-agent/agent.yaml
    echo -e "${GREEN}✓${NC} Added NFL job to agent configuration"
fi

echo ""
echo -e "${BLUE}5. RESTARTING GRAFANA AGENT${NC}"
echo "────────────────────────────────"

sudo systemctl restart grafana-agent
echo -e "${GREEN}✓${NC} Agent restarted"

sleep 5

# Check if agent is reading the file
AGENT_PID=$(pgrep grafana-agent | head -1)
if [ -n "$AGENT_PID" ]; then
    NFL_OPEN=$(sudo lsof -p $AGENT_PID 2>/dev/null | grep "nfl_updater.log" || echo "")
    if [ -n "$NFL_OPEN" ]; then
        echo -e "${GREEN}✓${NC} Agent is reading NFL log file"
    else
        echo -e "${YELLOW}⚠${NC} Agent not reading NFL log yet (may take a moment)"
    fi
fi

echo ""
echo -e "${BLUE}6. GENERATING TEST LOGS${NC}"
echo "────────────────────────────────"

# Restart NFL service to generate some logs
echo "Restarting NFL service to generate logs..."
sudo systemctl restart nfl-updater || echo "Service restart failed (may already be running)"

# Also add a test entry directly
echo "$(date -Iseconds) nfl-updater INFO Test log entry from setup script" | sudo tee -a /var/log/nfl_updater.log > /dev/null
echo "$(date -Iseconds) nfl-updater INFO Game update: Patriots 21 - Jets 14 (Q3)" | sudo tee -a /var/log/nfl_updater.log > /dev/null

echo -e "${GREEN}✓${NC} Generated test logs"

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  SETUP COMPLETE${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${GREEN}NFL logs are now being exported from journald to file!${NC}"
echo ""
echo "Services running:"
echo "  • nfl-updater.service - The actual NFL updater"
echo "  • nfl-log-exporter.service - Exports journal to /var/log/nfl_updater.log"
echo "  • grafana-agent.service - Collects logs and sends to Grafana Cloud"
echo ""
echo "Test in Grafana Explore with:"
echo -e "${CYAN}{job=\"nfl_updater\"}${NC}"
echo -e "${CYAN}{job=\"nfl_updater\"} |= \"Game\"${NC}"
echo -e "${CYAN}{job=\"nfl_updater\"} |= \"Test\"${NC}"
echo ""
echo "Monitor the pipeline:"
echo "  • NFL service: journalctl -u nfl-updater -f"
echo "  • Log file: tail -f /var/log/nfl_updater.log"
echo "  • Agent: sudo journalctl -u grafana-agent -f | grep nfl"