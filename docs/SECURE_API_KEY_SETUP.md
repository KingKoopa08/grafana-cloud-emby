# Secure API Key Setup

## Important: Never Commit API Keys to Git

API keys should NEVER be hardcoded in scripts or committed to version control. This guide shows how to securely configure your Grafana Cloud API keys.

## Setup Instructions

### 1. Create Your Config File

Copy the example configuration:
```bash
cd /opt/grafana-cloud-emby
cp config/config.env.example config/config.env
```

### 2. Add Your API Keys

Edit `config/config.env` with your actual values:
```bash
nano config/config.env
```

Add your keys:
```bash
# Your Grafana Cloud User ID
GRAFANA_CLOUD_USER=2607589

# API Key with metrics:write permission
GRAFANA_CLOUD_API_KEY=your-metrics-api-key-here

# API Key with logs:write permission (can be same as above if it has both)
GRAFANA_CLOUD_LOGS_API_KEY=your-logs-api-key-here

# Your Prometheus endpoint
GRAFANA_CLOUD_PROMETHEUS_URL=https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/push
```

### 3. Secure the Config File

Set proper permissions:
```bash
chmod 600 config/config.env
sudo chown root:root config/config.env
```

### 4. Add to .gitignore

Ensure config.env is never committed:
```bash
echo "config/config.env" >> .gitignore
echo "*.env" >> .gitignore
git add .gitignore
git commit -m "Add config.env to gitignore"
```

## For the Logs API Key

When you created your new API key with logs:write permission, add it to your config:

```bash
# Edit the config file
sudo nano /opt/grafana-cloud-emby/config/config.env

# Add this line (replace with your actual key):
GRAFANA_CLOUD_LOGS_API_KEY=glc_eyJv...your-key-here...
```

Then run the setup script:
```bash
sudo ./scripts/add-logs-with-new-key.sh
```

## Security Best Practices

1. **Never hardcode keys** in scripts
2. **Use environment variables** or config files
3. **Add config files to .gitignore**
4. **Set restrictive file permissions** (600 or 400)
5. **Use separate keys** for different services when possible
6. **Rotate keys regularly**
7. **Monitor for unauthorized access**

## If You Accidentally Commit a Key

1. **Immediately revoke the key** in Grafana Cloud
2. **Create a new key**
3. **Remove from git history**:
   ```bash
   git filter-branch --force --index-filter \
     "git rm --cached --ignore-unmatch path/to/file" \
     --prune-empty --tag-name-filter cat -- --all
   ```
4. **Force push** (coordinate with team):
   ```bash
   git push origin --force --all
   ```
5. **Update all systems** with the new key

## Environment Variable Alternative

Instead of a config file, you can use environment variables:

```bash
# Add to /etc/environment or ~/.bashrc
export GRAFANA_CLOUD_USER=2607589
export GRAFANA_CLOUD_API_KEY=your-key-here
export GRAFANA_CLOUD_LOGS_API_KEY=your-logs-key-here

# Then run scripts normally
sudo -E ./scripts/add-logs-with-new-key.sh
```

## Checking Current Configuration

To verify your configuration without exposing keys:
```bash
# Check if keys are set
grep -c "GRAFANA_CLOUD" config/config.env

# Test authentication (without showing key)
./scripts/test-logs-flow.sh
```

Remember: GitHub and other platforms scan for exposed secrets. Always keep your API keys secure!