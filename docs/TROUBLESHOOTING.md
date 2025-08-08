# Troubleshooting Guide

This guide helps diagnose and resolve common issues with the Grafana Cloud Emby monitoring setup.

## Quick Diagnostics

Run the debug script for immediate diagnostics:

```bash
./scripts/debug.sh
```

## Common Issues and Solutions

### 1. Grafana Agent Won't Start

**Symptoms:**
- `systemctl status grafana-agent` shows failed state
- No metrics appearing in Grafana Cloud

**Solutions:**

Check configuration syntax:
```bash
grafana-agent -config.check /etc/grafana-agent/grafana-agent.yaml
```

Check for port conflicts:
```bash
sudo netstat -tulpn | grep -E "12345|9119"
```

Review error logs:
```bash
sudo journalctl -u grafana-agent -n 100 --no-pager
```

Common fixes:
```bash
# Fix permissions
sudo chown -R grafana-agent:grafana-agent /var/lib/grafana-agent
sudo chown -R grafana-agent:grafana-agent /var/log/grafana-agent

# Restart with clean state
sudo systemctl stop grafana-agent
sudo rm -rf /var/lib/grafana-agent/wal/*
sudo systemctl start grafana-agent
```

### 2. Emby Exporter Not Working

**Symptoms:**
- No Emby metrics in Grafana
- Port 9119 not responding

**Solutions:**

Test Emby API connectivity:
```bash
curl -H "X-Emby-Token: YOUR_API_KEY" http://localhost:8096/System/Info
```

Check Python environment:
```bash
# Test exporter manually
cd /opt/emby-exporter
sudo -u emby-exporter ./venv/bin/python3 emby_exporter.py
```

Common fixes:
```bash
# Reinstall dependencies
sudo /opt/emby-exporter/venv/bin/pip install --upgrade -r /path/to/exporters/requirements.txt

# Check environment variables
sudo cat /etc/systemd/system/emby-exporter.service | grep Environment

# Restart service
sudo systemctl daemon-reload
sudo systemctl restart emby-exporter
```

### 3. Authentication Errors

**Symptoms:**
- "401 Unauthorized" in logs
- "403 Forbidden" errors

**Solutions:**

Verify Grafana Cloud API key:
```bash
# Test API key
curl -H "Authorization: Bearer YOUR_API_KEY" \
     https://grafana.com/api/orgs

# Check config
grep GRAFANA_CLOUD_API_KEY config/config.env
```

Regenerate API key:
1. Log in to Grafana Cloud
2. Go to **Configuration** > **API Keys**
3. Delete old key
4. Create new key with `MetricsPublisher` role
5. Update config.env
6. Restart services

### 4. No Metrics in Grafana

**Symptoms:**
- Services running but no data in dashboards
- Empty graphs in Grafana

**Solutions:**

Check metric scraping:
```bash
# Local metrics endpoint
curl http://localhost:9119/metrics | head -20

# Agent metrics
curl http://localhost:12345/metrics | grep prometheus_remote_write
```

Verify remote write:
```bash
# Check for remote write errors
sudo journalctl -u grafana-agent | grep -i "remote write"

# Check samples sent
curl -s http://localhost:12345/metrics | grep prometheus_remote_write_samples_total
```

Test Prometheus endpoint:
```bash
curl -u "INSTANCE_ID:API_KEY" \
     https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/api/v1/query \
     -d 'query=up'
```

### 5. High Resource Usage

**Symptoms:**
- High CPU or memory usage
- Server becoming slow
- OOM (Out of Memory) errors

**Solutions:**

Check resource usage:
```bash
# Overall system
top -b -n 1 | head -20

# Specific services
ps aux | grep -E "grafana-agent|emby_exporter"

# Memory details
free -h
```

Optimize configuration:
```bash
# Edit config to reduce load
nano config/config.env

# Increase scrape interval (reduces frequency)
SCRAPE_INTERVAL="60"  # or 120 for very low resources

# Reduce retention in Grafana Agent
sudo nano /etc/grafana-agent/grafana-agent.yaml
# Add under metrics.configs:
#   wal_truncate_frequency: 30m
#   min_wal_time: 15m
```

Restart with limits:
```bash
# Add resource limits to service
sudo systemctl edit emby-exporter

# Add these lines:
[Service]
MemoryLimit=512M
CPUQuota=50%

# Restart
sudo systemctl daemon-reload
sudo systemctl restart emby-exporter
```

### 6. Logs Not Appearing

**Symptoms:**
- No logs in Grafana Loki
- Empty log panels

**Solutions:**

Check log paths:
```bash
# Verify Emby log location
ls -la /var/lib/emby/logs/

# Check permissions
sudo -u grafana-agent ls /var/lib/emby/logs/
```

Test Loki endpoint:
```bash
curl -u "INSTANCE_ID:API_KEY" \
     https://logs-prod-012.grafana.net/loki/api/v1/labels
```

Fix common issues:
```bash
# Add grafana-agent to emby group for log access
sudo usermod -a -G emby grafana-agent

# Or change log permissions
sudo chmod 755 /var/lib/emby/logs
sudo chmod 644 /var/lib/emby/logs/*.txt

# Restart agent
sudo systemctl restart grafana-agent
```

### 7. Connection Timeouts

**Symptoms:**
- "Connection timeout" errors
- "No route to host" messages

**Solutions:**

Check network connectivity:
```bash
# Test Grafana Cloud
ping -c 4 grafana.net

# Test HTTPS
curl -I https://grafana.com

# Check DNS
nslookup prometheus-prod-36-prod-us-west-0.grafana.net
```

