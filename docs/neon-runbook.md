# Neon Self-Hosted Consolidated Operations Runbook

## Environment Setup

**Set tenant and connection variables**
```bash
export tenant="99336152a31c64b41034e4e904629ce9"
export timeline="814ce0bd2ae452e11575402e8296b64d"
export storcon_api="http://localhost:1234"
export storcon_dsn="postgresql://postgres:postgres@standalonepg:5432/storage_controller"
export compute_dsn="postgresql://cloud_admin:cloud_admin@compute:55433/postgres"
```

## Quick Infrastructure Startup

### 1. Reset Environment (if needed)

**Clean local state**
```bash
sudo rm -rf .neon/pageserver*/tenants
```

**Clean remote storage buckets**
```bash
gsutil rm -r gs://acrelab-production-us1c-neon/pageserver/
gsutil rm -r gs://acrelab-production-us1c-neon/safekeeper/
```

**Stop containers and remove network**
```bash
docker stop $(docker ps -q --filter network=neon-acres-net) 2>/dev/null || true
docker network rm neon-acres-net 2>/dev/null || true
```

### 2. Start Infrastructure

**Create Docker network**
```bash
docker network create neon-acres-net
```

**Start Storage Controller database**
```bash
docker run --rm --name=standalonepg --network=neon-acres-net -p 5432:5432 \
    -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=storage_controller postgres:16
```

**Start Storage Broker**
```bash
docker run --rm --network=neon-acres-net --name=storage_broker -p 50051:50051 \
    harbor.acreops.org/acrelab/neon:gcs storage_broker --listen-addr=0.0.0.0:50051
```

**Start SafeKeepers (3 for Paxos)**
```bash
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
```

**Start Storage Controller**
```bash
docker run --rm -p 1234:1234 --name storage_controller --network=neon-acres-net \
    harbor.acreops.org/acrelab/neon:gcs storage_controller \
    -l 0.0.0.0:1234 --dev \
    --database-url postgresql://postgres:postgres@standalonepg:5432/storage_controller \
    --max-offline-interval 10s --max-warming-up-interval 30s --control-plane-url http://compute_hook:3000 &
```

**Wait for storage controller startup**
```bash
sleep 5
```

**Register SafeKeepers with storage controller**
```bash
for sk in 1 2 3; do
  curl -X POST localhost:1234/control/v1/safekeeper/${sk} -d "{
    \"id\": ${sk}, \"region_id\": \"us-central\", \"version\": 1, 
    \"host\":\"safekeeper${sk}\", \"port\":5454, \"http_port\":7676, 
    \"availability_zone_id\": \"ps1\"}"
done
```

**Set SafeKeeper scheduling policy**
```bash
for sk in 1 2 3; do
  curl -X POST localhost:1234/control/v1/safekeeper/${sk}/scheduling_policy \
    -d '{"scheduling_policy":"Active"}'
done
```

### 3. Start PageServers

**Start PageServer 1**
```bash
docker run --rm -p 9898:9898 --name=pageserver1 --network=neon-acres-net \
    -v $GOOGLE_APPLICATION_CREDENTIALS:/data/bourdain.json \
    -v ./.neon/pageserver1:/data/.neon/ \
    -e GOOGLE_APPLICATION_CREDENTIALS=/data/bourdain.json \
    harbor.acreops.org/acrelab/neon:gcs pageserver -D /data/.neon &
```

**Start PageServer 2**
```bash
docker run --rm -p 9899:9898 --name=pageserver2 --network=neon-acres-net \
    -v $GOOGLE_APPLICATION_CREDENTIALS:/data/bourdain.json \
    -v ./.neon/pageserver2:/data/.neon/ \
    -e GOOGLE_APPLICATION_CREDENTIALS=/data/bourdain.json \
    harbor.acreops.org/acrelab/neon:gcs pageserver -D /data/.neon &
```

**Wait for PageServer startup**
```bash
sleep 5
```

### 4. Create Tenant and Timeline

