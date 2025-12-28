# Auto-Discovery Feature

## Overview

The Auto-Discovery feature enables the System Health Monitor to automatically detect, monitor, and heal **unknown components** on any host, not just pre-configured services. This makes the monitoring system truly dynamic and adaptable to any server environment.

## Key Capabilities

### 1. **Universal Component Discovery**

Auto-discovers components through multiple methods:
- **Systemd Services**: All loaded systemd units (excluding system services)
- **Running Processes**: Active processes with intelligent type identification
- **Network Ports**: Listening ports with service fingerprinting
- **Docker Containers**: All containers (running and stopped)
- **Log Files**: Application logs in standard directories
- **Kubernetes Pods**: (when enabled) Container orchestration workloads

### 2. **Component Fingerprinting**

Automatically identifies component types using:
- Port-to-service mapping (80+ common services)
- Process name pattern matching
- Configuration file patterns
- Log file analysis
- Docker image names

Recognized component types:
- Web servers (nginx, apache, etc.)
- Databases (mysql, postgresql, mongodb, etc.)
- Caches (redis, memcached, varnish)
- Message queues (rabbitmq, kafka)
- Application runtimes (node, python, ruby, php-fpm)
- Monitoring tools (prometheus, grafana)
- Mail servers (postfix, dovecot)
- Security tools (fail2ban)
- Container runtimes (docker, containerd, kubernetes)

### 3. **Generic Monitoring**

Monitors discovered components based on type:
- **Systemd services**: Active/inactive status
- **Docker containers**: Running/stopped/failed status
- **Network services**: Port connectivity checks
- **Processes**: PID existence checks
- **Generic fallback**: Process-based monitoring

Each component receives:
- Health status (healthy/unhealthy/unknown)
- Health score (0-100)
- List of issues (if any)
- Timestamp of last check

### 4. **Logrotate Integration**

Automatically:
- Detects log files for each discovered component
- Checks if logrotate configuration exists
- Suggests logrotate configurations for missing ones
- Validates log rotation setup

### 5. **Auto-Healing**

Attempts automatic remediation for unhealthy components:
- **User Prompts**: Always asks for permission before healing (by default)
- **Safe Strategies**: Only performs non-destructive actions
- **Logged Actions**: All healing attempts recorded
- **Type-Specific**: Different healing strategies per component type

Supported healing actions:
- Restart systemd services
- Restart Docker containers
- (Extensible for other component types)

## Usage

### Via health-check.sh

Run auto-discovery with the main health check:

```bash
# Discover and monitor components
./health-check.sh --auto-discover

# Discover, monitor, and auto-heal (with user prompts)
./health-check.sh --auto-discover --auto-heal

# JSON output with discovered components
./health-check.sh --auto-discover --json | jq '.metrics.extended.auto_discovered'
```

### Via component-discovery.sh CLI

Dedicated tool for managing discovered components:

```bash
# Run discovery
./bin/component-discovery.sh discover

# List all discovered components
./bin/component-discovery.sh list

# List in JSON format
./bin/component-discovery.sh list --json

# Monitor all components
./bin/component-discovery.sh monitor

# Show detailed info about a component
./bin/component-discovery.sh show nginx

# Attempt healing for a component
./bin/component-discovery.sh heal redis-server

# Heal all unhealthy components
./bin/component-discovery.sh heal-all

# Check logrotate configuration
./bin/component-discovery.sh logrotate-check

# Suggest logrotate config for a component
./bin/component-discovery.sh logrotate-suggest myapp

# Get discovery statistics
./bin/component-discovery.sh stats

# Export component database
./bin/component-discovery.sh export /tmp/components.json

# Import component database
./bin/component-discovery.sh import /tmp/components.json

# Clean component database
./bin/component-discovery.sh clean
```

## Component Database

Discovered components are cached in:
```
/var/lib/health-check/discovered-components.json
```

This database is updated each time discovery runs and includes:
- Component name
- Component type
- Discovery method used
- Discovery timestamp
- Type-specific metadata (ports, PIDs, paths, etc.)

Cache TTL: 1 hour (configurable)

## Configuration

### Environment Variables

```bash
# Component database location
export COMPONENT_DB="/var/lib/health-check/discovered-components.json"

# Auto-healing settings
export AUTOHEALING_ENABLED=false
export AUTOHEALING_ASK_USER=true
export AUTOHEALING_LOG="/var/log/health-check/autohealing.log"

# Discovery methods (toggle on/off)
export DISCOVERY_SYSTEMD=true
export DISCOVERY_PROCESSES=true
export DISCOVERY_PORTS=true
export DISCOVERY_DOCKER=true
export DISCOVERY_KUBERNETES=false
export DISCOVERY_LOGFILES=true
export DISCOVERY_CONFIGS=true

# Cache TTL
export DISCOVERY_CACHE_TTL=3600  # seconds
```

### Logrotate Directory

Default: `/etc/logrotate.d`

## JSON Output Structure

When auto-discovery is enabled, the JSON output includes:

```json
{
  "metrics": {
    "extended": {
      "auto_discovered": {
        "available": true,
        "component_count": 15,
        "components": [
          {
            "name": "nginx",
            "type": "webserver",
            "discovery_method": "systemd",
            "state": "active",
            "substate": "running",
            "discovered_at": 1234567890,
            "monitoring": {
              "status": "healthy",
              "health_score": 100,
              "issues": [],
              "checked_at": 1234567891
            }
          },
          {
            "name": "redis-server",
            "type": "cache",
            "discovery_method": "port-scan",
            "port": 6379,
            "process": "redis-server",
            "discovered_at": 1234567890,
            "monitoring": {
              "status": "unhealthy",
              "health_score": 0,
              "issues": ["Port 6379 not responding"],
              "checked_at": 1234567891
            }
          }
        ]
      }
    }
  }
}
```

## Examples

### Monitor Unknown Services

```bash
# Discover all components and show unhealthy ones
./bin/component-discovery.sh monitor | jq '.[] | select(.monitoring.status == "unhealthy")'
```

### Find Services Without Logrotate

```bash
# Check logrotate configuration
./bin/component-discovery.sh logrotate-check

# Generate config for missing service
./bin/component-discovery.sh logrotate-suggest myapp > /etc/logrotate.d/myapp
```

### Auto-Heal Failed Services

```bash
# Interactive healing (asks for confirmation)
./bin/component-discovery.sh heal-all

# Programmatic healing
./bin/component-discovery.sh monitor --json | \
    jq -r '.[] | select(.monitoring.status == "unhealthy") | .name' | \
    xargs -I {} ./bin/component-discovery.sh heal {}
```

### Discovery Statistics

```bash
# Get stats in JSON
./bin/component-discovery.sh stats --json

# Human-readable stats
./bin/component-discovery.sh stats
```

Output example:
```
Discovery Statistics:
====================

Total Components: 42

By Type:
  systemd-service: 15
  docker-container: 8
  network-service: 12
  log-file: 7

By Discovery Method:
  systemd: 15
  docker: 8
  port-scan: 12
  logfile-scan: 7
```

## Architecture

### Discovery Flow

```
1. Run Discovery Methods (parallel)
   ├── Scan systemd units
   ├── Enumerate running processes
   ├── Scan listening ports
   ├── List Docker containers
   └── Find log files

2. Fingerprint Components
   ├── Match ports to known services
   ├── Match process names to types
   ├── Identify from config files
   └── Extract metadata

3. Deduplicate & Merge
   ├── Group by component name
   └── Merge data from multiple methods

4. Save to Component Database
   └── /var/lib/health-check/discovered-components.json

5. Monitor Components
   ├── Load from database
   ├── Check health status
   └── Calculate health scores

6. Auto-Heal (if enabled)
   ├── Identify unhealthy components
   ├── Ask user for permission
   ├── Execute healing strategy
   └── Log results
```

### Extensibility

To add custom component types:

1. **Add to fingerprint database** (`lib/auto-discovery.sh`):
```bash
declare -A PROCESS_PATTERNS=(
    ["myapp"]="custom-app-type"
)

declare -A PORT_TO_SERVICE=(
    [8888]="myapp"
)
```

2. **Add monitoring logic**:
```bash
# In monitor_component() function
case "$type" in
    custom-app-type)
        # Custom health check logic
        ;;
esac
```

3. **Add healing strategy**:
```bash
# In attempt_autohealing() function
case "$type" in
    custom-app-type)
        # Custom healing logic
        ;;
esac
```

## Security Considerations

- **No Root Required**: Runs as non-root user with sudo for specific commands
- **User Confirmation**: Auto-healing always asks before taking action (by default)
- **Audit Trail**: All healing attempts logged to `/var/log/health-check/autohealing.log`
- **Safe Defaults**: Discovery methods disabled by default, must opt-in with `--auto-discover`
- **Sandboxed Execution**: All discovery methods timeout-protected
- **No Destructive Actions**: Healing only restarts services, never deletes data

## Troubleshooting

### Discovery not finding components

Check if discovery methods are enabled:
```bash
# View discovered components
./bin/component-discovery.sh list

# Run discovery with verbose logging
DISCOVERY_SYSTEMD=true DISCOVERY_DOCKER=true ./bin/component-discovery.sh discover
```

### Component database permissions

Ensure directory exists and is writable:
```bash
sudo mkdir -p /var/lib/health-check
sudo chown $USER:$USER /var/lib/health-check
```

### Auto-healing not working

Check auto-healing log:
```bash
tail -f /var/log/health-check/autohealing.log
```

Ensure healing is enabled:
```bash
./health-check.sh --auto-discover --auto-heal
```

### False positives in monitoring

Some components may be detected but not actually running. This is expected behavior - the system discovers potential components and monitors their actual status.

## Roadmap

Future enhancements:
- Kubernetes pod discovery
- Cloud provider instance metadata integration
- Custom plugin system for discovery methods
- Machine learning-based component classification
- Dependency graph visualization
- Predictive failure detection
- Integration with configuration management tools (Ansible, Puppet, Chef)

## License

MIT License - See LICENSE file for details

## Support

For issues, feature requests, or questions:
- GitHub Issues: https://github.com/calounx/pmanalysis/issues
- Documentation: https://github.com/calounx/pmanalysis/tree/master/docs
