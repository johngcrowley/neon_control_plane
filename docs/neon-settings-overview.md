# Neon PostgreSQL Architecture and Performance Optimization

## Overview

Neon represents a fundamental reimagining of PostgreSQL for cloud-native environments through disaggregated compute and storage architecture. This guide provides comprehensive technical analysis of Neon's architecture, storage engine mechanics, and optimization strategies for peak performance.

## Architecture Components

### The Disaggregated Model

Neon's architecture separates concerns across three specialized components:

- **Compute Nodes**: Stateless PostgreSQL instances that generate WAL records
- **Safekeepers**: Distributed WAL service using Paxos consensus for durability
- **Pageserver**: Storage backend that processes WAL into versioned, queryable format

### PostgreSQL vs Neon: Architectural Comparison

| Aspect | Traditional PostgreSQL | Neon Architecture |
|--------|----------------------|-------------------|
| **Storage Model** | Overwrite pages in-place | Immutable, versioned layers |
| **WAL Purpose** | Recovery and replication | Primary storage organization |
| **Resource Coupling** | Compute + storage co-located | Disaggregated, independently scalable |
| **Maintenance Operations** | VACUUM required for space reclamation | Compaction optimizes read performance |
| **Checkpoint Behavior** | Flushes dirty pages to disk | Persists WAL to layered format |
| **Historical Data Access** | Requires PITR from base backup + WAL replay | Native time-travel via GetPage@LSN |
| **Scaling Model** | Vertical scaling, complex sharding | Horizontal scaling via tenant sharding |

## Storage Engine: LSN-Based Time Travel

### Log Sequence Number (LSN) as Universal Coordinate

Every WAL record carries a unique LSN, creating a linearized history of all database changes. This enables:

- **Point-in-Time Recovery**: Query any historical state without physical snapshots
- **Instantaneous Branching**: Create new timelines diverging from any historical LSN
- **Time-Travel Queries**: Access data as it existed at any retained point in history

### Layer-Based Storage Architecture

Neon organizes data in immutable files called "layers" in two-dimensional space (key range × LSN range):

#### Delta Layers
- Store incremental changes (WAL records)
- Write-optimized for high-volume ingestion
- Cover specific page and LSN ranges

#### Image Layers
- Store complete page snapshots at specific LSNs
- Read-optimized for efficient GetPage@LSN operations
- Materialized from base image + delta layers

## Data Flow Example: The Alice, Bob, and Charlie Story

### Initial State (LSN 100)
```sql
INSERT INTO users (id, name, city) VALUES (1, 'Alice', 'New York');
```
**Physical State**: Image Layer created at LSN 100

### Alice's Update (LSN 150)
```sql
UPDATE users SET city = 'London' WHERE id = 1;
```
**Physical State**: Delta Layer (100, 150] created alongside Image@100

### Bob's Insertion (LSN 200)
```sql
INSERT INTO users (id, name, city) VALUES (2, 'Bob', 'Paris');
```
**Physical State**: Delta Layer (150, 200] added

### Time-Travel Queries

| Query LSN | Process | Result |
|-----------|---------|---------|
| 120 | Read Image@100 only | Alice in 'New York' |
| 170 | Image@100 + Delta(100,150] | Alice in 'London' |
| 210 | Image@100 + Delta(100,150] + Delta(150,200] | Alice in 'London', Bob in 'Paris' |

## Compaction and Garbage Collection

### Combating Read Amplification

The core challenge in log-structured storage is read amplification—single page reads requiring multiple file accesses. Neon employs tiered compaction:

#### L0 Compaction (Priority)
- Merges small, frequent L0 delta files into larger L1 deltas
- **Critical**: L0 compaction preempts all other background tasks
- Backpressure mechanism throttles ingestion if L0 files exceed ~30

#### L1 Compaction and Image Materialization
- Creates new image layers from old images + L1 deltas
- Establishes efficient baselines for future reads
- Reduces WAL replay requirements

### Garbage Collection Strategy

GC enforces data retention policies based on Point-in-Time Recovery (PiTR) windows:

- **gc_horizon**: Defines PiTR window duration
- **gc_period**: Frequency of obsolete layer cleanup
- Balances historical access vs storage costs

## Performance Optimization

### Neon Cloud: Compute Layer Optimization

#### Compute Units (CUs) and Local File Cache

| CU Size | vCPU | RAM (GB) | LFC Size (GB) | Max Connections |
|---------|------|----------|---------------|-----------------|
| 0.25 | 0.25 | 1 | 0.75 | 112 |
| 1 | 1 | 4 | 3 | 450 |
| 4 | 4 | 16 | 12 | 1802 |
| 8 | 8 | 32 | 24 | 3604 |

**Key Strategy**: Size compute to fit working set in Local File Cache (LFC) for optimal performance.

### Self-Hosted: Pageserver Configuration

#### Critical Parameters