**Create tenant with 2 shards and Attached(1) policy**
```bash
curl -X POST $storcon_api/v1/tenant -d '{
  "new_tenant_id": "'$tenant'",
  "shard_parameters": {"count":2, "stripe_size":65558},
  "placement_policy": {"Attached": 1}
}'
```

**Create timeline**
```bash
curl -X POST $storcon_api/v1/tenant/$tenant/timeline -d '{
  "new_timeline_id": "'$timeline'", 
  "pg_version": 16
}'
```

### 5. Start Compute and Hook

**Start Compute Node**
```bash
docker run --network=neon-acres-net --rm -it --name=compute \
    -p 55433:55433 -p 3080:3080 -v ./.neon/compute/:/var/db/postgres/specs/ \
    neondatabase/compute-node-v16 \
    --pgdata /var/db/postgres/compute \
    --connstr "postgresql://cloud_admin@localhost:55433/postgres" \
    --compute-id 1 -b /usr/local/bin/postgres \
    --config /var/db/postgres/specs/config.json &
```

**Start Compute Hook**
```bash
docker run --rm --name=compute_hook -p 3000:3000 --network=neon-acres-net \
    -e storcon_dsn="$storcon_dsn" -e compute_dsn="$compute_dsn" -e RUST_DEBUG=1 \
  harbor.acreops.org/acrelab/compute_hook:latest
```

## Operational Commands

### Diagnostics

**Check shard layout on PageServer 1**
```bash
curl localhost:9898/v1/location_config | jq
```

**Check shard layout on PageServer 2**
```bash
curl localhost:9899/v1/location_config | jq
```

**Check node status**
```bash
curl -X GET $storcon_api/control/v1/node
```

**Check tenant status**
```bash
curl -X GET $storcon_api/v1/tenant/$tenant
```

### Node Management

#### PageServer lifecycle

**Graceful restart PageServer 1 (shards auto-migrate)**
```bash
docker stop pageserver1
```

**Start PageServer 1**
```bash
docker start pageserver1
```

**Drain node before removal**
```bash
curl -X PUT $storcon_api/control/v1/node/1/drain
```

**Delete node after draining**
```bash
curl -X DELETE $storcon_api/control/v1/node/1
```

#### Manual shard migration (rarely needed)
**Note**: With `Attached(1)` policy, storage controller handles migrations automatically. Manual migration only needed for:
- Performance testing
- Emergency rebalancing when automatic migration fails
- Specific placement requirements

**Check current shard placement**
```bash
curl -X GET $storcon_api/control/v1/tenant/$tenant
```
**Migrate specific shard to node 2**
```bash
curl -X PUT $storcon_api/control/v1/tenant/${tenant}-0002/migrate -d '{"node_id":2}'
```

**Force migration if scheduler objects (use with caution)**
```bash
curl -X PUT $storcon_api/control/v1/tenant/${tenant}-0002/migrate -d '{"node_id":2,"migration_config":{"override_scheduler":true}}'
```

## Troubleshooting

### Shard Routing Errors
**Symptoms**: `request routed to wrong shard` errors in pageserver logs, compute connection issues

**Root Cause**: Compute connection string out of sync with actual shard locations

**Solution** (try in order):

**1. Check current shard layout**
```bash
curl -X GET $storcon_api/control/v1/tenant/$tenant | jq '.shards[] | {shard_id, node_attached, node_secondary}'
```

**2. Restart compute hook to refresh connection strings**
```bash
docker restart compute_hook
```

**3. If still broken, restart compute node**
```bash
docker restart compute
```

**Note**: With `Attached(1)` policy, storage controller maintains proper shard distribution automatically. Manual rebalancing should not be needed.

### Table Operations

**Normal DDL Operations** (CREATE TABLE, ALTER, DROP TABLE) work normally with sharded tenants. No special handling required.

