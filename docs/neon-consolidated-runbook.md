# Neon Self-Hosted Consolidated Operations Runbook

## Environment Setup
```bash
export tenant="99336152a31c64b41034e4e904629ce9"
export timeline="814ce0bd2ae452e11575402e8296b64d"
export storcon_api="http://localhost:1234"
export storcon_dsn="postgresql://postgres:postgres@standalonepg:5432/storage_controller"
export compute_dsn="postgresql://cloud_admin:cloud_admin@compute:55433/postgres"
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

### Node Management

#### PageServer lifecycle
```bash
# Graceful restart: just stop/start container - shards auto-migrate
docker stop pageserver1
docker start pageserver1

# Remove node completely (drain first, then delete)
curl -X PUT $storcon_api/control/v1/node/1/drain
# Wait for shards to migrate away
curl -X DELETE $storcon_api/control/v1/node/1
```

#### Manual shard migration (rarely needed)
**Note**: With `Attached(1)` policy, storage controller handles migrations automatically. Manual migration only needed for:
- Performance testing
- Emergency rebalancing when automatic migration fails
- Specific placement requirements

```bash
# Check current shard placement first
curl -X GET $storcon_api/control/v1/tenant/$tenant

# Migrate specific shard only if needed
curl -X PUT $storcon_api/control/v1/tenant/${tenant}-0002/migrate -d '{"node_id":2}'

# Force migration if scheduler objects (use with caution)
curl -X PUT $storcon_api/control/v1/tenant/${tenant}-0002/migrate -d '{"node_id":2,"migration_config":{"override_scheduler":true}}'
```

## Troubleshooting

### Shard Routing Errors
**Symptoms**: `request routed to wrong shard` errors in pageserver logs, compute connection issues

**Root Cause**: Compute connection string out of sync with actual shard locations

**Solution** (try in order):
```bash
# 1. Check current shard layout
curl -X GET $storcon_api/control/v1/tenant/$tenant | jq '.shards[] | {shard_id, node_attached, node_secondary}'

# 2. Restart compute hook to refresh connection strings
docker restart compute_hook

# 3. If still broken, restart compute node
docker restart compute
```

**Note**: With `Attached(1)` policy, storage controller maintains proper shard distribution automatically. Manual rebalancing should not be needed.

### Table Operations

**Normal DDL Operations** (CREATE TABLE, ALTER, DROP TABLE) work normally with sharded tenants. No special handling required.

**If you encounter DDL issues**:
```bash
# Check tenant status
curl -X GET $storcon_api/control/v1/tenant/$tenant

# Restart compute if connection issues persist
docker restart compute
```

### Time Travel / Point-in-Time Recovery

**IMPORTANT**: Always use storage controller API (port 1234), never direct pageserver APIs for time travel.

#### Complete Time Travel Workflow
```bash
# 1. Detach tenant completely (all shards) -- this worked. Storage controller showed all detaching.
curl -X PUT $storcon_api/control/v1/tenant/$tenant/policy -d '{
  "placement": "Detached"
}'

# 2. Wait for detachment to complete
while true; do
  status=$(curl -s $storcon_api/v1/tenant/$tenant | jq -r '.shards[0].policy')
  if [ "$status" = "Detached" ]; then break; fi
  echo "Waiting for detachment..."
  sleep 2
done

# 3. Time travel (specify all historical shard counts) -- this worked!
# See: libs/pageserver_api/src/models.rs:1389 (TenantTimeTravelRequest)
# See: storage_controller/src/service.rs:3500-3516 (shard reconstruction logic)
# See: test_runner/regress/test_storage_controller.py:1385 (usage example)
curl -X PUT "$storcon_api/v1/tenant/$tenant/time_travel_remote_storage?travel_to=2025-01-01T12:00:00Z&done_if_after=2025-01-01T13:00:00Z" \
  -H "Content-Type: application/json" \
  -d '{
    "shard_counts": [2]
  }'

# 4. Reattach tenant -- this reattaches all in storage controller!
curl -X PUT $storcon_api/control/v1/tenant/$tenant/policy -d '{
  "placement": {"Attached": 1}
}'

# 5. I restarted compute, but it's unable to find the basebackup but pageservers seem happy?

```

#### Notes
- Storage controller validates all shards are detached before time travel
- Specify all shard counts this tenant has ever used in `shard_counts` array
- Storage controller automatically handles all shard coordination
- Never use direct pageserver APIs (ports 9898/9899) for time travel operations

### Best Practices

1. **Use Attached(1) policy** - creates warm secondaries and automatic failover
2. **Let storage controller manage placement** - manual migration rarely needed
3. **Use storage controller APIs** - never hit pageserver APIs directly for tenant operations
4. **Clean node removal** - use drain/delete to avoid heartbeat warnings
5. **Time travel through storage controller** - ensures proper shard coordination

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

- **Attached(1)** creates most robust setup with automatic failover and load balancing
- **Storage controller handles everything** - shard placement, migration, failover
- **Routing errors** = compute connection string out of sync (restart compute_hook)
- **Manual operations rarely needed** - storage controller automates shard management
- **Time travel requires storage controller** - never use direct pageserver APIs
