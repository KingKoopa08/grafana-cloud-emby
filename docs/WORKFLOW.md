# Git-Based Workflow Guide

This document explains how to manage your Grafana Cloud Emby monitoring setup using Git for version control and deployment.

## Overview

The workflow follows a GitOps approach:
1. **Development**: Make changes locally or in a development environment
2. **Commit**: Push changes to GitHub
3. **Deploy**: Pull changes on the production Emby server
4. **Update**: Apply configuration and service updates

## Initial Setup

### 1. Fork/Create Repository

1. Fork or create the repository on GitHub
2. Update repository URL in these files:
   - `setup.sh` - Line with `GITHUB_REPO`
   - `deploy.sh` - Line with `GITHUB_REPO`
   - `README.md` - Update all GitHub URLs

### 2. First Deployment

On your Emby server (15.204.198.42):

```bash
# Quick install
curl -sSL https://raw.githubusercontent.com/KingKoopa08/grafana-cloud-emby/main/setup.sh | bash

# Or manual install
git clone https://github.com/KingKoopa08/grafana-cloud-emby.git /opt/grafana-cloud-emby
cd /opt/grafana-cloud-emby
./deploy.sh
```

### 3. Configure Secrets

```bash
cd /opt/grafana-cloud-emby
cp config/config.env.example config/config.env
nano config/config.env  # Add your API keys
```

**Important**: The `config.env` file is gitignored and stays local to the server.

## Daily Workflow

### Making Changes

#### Local Development

1. Clone repository locally:
```bash
git clone https://github.com/KingKoopa08/grafana-cloud-emby.git
cd grafana-cloud-emby
```

2. Make your changes:
```bash
# Edit exporter
nano exporters/emby_exporter.py

# Update dashboards
nano dashboards/emby-overview.json

# Modify configuration templates
nano config/grafana-agent.yaml
```

3. Test changes (if possible):
```bash
# Test Python syntax
python3 -m py_compile exporters/emby_exporter.py

# Validate YAML
yamllint config/grafana-agent.yaml
```

4. Commit and push:
```bash
git add .
git commit -m "feat: Add new metrics for transcoding quality"
git push origin main
```

### Deploying Changes

On the Emby server:

```bash
cd /opt/grafana-cloud-emby

# Pull and apply updates
./update.sh

# Or use Make
make update
```

The update script will:
- Check for uncommitted local changes
- Backup current configuration
- Pull latest changes from GitHub
- Restore configuration (API keys)
- Update services if needed
- Restart affected services
- Run verification

### Configuration Management

#### Updating Configuration Templates

1. Edit template locally:
```bash
nano config/config.env.example
```

2. Commit and push:
```bash
git add config/config.env.example
git commit -m "config: Add new configuration option"
git push
```

3. On server, after pulling:
```bash
# Compare with current config
diff config/config.env.example config/config.env

# Manually add new options to config.env
nano config/config.env
```

#### Changing Grafana Agent Configuration

1. Edit locally:
```bash
nano config/grafana-agent.yaml
```

2. Push changes:
```bash
git add config/grafana-agent.yaml
git commit -m "config: Increase scrape interval to reduce load"
git push
```

3. Deploy:
```bash
# On server
cd /opt/grafana-cloud-emby
./update.sh  # Will automatically update and restart agent
```

## Advanced Workflows

### Feature Branches

For major changes, use feature branches:

```bash
# Create feature branch
git checkout -b feature/add-plex-support

# Make changes
# ...

# Push branch
git push origin feature/add-plex-support

# On server, test feature
cd /opt/grafana-cloud-emby
git fetch
git checkout feature/add-plex-support
./deploy.sh

# After testing, merge to main
git checkout main
git merge feature/add-plex-support
git push origin main
```

### Rolling Back Changes

If an update causes issues:

```bash
# View recent commits
git log --oneline -10

# Rollback to specific commit
git checkout <commit-hash>
./deploy.sh

# Or rollback to previous commit
git checkout HEAD~1
./deploy.sh
```

### Emergency Recovery

If the deployment is broken:

```bash
# Reset to last known good state
cd /opt/grafana-cloud-emby
git fetch origin
git reset --hard origin/main

# Restore configuration
cp backups/config.env.$(ls -t backups/ | head -1) config/config.env

# Redeploy
./deploy.sh
```

## Dashboard Development

### Workflow for Dashboard Changes

