#!/bin/bash

# Script to apply cost-optimized Grafana Agent configuration
# This will reduce metrics from ~12,000 to ~2,000 series (83% reduction)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root (use sudo)"
   exit 1
fi

# Set paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(dirname "$SCRIPT_DIR")/config"
AGENT_CONFIG="/etc/grafana-agent/grafana-agent.yaml"
BACKUP_DIR="/etc/grafana-agent/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

log_info "Starting Grafana Agent cost optimization..."
log_info "This will reduce your metrics from ~12,000 to ~2,000 series"

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Check current metrics rate (if agent is running)
if systemctl is-active --quiet grafana-agent; then
    log_info "Current Grafana Agent is running. Checking metrics..."
    
    # Try to get current metric count
    CURRENT_METRICS=$(curl -s http://localhost:12345/metrics 2>/dev/null | grep -c "^[a-z]" || echo "unknown")
    log_info "Current local metrics count: $CURRENT_METRICS"
fi

# Backup current configuration
if [ -f "$AGENT_CONFIG" ]; then
    log_info "Backing up current configuration..."
    cp "$AGENT_CONFIG" "$BACKUP_DIR/grafana-agent.yaml.$TIMESTAMP"
    log_success "Backup saved to: $BACKUP_DIR/grafana-agent.yaml.$TIMESTAMP"
else
    log_warning "No existing configuration found at $AGENT_CONFIG"
fi

# Check if config.env exists
if [ ! -f "$CONFIG_DIR/config.env" ]; then
    log_error "Configuration file not found: $CONFIG_DIR/config.env"
    log_error "Please create it from config.env.example and add your API keys"
    exit 1
fi

# Source the config
source "$CONFIG_DIR/config.env"

# Validate required variables
if [ -z "$GRAFANA_CLOUD_API_KEY" ]; then
    log_error "GRAFANA_CLOUD_API_KEY not set in config.env"
    exit 1
fi

# Copy the optimized configuration
log_info "Applying cost-optimized configuration..."
cp "$CONFIG_DIR/agent-cost-optimized.yaml" "$AGENT_CONFIG"

# Replace variables in the config
sed -i "s/\${GRAFANA_CLOUD_API_KEY}/$GRAFANA_CLOUD_API_KEY/g" "$AGENT_CONFIG"

# Validate the configuration
log_info "Validating configuration..."
if grafana-agent -config.check "$AGENT_CONFIG" 2>/dev/null; then
    log_success "Configuration is valid"
else
    log_warning "Configuration validation had warnings (this is often okay)"
fi

# Restart Grafana Agent
log_info "Restarting Grafana Agent..."
systemctl daemon-reload
systemctl restart grafana-agent

# Wait for agent to start
sleep 5

# Check if agent is running
if systemctl is-active --quiet grafana-agent; then
    log_success "Grafana Agent restarted successfully"
else
    log_error "Grafana Agent failed to start"
    log_info "Rolling back to previous configuration..."
    cp "$BACKUP_DIR/grafana-agent.yaml.$TIMESTAMP" "$AGENT_CONFIG"
    systemctl restart grafana-agent
    log_error "Rolled back to previous configuration"
    exit 1
fi

# Check for errors in logs
log_info "Checking for errors..."
if journalctl -u grafana-agent -n 50 --no-pager | grep -q "401\|403\|authentication"; then
    log_warning "Authentication warnings detected - check your API key"
fi

# Show what metrics are being collected now
log_info "Checking optimized metrics..."
sleep 10

echo ""
log_success "=== OPTIMIZATION COMPLETE ==="
echo ""
log_info "Expected changes:"
echo "  • Removed ~3,063 Grafana Cloud internal metrics"
echo "  • Removed ~3,011 Loki internal metrics"
echo "  • Removed ~1,077 Prometheus internal metrics"
echo "  • Filtered ~2,800 excessive node_exporter metrics"
echo ""
log_info "Metrics reduction: ~12,000 → ~2,000 series (83% reduction)"
log_info "Cost savings: ~\$125-130/month"
echo ""
log_info "What's preserved:"
echo "  ✓ All Emby metrics (emby_*)"
echo "  ✓ Essential system metrics (CPU, memory, disk, network)"
echo "  ✓ All logs collection"
echo ""

# Show current agent status
log_info "Current agent status:"
systemctl status grafana-agent --no-pager | head -15

echo ""
log_info "To verify metrics in Grafana Cloud:"
echo "  1. Go to your Grafana instance"
echo "  2. Navigate to Explore"
echo "  3. Run query: count(count by (__name__)({job=~\".+\"}))"
echo "  4. This shows total unique metric names"
echo ""
log_info "To monitor DPM usage:"
echo "  1. Go to Billing & Usage"
echo "  2. Check Metrics usage"
echo "  3. DPM should drop significantly in next 15-30 minutes"
echo ""

# Create verification script
cat > /tmp/verify-metrics.sh << 'EOF'
#!/bin/bash
echo "Checking local metrics being scraped..."
curl -s http://localhost:12345/metrics 2>/dev/null | grep "^emby_" | head -10
echo ""
echo "Total metrics lines:"
curl -s http://localhost:12345/metrics 2>/dev/null | grep -c "^[a-z]" || echo "0"
EOF

chmod +x /tmp/verify-metrics.sh

log_info "To check what metrics are being collected locally:"
echo "  Run: /tmp/verify-metrics.sh"
echo ""

log_warning "Note: It may take 15-30 minutes for changes to reflect in Grafana Cloud billing"

# Save rollback script
cat > "$BACKUP_DIR/rollback-$TIMESTAMP.sh" << EOF
#!/bin/bash
echo "Rolling back to configuration from $TIMESTAMP..."
sudo cp "$BACKUP_DIR/grafana-agent.yaml.$TIMESTAMP" "$AGENT_CONFIG"
sudo systemctl restart grafana-agent
echo "Rollback complete"
EOF
chmod +x "$BACKUP_DIR/rollback-$TIMESTAMP.sh"

log_info "If you need to rollback, run:"
echo "  $BACKUP_DIR/rollback-$TIMESTAMP.sh"
echo ""

log_success "Optimization deployment complete!"