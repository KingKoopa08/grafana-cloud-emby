# NFL Live Score EPG Updater Monitoring Guide

## Overview
Complete monitoring solution for the NFL Live Score EPG Updater system using Grafana Cloud with Loki for logs and Prometheus for metrics.

## Architecture

```
NFL Updater Service
    ↓
Application Logs (/home/emby/py/nfl-updater/nfl_updater.log)
    ↓
Grafana Agent
    ├── Log Pipeline (Loki)
    │   ├── Parse timestamps
    │   ├── Extract fields (teams, scores, states)
    │   └── Generate metrics from logs
    └── Metrics Pipeline (Prometheus)
        ├── Score update frequency
        ├── API response times
        ├── Error rates
        └── Service health
```

## Key Features

### 1. Log Collection
- **Application logs**: Python formatted logs with rotation support
- **Systemd journal**: Service start/stop/restart events
- **Field extraction**: Teams, scores, game states, API metrics

### 2. Metrics Generated
- `nfl_updater_service_up`: Service availability (0/1)
- `nfl_updater_game_score_update`: Counter for score updates
- `nfl_updater_error_total`: Error counter
- `nfl_updater_espn_api_duration_seconds`: ESPN API latency histogram
- `nfl_updater_emby_api_duration_seconds`: Emby API latency histogram
- `nfl_updater_game_state_total`: Game state changes counter
- `nfl_updater_service_restart_total`: Service restart counter

### 3. Dashboard Panels
1. **Service Health**: Green/Red status indicator
2. **Live Score Feed**: Real-time score updates table
3. **Update Timeline**: Score update frequency graph
4. **Game Status Distribution**: Pie chart (LIVE/FINAL/SCHEDULED/HALFTIME)
5. **API Response Times**: P95 latency graphs
6. **Error Log Stream**: Live error tail
7. **Error Rate**: Hourly error histogram

### 4. Alerting Rules

#### Critical Alerts
- **Service Down**: No response for >5 minutes
- **Restart Loop**: >3 restarts in 10 minutes

#### Warning Alerts
- **High Error Rate**: >10 errors per hour
- **No Updates**: Missing updates during game windows
- **API Slowness**: Response time >5 seconds

#### Info Alerts
- **New Live Game**: Game state changed to LIVE

## Deployment

### Prerequisites
1. Grafana Cloud account with:
   - Prometheus endpoint
   - Loki endpoint
   - API key with write permissions

2. NFL Updater installed as systemd service:
   ```bash
   sudo systemctl status nfl-updater
   ```

3. Log file accessible:
   ```bash
   ls -la /home/emby/py/nfl-updater/nfl_updater.log
   ```

### Installation Steps

1. **Clone the repository**:
   ```bash
   cd /opt
   git clone https://github.com/yourusername/grafana-cloud-emby.git
   cd grafana-cloud-emby
   ```

2. **Configure credentials**:
   ```bash
   cp config/config.env.example config/config.env
   nano config/config.env
   ```
   
   Add:
   ```env
   GRAFANA_CLOUD_USER=your-instance-id
   GRAFANA_CLOUD_API_KEY=your-api-key
   GRAFANA_CLOUD_PROMETHEUS_URL=https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/push
   GRAFANA_CLOUD_LOKI_URL=https://logs-prod-021.grafana.net/loki/api/v1/push
   ```

3. **Deploy monitoring**:
   ```bash
   sudo ./scripts/deploy-nfl-monitoring.sh
   ```

4. **Import dashboard**:
   - Log into Grafana Cloud
   - Go to Dashboards > Import
   - Upload `dashboards/nfl-updater-monitoring.json`
   - Select datasources when prompted

5. **Configure alerts**:
   - Go to Alerting > Alert rules
   - Import rules from `config/nfl-alerts.yaml`
   - Set up notification channels

## Loki Queries

### Live Score Updates
```logql
{job="nfl-updater"} |= "Updated:" 
| regexp `(?P<away_team>\w+\s?\w*)\s+\((?P<away_score>\d+)\)\s+at\s+(?P<home_team>\w+\s?\w*)\s+\((?P<home_score>\d+)\)`
| line_format "{{.away_team}} ({{.away_score}}) at {{.home_team}} ({{.home_score}})"
```

### Error Tracking
```logql
{job="nfl-updater"} |= "ERROR" 
| regexp `(?P<error_type>\w+Error|Exception)`
```

