# Neon Self-Hosted Consolidated Operations Runbook

## Environment Setup
```bash
export tenant="99336152a31c64b41034e4e904629ce9"
export timeline="814ce0bd2ae452e11575402e8296b64d"
export storcon_api="http://localhost:1234"
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/your/service-account-key.json"
export storcon_dsn="postgresql://postgres:postgres@standalonepg:5432/storage_controller"
export compute_dsn="postgresql://cloud_admin@compute:55433/postgres"
```

## Quick Infrastructure Startup

### 1. Reset Environment (if needed)
```bash
# Clean local state and remote storage
sudo rm -rf .neon/pageserver*/tenants
gsutil rm -r gs://acrelab-production-us1c-neon/pageserver/
gsutil rm -r gs://acrelab-production-us1c-neon/safekeeper/
docker stop $(docker ps -q --filter network=neon-acres-net) 2>/dev/null || true
docker network rm neon-acres-net 2>/dev/null || true
```

### 2. Start Infrastructure
```bash
# Network
docker network create neon-acres-net

# Storage Controller DB
docker run --rm --name=standalonepg --network=neon-acres-net -p 5432:5432 \
    -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=storage_controller postgres:16 &

# Wait for DB to be ready
sleep 5

# Storage Broker
docker run --rm --network=neon-acres-net --name=storage_broker -p 50051:50051 \
    harbor.acreops.org/acrelab/neon:gcs storage_broker --listen-addr=0.0.0.0:50051 &

# SafeKeepers (3 for Paxos)
for i in 1 2 3; do
    docker run --rm -d --network=neon-acres-net --name=safekeeper$i \
        -v $GOOGLE_APPLICATION_CREDENTIALS:/data/bourdain.json \
        -e GOOGLE_APPLICATION_CREDENTIALS=/data/bourdain.json -p 767$i:7676 \
        harbor.acreops.org/acrelab/neon:gcs safekeeper \
        --id=$i --listen-pg="safekeeper$i:5454" --listen-http='0.0.0.0:7676' \
        --broker-endpoint='http://storage_broker:50051' -D /data \
        --remote-storage='{bucket_name="acrelab-production-us1c-neon",prefix_in_bucket="safekeeper/"}' \
        --enable-offload --delete-offloaded-wal --wal-reader-fanout --peer-recovery=true
done

# Storage Controller
docker run --rm -p 1234:1234 --name storage_controller --network=neon-acres-net \
    harbor.acreops.org/acrelab/neon:gcs storage_controller \
    -l 0.0.0.0:1234 --dev \
    --database-url postgresql://postgres:postgres@standalonepg:5432/storage_controller \
    --max-offline-interval 10s --max-warming-up-interval 30s --control-plane-url http://compute_hook:3000 &

# Wait for storage controller to start
sleep 5

# Register SafeKeepers
for sk in 1 2 3; do
  curl -X POST localhost:1234/control/v1/safekeeper/${sk} -d "{
    \"id\": ${sk}, \"region_id\": \"us-central\", \"version\": 1, 
    \"host\":\"safekeeper${sk}\", \"port\":5454, \"http_port\":7676, 
    \"availability_zone_id\": \"ps1\"}"
done	

for sk in 1 2 3; do
  curl -X POST localhost:1234/control/v1/safekeeper/${sk}/scheduling_policy \
    -d '{"scheduling_policy":"Active"}'
done
```

### 3. Start PageServers
```bash
# PageServer 1
docker run --rm -p 9898:9898 --name=pageserver1 --network=neon-acres-net \
    -v $GOOGLE_APPLICATION_CREDENTIALS:/data/bourdain.json \
    -v ./.neon/pageserver1:/data/.neon/ \
    -e GOOGLE_APPLICATION_CREDENTIALS=/data/bourdain.json \
    harbor.acreops.org/acrelab/neon:gcs pageserver -D /data/.neon &

# PageServer 2  
docker run --rm -p 9899:9898 --name=pageserver2 --network=neon-acres-net \
    -v $GOOGLE_APPLICATION_CREDENTIALS:/data/bourdain.json \
    -v ./.neon/pageserver2:/data/.neon/ \
    -e GOOGLE_APPLICATION_CREDENTIALS=/data/bourdain.json \
    harbor.acreops.org/acrelab/neon:gcs pageserver -D /data/.neon &

sleep 5
```

