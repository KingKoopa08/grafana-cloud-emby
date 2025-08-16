# Grafana Cloud Logs Setup Guide

## Overview
This guide explains how to configure log collection for both Emby and NFL systems using Grafana Agent and Loki.

## Prerequisites

1. **Grafana Cloud Account** with:
   - Logs service enabled
   - API key with `logs:write` permission
   - Known Prometheus endpoint URL (to determine region)

2. **System Requirements**:
   - Grafana Agent installed and running
   - Read access to log files
   - Working metrics collection (recommended to verify first)

## Quick Setup

### 1. Create API Key with Logs Permission

1. Go to Grafana Cloud Portal
2. Navigate to: **My Account > Security > API Keys**
3. Create new API key with:
   - `metrics:write` - For metrics collection
   - `logs:write` - For log ingestion
4. Save the API key securely

### 2. Update Configuration

Edit `/opt/grafana-cloud-emby/config/config.env`:

```bash
GRAFANA_CLOUD_USER=your-user-id
GRAFANA_CLOUD_API_KEY=your-metrics-api-key  # Can be same as logs key if it has both permissions
GRAFANA_CLOUD_PROMETHEUS_URL=https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/push
```

### 3. Run Setup Script

```bash
cd /opt/grafana-cloud-emby
git pull
chmod +x ./scripts/add-logs-with-new-key.sh
sudo ./scripts/add-logs-with-new-key.sh
```

The script will:
- Detect your Grafana Cloud region automatically
- Test authentication with the new API key
- Configure log collection for Emby and NFL
- Verify logs are being collected

### 4. Verify Log Collection

Run the test script:

```bash
chmod +x ./scripts/test-logs-flow.sh
sudo ./scripts/test-logs-flow.sh
```

This will check:
- Agent status
- Log file accessibility
- Authentication errors
- Log batch sending
- Loki query results

## Log Sources

### Emby Server Logs
- **Path**: `/var/lib/emby/logs/embyserver.txt`
- **Job Name**: `embyserver`
- **Features**:
  - Multiline log support
  - Timestamp parsing
  - Automatic rotation handling

### NFL Updater Logs
- **Path**: `/var/log/nfl_updater.log`
- **Job Name**: `nfl_updater`
- **Features**:
  - Game score extraction
  - API metric parsing
  - Status tracking

## Querying Logs in Grafana

### Basic Queries

```logql
# All logs
{job=~".+"}

# Emby server logs
{job="embyserver"}

# NFL updater logs
{job="nfl_updater"}

# Emby errors
{job="embyserver"} |= "error"

# NFL game updates
{job="nfl_updater"} |~ "Game.*Score"
```

### Advanced Queries

```logql
# Count errors per minute
sum(rate({job="embyserver"} |= "error" [1m]))

# Extract NFL game scores
{job="nfl_updater"} 
  | regexp "Game (?P<teams>[^:]+):\\s+(?P<score>[\\d-]+)"
  | line_format "{{.teams}}: {{.score}}"

# Live TV activity
{job="embyserver"} |~ "LiveTV|tuner|stream"
```

## Troubleshooting

### No Logs Appearing

1. **Wait 2-3 minutes** - Initial log batches take time
2. **Check authentication**:
   ```bash
   sudo journalctl -u grafana-agent -f | grep 401
   ```
3. **Verify file permissions**:
   ```bash
   ls -l /var/lib/emby/logs/embyserver.txt
   ls -l /var/log/nfl_updater.log
   ```

### Authentication Errors (401)

Your API key lacks `logs:write` permission:

1. Create new API key with proper permissions
2. Update the key in the script or config
3. Re-run `add-logs-with-new-key.sh`

### Agent Not Reading Files

Check if agent has file handles open:
```bash
AGENT_PID=$(pgrep grafana-agent | head -1)
sudo lsof -p $AGENT_PID | grep -E "embyserver|nfl_updater"
```

### Wrong Region/Loki URL

The script auto-detects region from Prometheus URL:
- US West (prod-36): `logs-prod-021.grafana.net`
- US Central (prod-10): `logs-prod-006.grafana.net`
- EU (prod-13): `logs-prod-eu-west-0.grafana.net`

## Recovery Scripts

### Complete Reset
If everything is broken:
```bash
sudo ./scripts/complete-reset.sh
```
This restores metrics-only configuration.

### Add Logs Back
After fixing authentication:
```bash
sudo ./scripts/add-logs-with-new-key.sh
```

### Test Log Flow
Verify everything works:
```bash
sudo ./scripts/test-logs-flow.sh
```

## Configuration Details

### Agent Configuration Structure

```yaml
logs:
  configs:
    - name: default
      clients:
        - url: <LOKI_URL>
          basic_auth:
            username: <USER_ID>
            password: <API_KEY_WITH_LOGS_WRITE>
      positions:
        filename: /var/lib/grafana-agent/positions.yaml
      scrape_configs:
        - job_name: <JOB_NAME>
          static_configs:
            - targets: [localhost]
              labels:
                job: <JOB_NAME>
                __path__: <LOG_FILE_PATH>
          pipeline_stages:
            # Log parsing stages
```

### Pipeline Stages

- **multiline**: Combines multi-line log entries
- **regex**: Extracts fields from log lines
- **timestamp**: Parses and sets log timestamps
- **labels**: Adds extracted fields as labels
- **output**: Formats final log message

## Best Practices

1. **Separate API Keys**: Consider using separate keys for metrics and logs
2. **Log Rotation**: Ensure log rotation doesn't break collection
3. **Permissions**: Grant minimal required permissions to agent
4. **Monitoring**: Set up alerts for authentication failures
5. **Testing**: Always test configuration changes with the test script

## Support

For issues:
1. Check agent logs: `sudo journalctl -u grafana-agent -f`
2. Run test script: `sudo ./scripts/test-logs-flow.sh`
3. Review this documentation
4. Check Grafana Cloud status page