1. **Export from Grafana Cloud** (if modifying existing):
   - In Grafana: Dashboard > Settings > JSON Model
   - Copy JSON

2. **Edit locally**:
```bash
# Save to appropriate file
nano dashboards/emby-overview.json

# Format JSON
python3 -m json.tool dashboards/emby-overview.json > temp.json
mv temp.json dashboards/emby-overview.json
```

3. **Commit and push**:
```bash
git add dashboards/
git commit -m "dashboard: Add bandwidth by user panel"
git push
```

4. **Import to Grafana Cloud**:
   - Pull changes on server: `./update.sh`
   - In Grafana: Dashboards > Import
   - Upload updated JSON file

### Dashboard Version Control

Keep dashboard versions in sync:

```bash
# Create dashboard versions directory
mkdir -p dashboards/versions

# Save versions with timestamps
cp dashboards/emby-overview.json \
   dashboards/versions/emby-overview-$(date +%Y%m%d).json

git add dashboards/versions/
git commit -m "dashboard: Archive version $(date +%Y%m%d)"
```

## Automation

### GitHub Actions (Optional)

Create `.github/workflows/validate.yml`:

```yaml
name: Validate

on: [push, pull_request]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v2
    
    - name: Validate Python
      run: |
        python3 -m py_compile exporters/emby_exporter.py
    
    - name: Check JSON
      run: |
        for file in dashboards/*.json; do
          python3 -m json.tool "$file" > /dev/null
        done
    
    - name: Validate YAML
      run: |
        pip install yamllint
        yamllint config/grafana-agent.yaml
```

### Automated Deployment

Set up webhook or cron job on server:

```bash
# Add to crontab for hourly updates
0 * * * * cd /opt/grafana-cloud-emby && ./update.sh >> /var/log/grafana-cloud-update.log 2>&1
```

## Best Practices

### 1. Commit Messages

Use conventional commits:
- `feat:` New features
- `fix:` Bug fixes
- `docs:` Documentation changes
- `config:` Configuration changes
- `refactor:` Code refactoring
- `test:` Test additions
- `chore:` Maintenance tasks

### 2. Testing Changes

Always test before deploying:
```bash
# Dry run on server
cd /opt/grafana-cloud-emby
git fetch
git diff origin/main  # Review changes
```

### 3. Configuration Backup

Before major updates:
```bash
make backup
# or
cp config/config.env backups/config.env.$(date +%Y%m%d-%H%M%S)
```

### 4. Documentation

Update documentation with changes:
- Update README.md for user-facing changes
- Update TROUBLESHOOTING.md for new issues/solutions
- Add inline comments for complex code

### 5. Security

- Never commit secrets (API keys, passwords)
- Keep `config.env` in .gitignore
- Use environment variables for sensitive data
- Regularly rotate API keys

## Troubleshooting Workflow Issues

### Git Conflicts

If you have local changes that conflict:

```bash
# Stash local changes
git stash

# Pull remote changes
git pull origin main

# Apply local changes
git stash pop

# Resolve conflicts manually
nano <conflicted-file>
git add .
git commit -m "Merge local changes"
```

### Permission Issues

If Git operations fail due to permissions:

```bash
# Fix ownership
sudo chown -R $USER:$USER /opt/grafana-cloud-emby

# Fix permissions
find /opt/grafana-cloud-emby -type d -exec chmod 755 {} \;
find /opt/grafana-cloud-emby -type f -exec chmod 644 {} \;
chmod +x *.sh scripts/*.sh
```

### Repository Sync Issues

If repository is out of sync:

```bash
# Check remote URL
git remote -v

# Update remote if needed
git remote set-url origin https://github.com/KingKoopa08/grafana-cloud-emby.git

# Force sync with remote
git fetch origin
git reset --hard origin/main
```

## Collaboration

### Working with Others

1. **Use Pull Requests** for major changes
2. **Document changes** in commit messages and PR descriptions
3. **Test on dev server** before merging to main
4. **Tag releases** for production deployments:

```bash
git tag -a v1.0.0 -m "Initial production release"
git push origin v1.0.0
```

### Code Review Checklist

Before merging changes:
- [ ] Python code is syntactically correct
- [ ] YAML/JSON files are valid
- [ ] No secrets in committed files
- [ ] Documentation updated if needed
- [ ] Tested on development environment
- [ ] Version bumped if significant change