### 4. Create Tenant and Timeline
```bash
# Create tenant with 2 shards, Attached(1) policy (recommended)
curl -X POST $storcon_api/v1/tenant -d '{
  "new_tenant_id": "'$tenant'",
  "shard_parameters": {"count":2, "stripe_size":65558},
  "placement_policy": {"Attached": 1}
}'

# Create timeline
curl -X POST $storcon_api/v1/tenant/$tenant/timeline -d '{
  "new_timeline_id": "'$timeline'", 
  "pg_version": 16
}'
```

### 5. Start Compute and Hook
```bash
# Compute Node
docker run --network=neon-acres-net --rm -it --name=compute \
    -p 55433:55433 -p 3080:3080 -v ./.neon/compute/:/var/db/postgres/specs/ \
    neondatabase/compute-node-v16 \
    --pgdata /var/db/postgres/compute \
    --connstr "postgresql://cloud_admin@localhost:55433/postgres" \
    --compute-id 1 -b /usr/local/bin/postgres \
    --config /var/db/postgres/specs/config.json &

# Compute Hook  
docker run --rm --name=compute_hook -p 3000:3000 --network=neon-acres-net \
    -e storcon_dsn="$storcon_dsn" -e compute_dsn="$compute_dsn" \
    harbor.acreops.org/acrelab/neon:gcs ctrl_plane_self_hosted &
```

## Operational Commands

### Diagnostics
```bash
# Check shard layout
curl localhost:9898/v1/location_config | jq
curl localhost:9899/v1/location_config | jq

# Check node status
curl -X GET $storcon_api/control/v1/node

# Check tenant status
curl -X GET $storcon_api/v1/tenant/$tenant
```

### Shard Management

#### Manual shard migration (when needed)
```bash
# Migrate shard 0002 to node 2 (pageserver2)
curl -X PUT $storcon_api/control/v1/tenant/${tenant}-0002/migrate -d '{"node_id":2}'

# Force migration if scheduler objects
curl -X PUT $storcon_api/control/v1/tenant/${tenant}-0002/migrate -d '{"node_id":2,"migration_config":{"override_scheduler":true}}'

# Trigger node to accept migrations (if auto-migration stuck)
curl -X PUT $storcon_api/control/v1/node/2/fill
```

#### PageServer lifecycle
```bash
# Graceful restart: just stop/start container - shards auto-migrate
docker stop pageserver1
docker start pageserver1

# Remove node completely
curl -X PUT $storcon_api/control/v1/node/1/drain
curl -X DELETE $storcon_api/control/v1/node/1
```

## Troubleshooting

### Shard Routing Errors
**Symptoms**: `request routed to wrong shard` errors in pageserver logs, compute connection issues

**Common Causes**:
1. **Compute connection string out of sync** with actual shard locations
2. **Shard migration in progress** - temporary routing confusion
3. **Unbalanced shard placement** - both shards on one pageserver while compute expects distribution

**Solutions**:
```bash
# 1. Check current shard layout vs compute config
curl localhost:9898/v1/location_config | jq
curl localhost:9899/v1/location_config | jq
# Compare with compute config.json pageserver_connstring

# 2. Force compute hook to update connection string
# (restart compute hook service to trigger refresh)
docker restart compute_hook

# 3. If shards unbalanced, migrate one shard to balance
curl -X PUT $storcon_api/control/v1/tenant/${tenant}-0002/migrate -d '{"node_id":2}'

# 4. Nuclear option: restart compute node to pick up new connection string
docker restart compute
```

### Table Operations and Shard Consistency

**DDL Operations** (DROP TABLE, ALTER, etc.) can cause routing errors:
- DDL operations need to coordinate across all shards
- If shards are on different pageservers during DDL, routing can break
- **Solution**: Ensure both shards on same pageserver before DDL:
  