**If you encounter DDL issues**:
```bash
# Check tenant status
curl -X GET $storcon_api/control/v1/tenant/$tenant

**Check tenant status**
```bash
curl -X GET $storcon_api/control/v1/tenant/$tenant
```

**Restart compute if connection issues persist**
```bash
docker restart compute
```

### Time Travel / Point-in-Time Recovery

**IMPORTANT**: Always use storage controller API (port 1234), never direct pageserver APIs for time travel.

#### Complete Time Travel Workflow

**0. STOP COMPUTE FIRST! (Required to avoid basebackup conflicts)**
```bash
docker stop compute
```

**1. Detach tenant completely (all shards)**
```bash
curl -X PUT $storcon_api/control/v1/tenant/$tenant/policy -d '{
  "placement": "Detached"
}'
```

**2. Wait for detachment to complete**
```bash
while true; do
  status=$(curl -s $storcon_api/v1/tenant/$tenant | jq -r '.shards[0].policy')
  if [ "$status" = "Detached" ]; then break; fi
  echo "Waiting for detachment..."
  sleep 2
done
```

**3. Perform time travel (specify all historical shard counts)**
- libs/pageserver_api/src/models.rs:1389 (TenantTimeTravelRequest)
- storage_controller/src/service.rs:3500-3516 (shard reconstruction logic)
- test_runner/regress/test_storage_controller.py:1385 (usage example)

```bash
curl -X PUT "$storcon_api/v1/tenant/$tenant/time_travel_remote_storage?travel_to=2025-01-01T12:00:00Z&done_if_after=2025-01-01T13:00:00Z" \
  -H "Content-Type: application/json" \
  -d '{
    "shard_counts": [2]
  }'
```

**4. Reattach tenant (all shards)**
```bash
curl -X PUT $storcon_api/control/v1/tenant/$tenant/policy -d '{
  "placement": {"Attached": 1}
}'
```

**5. Restart pageservers to load post-time-travel timeline state**
```bash
docker restart pageserver1 pageserver2
```

**6. Start compute (will get fresh basebackup from post-time-travel state)**
```bash
docker start compute
```

**WARNING**: Don't go too far back! Must be after init.db.zst creation in pageserver bucket. Check GCS bucket timeline dir to see earliest safe timestamp.

#### Notes
- Storage controller validates all shards are detached before time travel
- Specify all shard counts this tenant has ever used in `shard_counts` array
- Storage controller automatically handles all shard coordination
- Never use direct pageserver APIs (ports 9898/9899) for time travel operations
- **CRITICAL**: Stop compute before time travel to prevent "Timeline not found" basebackup errors
- **CRITICAL**: Don't time travel before timeline initialization - check GCS bucket for init.db.zst timestamp
- Pageservers must be restarted after time travel to reload the new timeline state

### Best Practices

1. **Use Attached(1) policy** - creates warm secondaries and automatic failover
2. **Let storage controller manage placement** - manual migration rarely needed
3. **Use storage controller APIs** - never hit pageserver APIs directly for tenant operations
4. **Clean node removal** - use drain/delete to avoid heartbeat warnings
5. **Time travel through storage controller** - ensures proper shard coordination

### Emergency Recovery

**1. Stop all containers**
```bash
docker stop $(docker ps -q --filter network=neon-acres-net)
```

**2. Restart infrastructure components first**
Follow the "Start Infrastructure" section above to restart:
- Storage Controller database
- Storage Broker  
- SafeKeepers
- Storage Controller

**3. Restart PageServers**
Follow the "Start PageServers" section above

**4. Check shard placement and fix if needed**
```bash
curl -X GET $storcon_api/control/v1/tenant/$tenant
```

**5. Restart compute last**
```bash
docker start compute
```

## Key Insights

- **Attached(1)** creates most robust setup with automatic failover and load balancing
- **Storage controller handles everything** - shard placement, migration, failover
- **Routing errors** = compute connection string out of sync (restart compute_hook)
- **Manual operations rarely needed** - storage controller automates shard management
- **Time travel requires storage controller** - never use direct pageserver APIs
