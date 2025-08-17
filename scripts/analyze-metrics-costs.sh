#!/bin/bash

# Analyze Grafana Cloud metrics usage and costs
# Based on Grafana Cloud cost management best practices

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
echo -e "${CYAN}  GRAFANA CLOUD METRICS COST ANALYSIS${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Load config
source /opt/grafana-cloud-emby/config/config.env

PROM_URL="https://prometheus-prod-36-prod-us-west-0.grafana.net"
USER="${GRAFANA_CLOUD_USER}"
API_KEY="${GRAFANA_CLOUD_API_KEY}"

echo -e "${BLUE}1. TOP HIGH-CARDINALITY METRICS${NC}"
echo "────────────────────────────────"
echo "Querying top metrics by series count..."
echo ""

# Find metrics with highest cardinality
curl -s -u "$USER:$API_KEY" \
  "$PROM_URL/api/prom/api/v1/query" \
  --data-urlencode 'query=topk(20, count by (__name__)({__name__=~".+"}))' | \
  jq -r '.data.result[] | "\(.metric.__name__): \(.value[1]) series"' 2>/dev/null || echo "Failed to query"

echo ""
echo -e "${BLUE}2. METRICS BY JOB${NC}"
echo "────────────────────────────────"

# Count series per job
curl -s -u "$USER:$API_KEY" \
  "$PROM_URL/api/prom/api/v1/query" \
  --data-urlencode 'query=count by (job) ({__name__=~".+"})' | \
  jq -r '.data.result[] | "\(.metric.job): \(.value[1]) series"' 2>/dev/null || echo "Failed to query"

echo ""
echo -e "${BLUE}3. EMBY METRICS ANALYSIS${NC}"
echo "────────────────────────────────"

# Analyze Emby-specific metrics
echo "Emby Live TV metrics cardinality:"
curl -s -u "$USER:$API_KEY" \
  "$PROM_URL/api/prom/api/v1/query" \
  --data-urlencode 'query=count by (__name__) ({__name__=~"emby_livetv.*"})' | \
  jq -r '.data.result[] | "  \(.metric.__name__): \(.value[1]) series"' 2>/dev/null || echo "No Emby metrics found"

echo ""
echo -e "${BLUE}4. HIGH-FREQUENCY METRICS${NC}"
echo "────────────────────────────────"
echo "Checking scrape intervals..."

# Check scrape intervals
curl -s -u "$USER:$API_KEY" \
  "$PROM_URL/api/prom/api/v1/query" \
  --data-urlencode 'query=prometheus_target_interval_length_seconds{quantile="0.99"}' | \
  jq -r '.data.result[] | "Job: \(.metric.job), Interval: \(.value[1])s"' 2>/dev/null || echo "Failed to query"

echo ""
echo -e "${BLUE}5. LABEL CARDINALITY ANALYSIS${NC}"
echo "────────────────────────────────"

# Check which labels have high cardinality
echo "Top label combinations for emby_livetv_channel_info:"
curl -s -u "$USER:$API_KEY" \
  "$PROM_URL/api/prom/api/v1/series" \
  --data-urlencode 'match[]=emby_livetv_channel_info' \
  --data-urlencode 'start=5m' | \
  jq -r '.data | length' 2>/dev/null | xargs -I {} echo "  Total series: {}"

echo ""
echo -e "${BLUE}6. DATA POINTS PER MINUTE (DPM)${NC}"
echo "────────────────────────────────"

# Calculate approximate DPM
echo "Calculating data points per minute..."
curl -s -u "$USER:$API_KEY" \
  "$PROM_URL/api/prom/api/v1/query" \
  --data-urlencode 'query=sum(rate(prometheus_tsdb_samples_appended_total[5m])) * 60' | \
  jq -r '.data.result[0].value[1]' 2>/dev/null | xargs -I {} echo "Approximate DPM: {}"

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  COST REDUCTION RECOMMENDATIONS${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${YELLOW}Based on analysis, consider these optimizations:${NC}"
echo ""

echo "1. REDUCE SCRAPE FREQUENCY"
echo "   Current agent.yaml has 30s interval for Emby"
echo "   ${CYAN}→ Change to 60s or 120s for non-critical metrics${NC}"
echo ""

echo "2. DROP HIGH-CARDINALITY LABELS"
echo "   Emby channels create many unique series"
echo "   ${CYAN}→ Consider aggregating by category instead of channel${NC}"
echo ""

echo "3. USE RECORDING RULES"
echo "   Pre-aggregate frequently-queried metrics"
echo "   ${CYAN}→ Create rules for dashboard queries${NC}"
echo ""

echo "4. IMPLEMENT METRIC FILTERING"
echo "   Drop unnecessary metrics at collection time"
echo "   ${CYAN}→ Add metric_relabel_configs to agent.yaml${NC}"
echo ""

echo "5. REVIEW DASHBOARD QUERIES"
echo "   Complex queries increase costs"
echo "   ${CYAN}→ Simplify queries and reduce refresh rates${NC}"
echo ""

echo -e "${BLUE}QUICK WINS:${NC}"
echo ""
echo "Add this to your agent.yaml to drop high-cardinality metrics:"
echo ""
cat << 'EOF'
metrics:
  configs:
    - name: default
      scrape_configs:
        - job_name: emby
          scrape_interval: 120s  # Increased from 30s
          metric_relabel_configs:
            # Drop per-channel metrics (high cardinality)
            - source_labels: [__name__, channel_name]
              regex: 'emby_livetv_channel_info;.+'
              action: drop
            
            # Keep only essential program info
            - source_labels: [__name__]
              regex: 'emby_livetv_program_.*'
              action: drop
              
            # Drop detailed recording metrics
            - source_labels: [__name__]
              regex: 'emby_livetv_recording_detail.*'
              action: drop
EOF

echo ""
echo -e "${GREEN}To see cost impact in Grafana Cloud:${NC}"
echo "1. Go to: Billing → Usage → Metrics"
echo "2. Check 'Billable series' graph"
echo "3. Use Cardinality Management dashboards"
echo ""
echo "Monitor at: https://grafana.com/orgs/kingkoopa08/billing/usage"