```bash
# Move both shards to pageserver1 before DDL
curl -X PUT $storcon_api/control/v1/tenant/${tenant}-0001/migrate -d '{"node_id":1}'
curl -X PUT $storcon_api/control/v1/tenant/${tenant}-0002/migrate -d '{"node_id":1}'

# Wait for migration complete, then do DDL operations
# After DDL, can rebalance if needed
```

### Time Travel / Point-in-Time Recovery

**Important**: Use correct image for time travel operations. Some operations require specific Neon image builds.

**Critical Issues with Detach/Reattach**:
- Hitting individual PageServer `/location_config` endpoints (9898, 9899) can cause PS/compute coordination issues
- Multiple detach attempts can put pageserver and compute in conflicting states
- Proper detach/reattach coordination through storage_controller may be required

#### Experimental Time Travel Workflow (NEEDS REFINEMENT)
```bash
# Example: Current time is 23:44 CST (05:44 UTC), traveling back 15 minutes
export tenant_id="$tenant"

# Step 1: Detach all shards (WARNING: Direct PS API may cause issues)
for shard_id in $(curl -s "http://localhost:9898/v1/tenant/${tenant_id}" | jq -r '.shards[].tenant_shard_id'); do
  curl -X PUT -H "Content-Type: application/json" -d '{
    "mode": "Detached",
    "tenant_conf": {}
  }' "http://localhost:9898/v1/tenant/${shard_id}/location_config"
done

# Step 2: Time travel (gets 200 OK with version/delete output)
curl -X PUT \
  "http://localhost:9898/v1/tenant/${tenant_id}/time_travel_remote_storage?travel_to=2025-09-12T05:29:00Z&done_if_after=2025-09-12T05:44:00Z"

# Step 3: Reattach (METHOD UNCLEAR - may need storage_controller coordination)
# ISSUE: Multiple detach attempts cause PS1/compute sync problems
```

#### Research Needed
- **Proper detach method**: Should detach go through storage_controller API instead of direct PageServer?
- **Reattach coordination**: How to properly reattach without PS/compute conflicts?
- **Shard coordination**: Does time travel need all shards detached from all PageServers?

#### Working Observations
- Time travel API returns 200 OK with expected version/delete output when hitting single PageServer
- Direct PageServer `/location_config` calls can destabilize PS/compute coordination
- Multiple detach operations cause "fritz" between PageServer and compute

#### Manual Per-Shard Time Travel (Use with caution)
```bash
# Detach single shard (WARNING: may cause coordination issues)
curl -X PUT -H "Content-Type: application/json" -d '{
  "mode": "Detached",
  "tenant_conf": {}
}' http://localhost:9898/v1/tenant/${tenant}-0001/location_config

# Time travel operation (this part works)
curl -X PUT "http://localhost:9898/v1/tenant/${tenant}/time_travel_remote_storage?travel_to=2025-09-12T05:29:00Z&done_if_after=2025-09-12T05:44:00Z"

# Reattach method TBD - avoid multiple detach attempts
```

### Best Practices

1. **Use Attached(1) policy** - creates warm secondaries automatically
2. **Monitor shard distribution** - uneven distribution causes routing errors  
3. **Coordinate DDL operations** - ensure shards co-located during schema changes
4. **Let auto-migration work** - manual intervention usually not needed
5. **Clean node removal** - use drain/delete to avoid heartbeat warnings

### Emergency Recovery
```bash
# If everything breaks, restart in this order:
# 1. Stop all containers
docker stop $(docker ps -q --filter network=neon-acres-net)

# 2. Restart infrastructure (DB, broker, controller first)
# 3. Restart pageservers
# 4. Check shard placement and fix if needed
# 5. Restart compute last
```

## Key Insights

- **Heatmaps** enable automatic shard migration - generated during normal operation
- **Attached(1)** creates most robust setup with automatic failover
- **Routing errors** often indicate compute/pageserver connection string mismatch
- **DDL operations** require careful shard coordination to avoid errors
- **Manual migration** rarely needed with proper placement policy