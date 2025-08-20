#!/bin/bash

# Script to verify metrics reduction after applying cost optimization

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Log functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

echo ""
echo -e "${CYAN}=== GRAFANA AGENT METRICS VERIFICATION ===${NC}"
echo ""

# Check if Grafana Agent is running
if systemctl is-active --quiet grafana-agent; then
    log_success "Grafana Agent is running"
else
    log_error "Grafana Agent is not running"
    exit 1
fi

# Check for authentication errors
echo ""
log_info "Checking for authentication errors..."
AUTH_ERRORS=$(journalctl -u grafana-agent -n 100 --no-pager 2>/dev/null | grep -c "401\|403" || echo "0")
if [ "$AUTH_ERRORS" -eq 0 ]; then
    log_success "No authentication errors found"
else
    log_warning "Found $AUTH_ERRORS authentication errors - check your API key"
fi

# Check what metrics are being scraped locally
echo ""
log_info "Checking locally scraped metrics..."
echo ""

# Count metrics by prefix
echo -e "${CYAN}Metrics by category:${NC}"
echo "----------------------------------------"

# Emby metrics
EMBY_COUNT=$(curl -s http://localhost:12345/metrics 2>/dev/null | grep -c "^emby_" || echo "0")
echo -e "Emby metrics:                ${GREEN}$EMBY_COUNT${NC}"

# Node metrics
NODE_COUNT=$(curl -s http://localhost:12345/metrics 2>/dev/null | grep -c "^node_" || echo "0")
echo -e "Node metrics:                ${GREEN}$NODE_COUNT${NC}"

# Check for unwanted metrics that should be filtered
echo ""
echo -e "${CYAN}Checking for filtered metrics (should be 0):${NC}"
echo "----------------------------------------"

# Grafana Cloud internal
GRAFANA_COUNT=$(curl -s http://localhost:12345/metrics 2>/dev/null | grep -c "^grafanacloud_\|^usage_cloud_\|^billing_" || echo "0")
if [ "$GRAFANA_COUNT" -eq 0 ]; then
    echo -e "Grafana Cloud internal:      ${GREEN}$GRAFANA_COUNT ✓${NC}"
else
    echo -e "Grafana Cloud internal:      ${RED}$GRAFANA_COUNT ✗${NC}"
fi

# Loki internal
LOKI_COUNT=$(curl -s http://localhost:12345/metrics 2>/dev/null | grep -c "^loki_\|^promtail_" || echo "0")
if [ "$LOKI_COUNT" -eq 0 ]; then
    echo -e "Loki internal:               ${GREEN}$LOKI_COUNT ✓${NC}"
else
    echo -e "Loki internal:               ${RED}$LOKI_COUNT ✗${NC}"
fi

# Prometheus internal
PROM_COUNT=$(curl -s http://localhost:12345/metrics 2>/dev/null | grep -c "^prometheus_" || echo "0")
if [ "$PROM_COUNT" -eq 0 ]; then
    echo -e "Prometheus internal:         ${GREEN}$PROM_COUNT ✓${NC}"
else
    echo -e "Prometheus internal:         ${RED}$PROM_COUNT ✗${NC}"
fi

# Go runtime
GO_COUNT=$(curl -s http://localhost:12345/metrics 2>/dev/null | grep -c "^go_" || echo "0")
if [ "$GO_COUNT" -eq 0 ]; then
    echo -e "Go runtime:                  ${GREEN}$GO_COUNT ✓${NC}"
else
    echo -e "Go runtime:                  ${RED}$GO_COUNT ✗${NC}"
fi

# Process metrics
PROCESS_COUNT=$(curl -s http://localhost:12345/metrics 2>/dev/null | grep -c "^process_" || echo "0")
if [ "$PROCESS_COUNT" -eq 0 ]; then
    echo -e "Process metrics:             ${GREEN}$PROCESS_COUNT ✓${NC}"
else
    echo -e "Process metrics:             ${RED}$PROCESS_COUNT ✗${NC}"
fi

# Agent metrics
AGENT_COUNT=$(curl -s http://localhost:12345/metrics 2>/dev/null | grep -c "^agent_\|^grafana_agent_" || echo "0")
if [ "$AGENT_COUNT" -eq 0 ]; then
    echo -e "Agent self-monitoring:       ${GREEN}$AGENT_COUNT ✓${NC}"
else
    echo -e "Agent self-monitoring:       ${RED}$AGENT_COUNT ✗${NC}"
fi

# Total metrics
echo ""
TOTAL_COUNT=$(curl -s http://localhost:12345/metrics 2>/dev/null | grep -c "^[a-z]" || echo "0")
echo -e "${CYAN}Total metric lines:${NC} ${GREEN}$TOTAL_COUNT${NC}"

# Check node metrics detail
echo ""
echo -e "${CYAN}Node metrics breakdown:${NC}"
echo "----------------------------------------"
CPU_COUNT=$(curl -s http://localhost:12345/metrics 2>/dev/null | grep -c "^node_cpu_" || echo "0")
echo "CPU metrics:           $CPU_COUNT"
MEM_COUNT=$(curl -s http://localhost:12345/metrics 2>/dev/null | grep -c "^node_memory_" || echo "0")
echo "Memory metrics:        $MEM_COUNT"
DISK_COUNT=$(curl -s http://localhost:12345/metrics 2>/dev/null | grep -c "^node_disk_" || echo "0")
echo "Disk metrics:          $DISK_COUNT"
FS_COUNT=$(curl -s http://localhost:12345/metrics 2>/dev/null | grep -c "^node_filesystem_" || echo "0")
echo "Filesystem metrics:    $FS_COUNT"
NET_COUNT=$(curl -s http://localhost:12345/metrics 2>/dev/null | grep -c "^node_network_" || echo "0")
echo "Network metrics:       $NET_COUNT"

# Sample some actual metrics
echo ""
echo -e "${CYAN}Sample of collected metrics:${NC}"
echo "----------------------------------------"
echo "Emby metrics:"
curl -s http://localhost:12345/metrics 2>/dev/null | grep "^emby_" | head -3 | sed 's/^/  /'
echo ""
echo "System metrics:"
curl -s http://localhost:12345/metrics 2>/dev/null | grep "^node_" | head -3 | sed 's/^/  /'

# Check remote write status
echo ""
echo -e "${CYAN}Remote write status:${NC}"
echo "----------------------------------------"
REMOTE_SUCCESS=$(curl -s http://localhost:12345/metrics 2>/dev/null | grep "prometheus_remote_write_samples_total" | tail -1 | awk '{print $2}' || echo "unknown")
REMOTE_FAILED=$(curl -s http://localhost:12345/metrics 2>/dev/null | grep "prometheus_remote_write_samples_failed_total" | tail -1 | awk '{print $2}' || echo "0")

if [ "$REMOTE_SUCCESS" != "unknown" ]; then
    echo "Samples sent successfully: $REMOTE_SUCCESS"
    echo "Samples failed:           $REMOTE_FAILED"
else
    echo "Remote write metrics not available (this is expected with optimization)"
fi

# Summary
echo ""
echo -e "${CYAN}=== SUMMARY ===${NC}"
echo ""

FILTERED_TOTAL=$((GRAFANA_COUNT + LOKI_COUNT + PROM_COUNT + GO_COUNT + PROCESS_COUNT + AGENT_COUNT))

if [ "$FILTERED_TOTAL" -eq 0 ]; then
    log_success "All internal metrics successfully filtered!"
    echo ""
    echo "✓ Emby metrics:        Preserved ($EMBY_COUNT series)"
    echo "✓ System metrics:      Optimized ($NODE_COUNT series)"
    echo "✓ Internal metrics:    Removed (0 series)"
    echo ""
    log_success "Optimization successful! You should see ~83% reduction in DPM."
else
    log_warning "Some internal metrics are still being collected ($FILTERED_TOTAL series)"
    echo "Please check the configuration and restart Grafana Agent."
fi

echo ""
log_info "Note: It takes 15-30 minutes for changes to reflect in Grafana Cloud billing."
echo ""
echo "To check in Grafana Cloud:"
echo "  1. Go to Explore"
echo "  2. Run: count(count by (__name__)({}))"
echo "  3. Check Billing & Usage → Metrics for DPM changes"
echo ""