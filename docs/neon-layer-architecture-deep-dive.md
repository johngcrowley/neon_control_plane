# Neon Layer Architecture Deep Dive

## Executive Summary

Neon transforms PostgreSQL into a cloud-native database through disaggregated storage using immutable layers. This guide covers layer architecture, compaction mechanics, and performance optimization.

## Foundation: PostgreSQL Pages in Neon's Layer System

**Key Insight**: Neon preserves PostgreSQL's `(relation, block)` page identification while adding LSN-based time travel.

**Mapping**: `users` table (relation 16384) pages → Keys: `rel_16384_blk_0`, `rel_16384_blk_1`, etc.
**Time dimension**: Each key exists at multiple LSNs for historical access

### Why L0 Layers Create Read Amplification

**L0 "all pages"** = all tables in database:
```
L0 Layer: users + orders + products + indexes (everything)
Query users → must scan layers containing mostly irrelevant data
Read amplification: 10x+ due to unrelated table data
```

**WAL → Layer Flow**:
```sql
UPDATE users SET balance = 1000 WHERE id = 42;
-- Generates WAL → Key: rel_16384_blk_5 → Stored in delta layer
```

## Core Architecture: L0, L1, and Image Layers

### Layer Types

**L0 (Ingestion)**: All tables, specific LSN ranges
- Generated every 256MB of WAL
- Problem: Every read searches ALL L0 layers

**L1 Delta**: Specific table page ranges, compacted from L0
- Benefit: Skip irrelevant tables during reads

**L1 Image**: Materialized pages at specific LSN
- Benefit: Instant access, no reconstruction needed

**Layer Stack**:
```
L1 Delta:    |  users@2000-2100  | |orders@1900-2050|
L1 Images:   |  users@1800       | |orders@1700     |
```

## Two-Phase Compaction

**L0→L1 (Reorganization)**:
- Input: 10-20 L0 layers
- Process: Merge-sort by `(page, LSN)`, write 128MB chunks
- Key insight: Page boundaries emerge from actual write density
- Output: L1 deltas organized by table ranges

**L1 Image Compaction (Materialization)**:
- Trigger: 3+ delta layers overlap image layers (`image_creation_threshold`)
- Process: Reconstruct pages at specific LSN, write image layers
- Benefit: Future reads stop at image layer

## GetPage@LSN Request Lifecycle: Complete Journey

### The Multi-Tier Cache and IO Architecture

**Cache Hierarchy (Fastest → Slowest)**:
1. **shared_buffers** (PostgreSQL buffer pool) - nanosecond access
2. **Local File Cache (LFC)** - microsecond access, 75% of compute RAM
3. **Pageserver cache** (`page_cache_size`) - millisecond network + cache lookup
4. **Layer reconstruction** - millisecond network + disk IO + reconstruction

### Step-by-Step Request Flow

**1. Compute-Side Processing**
```sql
SELECT * FROM users WHERE id = 42;  -- Needs page rel_16384_blk_5
```
- **shared_buffers check**: PostgreSQL's standard buffer pool (instant if hit)
- **LFC check**: Local File Cache lookup (microseconds if hit)
- **Cache miss**: Triggers GetPage@LSN(rel_16384_blk_5, current_LSN) to pageserver

**2. Network Request Batching**
- **Spatial locality**: Group requests by overlapping layers
- **Temporal locality**: Group requests by target LSN
- **Connection limit**: `max_connections = 100` (use connection pooling)

**3. Pageserver Processing**
- **Page cache lookup**: Check `page_cache_size` (128MB-1GB) for reconstructed page
- **Cache hit**: Return cached page (milliseconds)
- **Cache miss**: Trigger layer reconstruction

**4. Layer Discovery and Vectored Reads**
```
Target: page rel_16384_blk_5 @ LSN 2000

Layer stack scan:
├── L1 Delta: rel_16384_blk_0-100 @ LSN 1800-2100 ✓
├── L1 Delta: rel_16384_blk_0-50 @ LSN 1500-1799 ✓
└── Image: rel_16384_blk_0-50 @ LSN 1500 ✓ (base image)
```

**5. Concurrent Layer Reconstruction**
- **Vectored reads**: Parallel access to image layer + relevant delta layers
- **Concurrency**: `CONCURRENT_BACKGROUND_TASKS = 12` (1.5x CPU cores)
- **WAL extraction**: Parse records from delta layers, sort by LSN
- **Sequential replay**: Apply WAL records in order to base image
- **Result**: Complete 8KB PostgreSQL page

**6. Response and Cache Population**
- **Pageserver cache**: Store reconstructed page in `page_cache_size`
- **Network return**: Send 8KB page to compute
- **LFC population**: Cache in Local File Cache (75% of compute RAM)
- **shared_buffers**: PostgreSQL loads page normally

**Performance Impact**:
```toml
# Pageserver concurrency
CONCURRENT_BACKGROUND_TASKS = 12    # 1.5x CPU cores
page_cache_size = 1073741824        # 1GB

# Compute caching
max_connections = 100               # Use pooling
# LFC = 75% RAM (automatic)
```

**Read Amplification**:
- L0: 10x+ (scan all tables)
- L1 + Images: 1.5x (targeted access)

Aggressive image creation (`image_creation_threshold = 1`) minimizes reconstruction work.

## Sharding Benefits

**8 shards = 8x parallelization**:
- Each shard: 1/8th write volume → fewer layers
- Parallel I/O and compaction across pageservers
- Better cache locality per shard

**Optimal**: 8-16 shards for large tenants

## Performance Optimization

**Maximum Performance Settings**:
```toml
# Concurrency
CONCURRENT_BACKGROUND_TASKS = 12        # 1.5x CPU cores
CONCURRENT_L0_COMPACTION_TASKS = 12

# Aggressive compaction
compaction_threshold = 8                # Earlier L0→L1 (vs 10)
image_creation_threshold = 1            # Ultra-aggressive images (vs 3)
compaction_period = 10                  # More frequent (vs 20s)

# Sharded tenants
wal_receiver_protocol = 'interpreted'   # 87.5% CPU reduction
```

**Strategy**: Minimize L0 layers, maximize image layers. Monitor L0 count < 10.

## Key Insights

**Data-Driven Partitioning**: L0→L1 sorts by `(page, LSN)`. Hot tables get narrow page ranges, cold tables get wide ranges. Boundaries emerge from actual write patterns.

**Layer Navigation**: Start from newest layers, skip by page range, stop at first image layer.

## Best Practices

**Maximum Performance**:
- 8+ shards, `image_creation_threshold = 1`, aggressive L0 compaction
- Interpreted WAL for sharded tenants

**Balanced**:
- 4-8 shards, `image_creation_threshold = 3-4`, monitor layer depth

**Universal Principles**:
- L0 layers are the enemy of read performance
- Images stop layer traversal early
- Sharding multiplies all benefits

This architecture enables cloud-native PostgreSQL with ACID guarantees, instant branching, and time-travel queries.
