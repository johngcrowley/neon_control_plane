# Neon Sharding Operations Runbook

## Quick Reference Commands

### Get Bearings - Check Current State
```bash
# View all tenant shard locations and status
curl localhost:9898/v1/location_config | jq

# Check specific tenant location
curl "localhost:9898/v1/tenant/${tenant_id}/locate" | jq

# View pageserver node status
curl localhost:9898/v1/nodes | jq

# Check tenant shard details
curl "localhost:9898/v1/tenant/${tenant_id}" | jq
```

## Understanding Shard Routing Errors

### Why "Wrong Shard Route" Errors Happen
1. **Distributed Shards**: When shards are spread across multiple pageservers, the compute node may send requests to the wrong pageserver
2. **Stale Routing Information**: During migrations or failovers, routing tables become temporarily inconsistent
3. **Race Conditions**: Rapid pageserver restarts can cause temporary routing confusion

### The Fix Pattern You Discovered
When you "spun down PS1 and spun it up, now can read table" - this worked because:
- All shards consolidated onto PS2 during PS1 downtime
- Compute node updated its routing to point to PS2
- When PS1 came back, both shards were accessible from the same pageserver

## Optimal Shard Distribution Strategies

### Recommended Patterns

#### Production Setup (High Availability)
```bash
# Each shard should have primary on different pageserver
# Shard 0: Primary on PS1, Secondary on PS2
# Shard 1: Primary on PS2, Secondary on PS1
```

#### Development/Testing Setup (Simplicity)
```bash
# All shards on single pageserver for predictable routing
# Both Shard 0 and 1: Primary on PS1
```

### Managing Shard Distribution

#### Force All Shards to Single Pageserver (Your Working Pattern)
```bash
# Method 1: Shutdown other pageservers (your approach)
# This forces storage controller to consolidate shards

# Method 2: Explicit shard placement (recommended)
# Set specific placement policy for each shard
curl -X PUT \
  -H "Content-Type: application/json" \
  -d '{
    "mode": "AttachedSingle",
    "tenant_conf": {
      "checkpoint_distance": 8388608,
      "gc_period": "1h",
      "gc_horizon": 67108864,
      "pitr_interval": "7 days"
    },
    "placement_policy": {
      "Primary": "ps1"
    }
  }' \
  "http://localhost:9898/v1/tenant/${tenant_id}/location_config"
```

#### Monitor Shard Redistribution
```bash
# Watch for automatic redistribution
watch "curl -s localhost:9898/v1/location_config | jq '.[] | select(.tenant_id == \"$tenant_id\") | {shard: .shard_number, mode: .mode, pageserver: .generation_pageserver}'"
```

## Time Travel Operations - Proper Procedure

### Critical Requirements
1. **All shards must be completely detached** before time travel
2. **Wait for detachment to complete** across all pageservers
3. **Use correct API endpoint** and image version

### Step-by-Step Time Travel Procedure

#### Step 1: Check Current Attachment Status
```bash
# Verify current shard states
curl "localhost:9898/v1/tenant/${tenant_id}" | jq '.shards[] | {id: .tenant_shard_id, intent: .intent.mode, observed: .observed.locations}'
```

#### Step 2: Detach All Shards
```bash
# For each shard in the tenant
for shard_num in 0001 0002; do
  curl -X PUT \
    -H "Content-Type: application/json" \
    -d '{
      "mode": "Detached",
      "tenant_conf": {
        "checkpoint_distance": 8388608,
        "gc_period": "1h", 
        "gc_horizon": 67108864,
        "pitr_interval": "7 days"
      }
    }' \
    "http://localhost:9898/v1/tenant/${tenant_id}-${shard_num}/location_config"
done
```

#### Step 3: Wait for Complete Detachment
```bash
# Poll until all shards show "Detached" in both intent and observed states
while true; do
  detached_count=$(curl -s "localhost:9898/v1/tenant/${tenant_id}" | jq '.shards[] | select(.intent.mode == "Detached" and (.observed.locations | length) == 0) | .tenant_shard_id' | wc -l)
  total_shards=$(curl -s "localhost:9898/v1/tenant/${tenant_id}" | jq '.shards | length')
  
  if [ "$detached_count" -eq "$total_shards" ]; then
    echo "All shards fully detached"
    break
  fi
  
  echo "Waiting for detachment: $detached_count/$total_shards shards detached"
  sleep 5
done
```

#### Step 4: Execute Time Travel
```bash
# Now safe to perform time travel
curl -X PUT \
  "http://localhost:9898/v1/tenant/${tenant_id}/time_travel_remote_storage?travel_to=2025-09-11T07:00:00Z&done_if_after=2025-09-11T08:15:00Z"
```

#### Step 5: Re-attach Shards After Time Travel
```bash
# Re-attach shards to desired pageservers
for shard_num in 0001 0002; do
  curl -X PUT \
    -H "Content-Type: application/json" \
    -d '{
      "mode": "AttachedSingle",
      "tenant_conf": {
        "checkpoint_distance": 8388608,
        "gc_period": "1h",
        "gc_horizon": 67108864, 
        "pitr_interval": "7 days"
      }
    }' \
    "http://localhost:9898/v1/tenant/${tenant_id}-${shard_num}/location_config"
done
```

## Troubleshooting Common Issues