### Game State Changes
```logql
{job="nfl-updater"} 
| regexp `Game.*:\s+\d+-\d+\s+\((?P<state>LIVE|HALFTIME|FINAL|SCHEDULED)\)`
| line_format "Game {{.state}}"
```

### API Performance
```logql
{job="nfl-updater"} 
| regexp `ESPN API response time: (?P<response_time>[\d.]+)s`
| response_time > 2
```

### Emby Guide Refresh
```logql
sum(rate({job="nfl-updater"} |= "Emby guide refresh triggered" [5m]))
```

## Prometheus Queries

### Service Uptime Percentage
```promql
avg_over_time(nfl_updater_service_up[24h]) * 100
```

### Updates Per Minute
```promql
rate(nfl_updater_game_score_update[1m])
```

### Error Rate
```promql
sum(rate(nfl_updater_error_total[5m]))
```

### API Latency P95
```promql
histogram_quantile(0.95, 
  sum(rate(nfl_updater_espn_api_duration_seconds_bucket[5m])) by (le)
)
```

### Games by State
```promql
count by (game_state) (
  nfl_updater_game_state_total
)
```

## Best Practices

### Log Retention
- **Grafana Cloud Free**: 50GB/month retention
- **Recommended**: 7 days for debug logs, 30 days for errors
- **Cardinality**: Keep labels minimal (team names not recommended as labels)

### Performance Optimization
1. **Log Sampling**: For high-volume periods, consider sampling
2. **Metric Aggregation**: Use recording rules for frequently-queried metrics
3. **Label Management**: Avoid high-cardinality labels like user IDs

### Monitoring Schedule
- **Peak Load**: Sunday 1-7 PM ET (up to 10 concurrent games)
- **Regular Load**: Thursday/Monday nights (1-2 games)
- **Maintenance Window**: Tuesday/Wednesday (no games)

## Troubleshooting

### No Logs Appearing
```bash
# Check agent is running
sudo systemctl status grafana-agent

# Check log file permissions
ls -la /home/emby/py/nfl-updater/nfl_updater.log

# Check agent can read logs
sudo -u grafana-agent cat /home/emby/py/nfl-updater/nfl_updater.log

# View agent logs
sudo journalctl -u grafana-agent -f
```

### Missing Metrics
```bash
# Check metrics endpoint
curl http://localhost:12345/metrics | grep nfl_updater

# Verify Loki is receiving data
curl -G -s "${GRAFANA_CLOUD_LOKI_URL}/loki/api/v1/query" \
  --data-urlencode 'query={job="nfl-updater"}' \
  -u "${GRAFANA_CLOUD_USER}:${GRAFANA_CLOUD_API_KEY}"
```

### High Cardinality Issues
```promql
# Check label cardinality
count(count by (label_name) (metric_name))

# Find high-cardinality series
topk(10, count by (__name__)({__name__=~"nfl_updater.*"}))
```

## Log Format Examples

### Score Update
```
2024-01-14 16:23:45,123 - nfl_updater - INFO - Updated: Kansas City (21) at Buffalo (17)
```

### Game State Change
```
2024-01-14 13:00:12,456 - nfl_updater - INFO - Game KC @ BUF: 0-0 (LIVE)
```

### API Response
```
2024-01-14 16:23:44,789 - nfl_updater - DEBUG - ESPN API response time: 0.234s
```

### Error
```
2024-01-14 16:25:01,234 - nfl_updater - ERROR - Failed to connect to ESPN API: Connection refused
```

## Support

For issues or questions:
1. Check agent logs: `sudo journalctl -u grafana-agent -f`
2. Verify service status: `sudo systemctl status nfl-updater`
3. Test queries in Grafana Explore
4. Review this guide's troubleshooting section

## Updates

To update the monitoring configuration:
```bash
cd /opt/grafana-cloud-emby
git pull
sudo ./scripts/deploy-nfl-monitoring.sh
```

## Security Considerations

1. **API Keys**: Store in environment variables, never in code
2. **Log Sanitization**: Ensure no sensitive data in logs
3. **Network Security**: Use HTTPS for all API endpoints
4. **Access Control**: Limit log file permissions to necessary users

## Performance Metrics

Expected resource usage:
- **CPU**: <5% during normal operation
- **Memory**: ~50MB for Grafana Agent
- **Network**: ~1MB/hour log traffic
- **Disk**: ~10MB/day log storage (with rotation)