| Parameter | Purpose | Tuning Strategy |
|-----------|---------|-----------------|
| `checkpoint_distance` | WAL volume before flushing to L0 | 256MB-1GB; balance throughput vs Safekeeper capacity |
| `wal_receiver_protocol` | WAL processing mode | "Interpreted/Filtered" for sharded tenants |
| `compaction_target_size` | L1 layer file size | 128MB-512MB; smaller = smoother I/O |
| `gc_horizon` | PiTR window duration | Balance retention needs vs storage costs |

#### Example pageserver.toml Configuration

```toml
# Pageserver global settings
checkpoint_distance = 536870912  # 512MB
checkpoint_timeout = '10m'
wal_receiver_protocol = 'interpreted'
page_cache_size = 134217728  # 128MB

# Compaction settings
compaction_target_size = 268435456  # 256MB

# Garbage collection
gc_horizon = 604800  # 7 days in seconds
gc_period = '1h'
```

### Compute Node (PostgreSQL) Configuration

#### WAL Generation Optimization

| Parameter | Default | Recommended | Impact |
|-----------|---------|-------------|--------|
| `wal_buffers` | 1/32 of shared_buffers | 32-64MB | Batches WAL before streaming |
| `commit_delay` | 0 μs | 50-100 μs | Enables group commit for higher throughput |
| `max_wal_size` | 1GB | 8-16GB | Smooths checkpoint frequency |

#### High-Performance Configuration

```postgresql
-- WAL optimization
SET wal_buffers = '32MB';
SET commit_delay = 50;  -- microseconds
SET max_wal_size = '8GB';
SET min_wal_size = '2GB';

-- Connection efficiency
SET max_connections = 100;  -- Use connection pooling
```

## Production Configuration Profiles

### Maximum Throughput Profile

**Pageserver**:
```toml
checkpoint_distance = 1073741824  # 1GB
wal_receiver_protocol = 'interpreted'
page_cache_size = 268435456  # 256MB
```

**Compute**:
```postgresql
SET wal_buffers = '64MB';
SET commit_delay = 100;
SET max_wal_size = '16GB';
```

### Balanced Latency Profile

**Pageserver**:
```toml
checkpoint_distance = 536870912  # 512MB
wal_receiver_protocol = 'interpreted'
page_cache_size = 134217728  # 128MB
```

**Compute**:
```postgresql
SET wal_buffers = '32MB';
SET commit_delay = 10;
SET max_wal_size = '8GB';
```

## Critical Interdependencies

### Configuration Relationships

1. **Pageserver `checkpoint_distance` ↔ Safekeeper WAL Storage**
   - Larger distances require more Safekeeper capacity
   - Must ensure Safekeeper provisioning supports configuration

2. **`wal_receiver_protocol` Impact**
   - "Interpreted" mode shifts CPU load from Pageserver to Safekeeper
   - Essential for sharded tenant scalability (87.5% reduction in redundant work for 8-shard tenant)

3. **Compute `max_wal_size` ↔ Pageserver `checkpoint_distance`**
   - Compute checkpoints should be less frequent than Pageserver checkpoints
   - Avoid conflicting checkpoint rhythms across layers

## Monitoring Key Metrics

### Pageserver Metrics
- WAL receiver lag (time/LSN difference)
- Open layer size in memory
- Checkpoint frequency and duration
- GetPage@LSN request latency

### Safekeeper Metrics
- Per-timeline WAL queue depth
- CPU utilization (especially with "interpreted" protocol)
- Available disk space for WAL storage

### Compute Metrics
- WAL generation rate (bytes/second)
- Transaction commit latency
- Local File Cache hit rate
- Connection pool utilization

## Architectural Performance Enablers

### Built-in Scalability Features

1. **Tenant Sharding**: Automatic horizontal distribution of large tenants across multiple Pageservers
2. **Sharded Ingest**: Safekeepers route WAL records only to relevant Pageserver shards
3. **WAL Compression**: Zstd compression reduces network bandwidth by ~70%
4. **Parallel Cloud Uploads**: Pipelined local disk writes and S3 uploads maximize throughput

## Best Practices Summary

### For Neon Cloud Users
1. **Size compute appropriately** for working set to fit in LFC
2. **Implement connection pooling** with PgBouncer
3. **Monitor cache hit rates** and scale compute when needed
4. **Apply standard PostgreSQL query optimization** techniques

### For Self-Hosted Operators
1. **Prioritize L0 compaction** through proper `checkpoint_distance` tuning
2. **Use "interpreted" wal_receiver_protocol** for sharded tenants
3. **Balance GC settings** between retention needs and storage costs
4. **Monitor all three component layers** for bottlenecks

### Universal Principles
- **LSN-centric thinking**: Frame all operations in terms of LSN ranges
- **Immutable storage mindset**: Understand append-only implications
- **Disaggregated optimization**: Tune each component for its specialized role
- **Continuous monitoring**: Track metrics across compute, Safekeepers, and Pageserver

---

This architecture enables PostgreSQL to achieve serverless characteristics while maintaining ACID guarantees and providing advanced capabilities like instantaneous branching and deep point-in-time recovery that are fundamental to modern cloud-native database requirements.