### Issue 1: "Wrong Shard Route" Errors During Normal Operations

**Symptoms**: 
- Intermittent routing errors during SELECT/INSERT operations
- Errors increase when shards are distributed across pageservers

**Root Cause**: 
- Compute node routing table doesn't match actual shard locations
- Temporary inconsistency during live migrations

**Solutions**:
```bash
# Option A: Consolidate shards to single pageserver (your proven method)
# Bring down PS2, wait for shards to migrate to PS1

# Option B: Force routing table refresh on compute
# Restart compute endpoint to refresh pageserver connections
cargo neon endpoint restart main

# Option C: Wait for automatic reconciliation (30-60 seconds)
# Storage controller will eventually sync routing
```

### Issue 2: "Shard X is greater or equal than number of shards" Error

**Symptoms**: 
- Error during table operations, especially DROP TABLE
- Compute thinks there are fewer shards than actually exist

**Root Cause**: 
- Shard split occurred but compute node wasn't notified
- Inconsistent shard count in compute vs storage controller

**Solution**:
```bash
# Restart compute endpoint to refresh shard configuration
cargo neon endpoint restart main

# Check shard count consistency
curl "localhost:9898/v1/tenant/${tenant_id}" | jq '.shard_count'
```

### Issue 3: Time Travel API Panics

**Symptoms**: 
- `HTTP request handler task panicked` during time travel
- 500 Internal Server Error responses

**Common Causes & Solutions**:
```bash
# Cause 1: Shards still attached
# Solution: Follow proper detachment procedure above

# Cause 2: Wrong image/version
# Solution: Verify using correct Neon build with time travel support

# Cause 3: Invalid timestamp format
# Solution: Use ISO8601 format: 2025-09-11T07:00:00Z

# Cause 4: Missing remote storage configuration
# Solution: Ensure pageservers configured with remote storage backend
```

### Issue 4: Automatic Shard Redistribution

**Symptoms**: 
- Shards automatically move when pageservers restart
- Unexpected shard distribution changes

**Why This Happens**: 
- Storage controller uses intent-based reconciliation
- Automatic load balancing and high availability optimization
- AZ-aware placement policies

**Control Redistribution**:
```bash
# Set explicit placement policies to prevent automatic migration
curl -X PUT \
  -H "Content-Type: application/json" \
  -d '{
    "mode": "AttachedSingle", 
    "placement_policy": {
      "Primary": "ps1"
    }
  }' \
  "http://localhost:9898/v1/tenant/${tenant_id}/location_config"

# Monitor placement decisions
curl localhost:9898/v1/debug/scheduler | jq
```

## Monitoring and Observability

### Key Metrics to Monitor
```bash
# Storage controller reconciliation status
curl localhost:9898/v1/debug/tenant/${tenant_id}/reconcile

# Pageserver health and load
curl localhost:64000/v1/metrics | grep -E "pageserver_tenant_count|pageserver_disk_usage"

# Shard routing errors in compute logs
tail -f .neon/endpoints/main/logs/compute.log | grep -i "wrong shard"
```

### Health Check Script
```bash
#!/bin/bash
# Quick health check for sharded tenant

TENANT_ID="$1"
if [ -z "$TENANT_ID" ]; then
  echo "Usage: $0 <tenant_id>"
  exit 1
fi

echo "=== Tenant Shard Status ==="
curl -s "localhost:9898/v1/tenant/${TENANT_ID}" | jq '.shards[] | {
  shard: .tenant_shard_id,
  intent: .intent.mode,
  observed_locations: (.observed.locations | length),
  generation: .generation
}'

echo -e "\n=== Location Config ==="
curl -s localhost:9898/v1/location_config | jq ".[] | select(.tenant_id == \"$TENANT_ID\")"

echo -e "\n=== Quick Connection Test ==="
psql -h 127.0.0.1 -p 55432 -U cloud_admin postgres -c "\d" > /dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "✓ Compute connection successful"
else
  echo "✗ Compute connection failed - check routing"
fi
```

## Best Practices

### For Development/Testing
1. **Keep shards on single pageserver** to avoid routing complexity
2. **Use explicit placement policies** rather than relying on automatic distribution
3. **Always detach before time travel** operations
4. **Monitor reconciliation status** during configuration changes

### For Production  
1. **Distribute shards across AZs** for high availability
2. **Use secondary replicas** for warm standby
3. **Implement proper monitoring** for routing errors
4. **Plan maintenance windows** for shard migrations

### Common Operational Patterns
```bash
# Development Pattern: All shards on PS1
curl -X PUT "localhost:9898/v1/tenant/${tenant_id}/location_config" -d '{"mode": "AttachedSingle", "placement_policy": {"Primary": "ps1"}}'

# HA Pattern: Distributed with secondaries  
curl -X PUT "localhost:9898/v1/tenant/${tenant_id}/location_config" -d '{"mode": "AttachedMulti", "placement_policy": {"Primary": "ps1", "Secondary": ["ps2"]}}'

# Maintenance Pattern: Drain and fill operations
curl -X POST "localhost:9898/v1/node/ps1/drain"
curl -X POST "localhost:9898/v1/node/ps2/fill"
```

This runbook should help you avoid the routing errors and operational issues you encountered, while providing a systematic approach to managing Neon's sharding system.