Check firewall:
```bash
# List firewall rules
sudo iptables -L -n

# Allow outbound HTTPS
sudo ufw allow out 443/tcp

# Check if behind proxy
echo $HTTP_PROXY
echo $HTTPS_PROXY
```

Configure proxy (if needed):
```bash
# Add to /etc/systemd/system/grafana-agent.service
[Service]
Environment="HTTPS_PROXY=http://proxy.company.com:8080"
Environment="NO_PROXY=localhost,127.0.0.1"

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl restart grafana-agent
```

## Advanced Debugging

### Enable Debug Logging

Grafana Agent:
```bash
# Edit service file
sudo systemctl edit grafana-agent

# Add debug flag
[Service]
ExecStart=
ExecStart=/usr/bin/grafana-agent \
  -config.file=/etc/grafana-agent/grafana-agent.yaml \
  -log.level=debug

# Restart and watch logs
sudo systemctl restart grafana-agent
sudo journalctl -u grafana-agent -f
```

Emby Exporter:
```bash
# Edit exporter script
sudo nano /opt/emby-exporter/emby_exporter.py

# Change log level
logging.basicConfig(level=logging.DEBUG)

# Restart
sudo systemctl restart emby-exporter
```

### Manual Service Testing

Test Grafana Agent:
```bash
# Run manually
sudo -u grafana-agent grafana-agent \
  -config.file=/etc/grafana-agent/grafana-agent.yaml \
  -config.expand-env
```

Test Emby Exporter:
```bash
# Set environment variables
export EMBY_API_KEY="your-key"
export EMBY_SERVER_URL="http://localhost:8096"

# Run directly
/opt/emby-exporter/venv/bin/python3 /opt/emby-exporter/emby_exporter.py
```

### Network Packet Capture

For deep network debugging:
```bash
# Capture traffic to Grafana Cloud
sudo tcpdump -i any -w grafana.pcap \
  'host prometheus-prod-36-prod-us-west-0.grafana.net'

# Analyze with Wireshark or tcpdump
tcpdump -r grafana.pcap -nn
```

## Performance Tuning

### Optimize Grafana Agent

```yaml
# /etc/grafana-agent/grafana-agent.yaml modifications

metrics:
  global:
    scrape_interval: 60s  # Increase from 30s
    scrape_timeout: 10s
  
  configs:
    - name: integrations
      # Add WAL settings
      wal_truncate_frequency: 1h
      min_wal_time: 30m
      max_wal_time: 2h
      
      # Limit samples
      sample_limit: 10000
      
      # Add metric relabeling to drop unnecessary metrics
      metric_relabel_configs:
        - source_labels: [__name__]
          regex: 'go_.*'
          action: drop
```

### Optimize Emby Exporter

```python
# Modifications to emby_exporter.py

# Add caching
CACHE_TTL = 120  # Increase from 60

# Reduce API calls
SCRAPE_INTERVAL = 60  # Increase from 30

# Add connection pooling
self.session = requests.Session()
adapter = requests.adapters.HTTPAdapter(pool_connections=10, pool_maxsize=10)
self.session.mount('http://', adapter)
```

## Emergency Recovery

### Complete Reset

If all else fails, perform a clean reinstall:

```bash
# Stop all services
sudo systemctl stop grafana-agent
sudo systemctl stop emby-exporter

# Backup configuration
cp config/config.env config/config.env.backup

# Remove services
sudo systemctl disable grafana-agent
sudo systemctl disable emby-exporter
sudo rm /etc/systemd/system/grafana-agent.service
sudo rm /etc/systemd/system/emby-exporter.service

# Clean directories
sudo rm -rf /var/lib/grafana-agent
sudo rm -rf /opt/emby-exporter
sudo rm -rf /etc/grafana-agent

# Reinstall
./deploy.sh
```

### Rollback

If issues after update:

```bash
# Restore from backup
git checkout HEAD~1
./deploy.sh

# Or restore specific version
git checkout v1.0.0
./deploy.sh
```

## Getting Help

### Collect Diagnostics

Before requesting help, collect:

```bash
# Create diagnostics archive
mkdir -p /tmp/emby-grafana-diag
cd /tmp/emby-grafana-diag

# Collect info
./scripts/debug.sh > debug-output.txt 2>&1
sudo journalctl -u grafana-agent -n 500 > agent-logs.txt
sudo journalctl -u emby-exporter -n 500 > exporter-logs.txt
cp /etc/grafana-agent/grafana-agent.yaml ./
systemctl status grafana-agent emby-exporter > services-status.txt

# Create archive
tar -czf emby-grafana-diagnostics.tar.gz *
```

### Support Channels

1. **GitHub Issues**: [Project Issues](https://github.com/KingKoopa08/grafana-cloud-emby/issues)
2. **Grafana Community**: [community.grafana.com](https://community.grafana.com)
3. **Emby Forums**: [emby.media/community](https://emby.media/community)

When reporting issues, include:
- Diagnostics archive
- Steps to reproduce
- Expected vs actual behavior
- Environment details (OS, versions)

## Prevention Tips

1. **Regular Updates**: Keep services updated
2. **Monitor Logs**: Set up log alerts for errors
3. **Resource Monitoring**: Track CPU/memory trends
4. **Backup Configuration**: Regular config backups
5. **Test Changes**: Use staging environment for major changes
6. **Document Changes**: Keep changelog of modifications