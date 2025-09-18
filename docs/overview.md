# Neon Layer Architecture Deep Dive

## Executive Summary

Neon transforms PostgreSQL into a cloud-native database through disaggregated storage using immutable layers. This guide covers layer architecture, compaction mechanics, and performance optimization.

## Foundation: PostgreSQL Pages in Neon's Layer System

**Key Insight**: Neon preserves PostgreSQL's `(relation, block)` page identification while adding LSN-based time travel.

### The Russian Doll Architecture: PostgreSQL Storage Hierarchy

**PostgreSQL's Nested Storage Structure**:
```
-- DB
--- Table           : a table is comprised of 1 GB files
------ File         : a file is comprised of 8 KB pages
-------- Page       : a page is comprised of rows and looks like:
----------- Row

Page:      [ Header | Row pointer | FREE SPACE | Row1 | Row2 | etc... ]
Row:       [ Header | Field 1 | ... | Field N ]
```

**Page Header** = contains "page LSN", the next byte after last byte of WAL record for last change to this page. Basically a pointer to the WAL log that says "this change updated this page". During a CHECKPOINT, when the page is written to disk (updating the actual files), the "page LSN" must be <= the "flushed LSN", i.e., the last change that we have already put into the disk. It also contains Row pointers to make looking up a particular row faster.

**Row Header** = contains the transaction ids for MVCC and the "hint bits" described above. These "hint bits" are basically a 1 or a 0 if the transaction was committed or not. These hints exist to save PostgreSQL the round trip of going to the commit log per row per query.

**Neon's Transformation of This Architecture**:
- **Database → Timeline**: Each database becomes a timeline with complete history
- **Table → Key Space**: Each table becomes a range of keys in format `rel_<db>_<table>_blk_<page>`
- **File → Layer**: 1GB files become variable-sized layers (delta and image)
- **Page → Reconstructed State**: 8KB pages reconstructed from WAL history at any LSN
- **Row → Time-Aware Tuple**: Rows exist at specific LSNs with complete historical visibility

## Research-Based Corrections and Deep Dive Expansions

### Critical Misconception Corrected: "L0 Contains All Tables"

**Previous Understanding**: L0 layers contain "all tables in database"
**Research Finding**: L0 layers contain only **modified pages** from active tables during their LSN range

**Evidence from Neon codebase investigation**:
- WAL ingestion processes only modified pages: "parses WAL records to determine which pages they apply to"
- Delta layers contain only updates: "If a key has not been modified, there is no trace of it in the delta layer"
- L0 "all keys" means potential coverage, not actual data presence

### Key Format Implementation Details

**Binary vs Human-Readable Formats**:
```rust
// Internal binary format (libs/pageserver_api/src/key.rs)
pub struct Key {
    pub field1: u8,      // Key type/namespace
    pub field2: u32,     // Component 1
    pub field3: u32,     // Component 2
    pub field4: u32,     // Component 3
    pub field5: u8,      // Component 4
    pub field6: u32,     // Component 5
}

// Conversion functions (pgdatadir_mapping.rs)
rel_block_to_key(rel: RelTag, blknum: BlockNumber) -> Key
```

**Layer File Naming Examples**:
```
000000000000000003E8-000000000000000FA0__rel_12345_16384_blk_0-5__delta
000000000000000FA0__rel_12345_16384_blk_0-5__image
Format: [LSN_range]__[human_readable_key_range]__[layer_type]
```

### Large Table vs Many Tables: L0 Layer Reality

**DISPROVEN CLAIM**: "L0 layers spanning many pages means many tables"

**Research Evidence**:
- Single PostgreSQL table can span 50,000+ pages (1GB+ table size)
- Bulk operations on large tables generate thousands of page modifications
- L0 layer with "many pages" can be dominated by ONE large table

**Real-World Scenario**:
```sql
-- Single table bulk update
UPDATE large_users_table SET last_login = NOW(); -- 10M rows, 50,000 pages
-- Result: L0 layer contains 50,000 modified pages from ONE table
-- Read amplification occurs within single table context
```

**PostgreSQL Table Scaling**:
- Maximum table size: 32TB (default), up to 128TB
- Page structure: 8KB pages/blocks
- Large table impact: Few tables can dominate L0 layer content

### What is an LSN Really? - Deep Technical Analysis

**LSN as PostgreSQL's Universal Time Coordinate**: The Log Sequence Number (LSN) is PostgreSQL's fundamental ordering mechanism, but Neon elevates it from a recovery aid to the primary temporal coordinate of the entire system.

**PostgreSQL LSN Structure (64-bit integer)**:
```
Traditional Format: 0/1A2B3C4D
├── High 32 bits (0): WAL timeline/segment file number
├── Low 32 bits (1A2B3C4D): Byte offset within WAL segment
└── Represents exact byte position in WAL stream

Binary Representation:
63                    32 31                     0
├──────────────────────┼─────────────────────────┤
│   Timeline/Segment   │     Byte Offset         │
├──────────────────────┼─────────────────────────┤
0x00000000             0x1A2B3C4D
```

**Breaking Down `0/1A2B3C4D` - Hexadecimal to Decimal Conversion**:
```
High Part: 0 (WAL file/segment number = 0)
Low Part: 1A2B3C4D (hexadecimal byte offset)

Hex to Decimal Conversion:
1A2B3C4D = 1×16⁷ + A×16⁶ + 2×16⁵ + B×16⁴ + 3×16³ + C×16² + 4×16¹ + D×16⁰
         = 1×268435456 + 10×16777216 + 2×1048576 + 11×65536 + 3×4096 + 12×256 + 4×16 + 13×1
         = 439,041,101 (decimal byte position)

Meaning: "WAL File 0, Byte Position 439,041,101"
```

**LSN Generation Process**:
1. **WAL Record Creation**: Each transaction operation generates WAL record
2. **LSN Assignment**: WAL manager assigns next available LSN (monotonically increasing)
3. **Atomicity**: LSN assignment is atomic - no two records get same LSN
4. **Global Ordering**: LSN provides total order across all transactions system-wide

**Neon's LSN Usage Revolution**:
```
Traditional PostgreSQL: LSN for recovery and replication
Neon's Innovation: LSN as primary temporal coordinate

├── LSN 1000: Database state at exact moment LSN 1000 was written
├── LSN 2000: Database state 1000 WAL bytes later
├── LSN Range (1000, 2000]: All changes between these two points
└── GetPage@LSN(page_id, 1500): Page state exactly at LSN 1500
```

**WAL File Boundaries and LSN Progression**:
```
WAL files typically 16MB each:
End of file:   0/00FFFFFF (16MB - 1 byte)
Start of next: 1/00000000 (next file, byte 0)

LSN Sequence:
0/00000000 → 0/00000001 → ... → 0/00FFFFFF → 1/00000000 → 1/00000001...
```

### 2D Coordinate System: The Foundation of Time-Travel

**Complete State Addressing**: `(key, LSN)` provides complete state addressing
- **X-axis (Key)**: `rel <database_oid>/<relation_oid> blk <block_number>`
- **Y-axis (LSN)**: Temporal coordinate for exact point-in-time state
- **Intersection**: Specific page state at specific moment

**LSN Range Semantics and Transaction Boundaries**:
```
Transaction commits at LSN 5500:
- Before: Database state includes changes up to LSN 5499
- After: Database state includes changes up to LSN 5500
- Delta range: (5499, 5500] contains exactly this transaction's changes
- Exclusive start, inclusive end: (start_lsn, end_lsn]
```

**GetPage@LSN Algorithm - The Heart of Neon**:
1. **Image Layer Search**: Find most recent image layer at or before target LSN
2. **Delta Layer Discovery**: Collect all delta layers between image LSN and target LSN
3. **WAL Record Extraction**: Parse WAL records for requested page from each layer
4. **Sequential Replay**: Apply WAL records in LSN order to reconstruct page state
5. **Page Return**: Return exact 8KB PostgreSQL page at requested LSN

**LSN-to-Physical Storage Mapping**:
```
Traditional PostgreSQL:
├── WAL File: pg_wal/000000010000000000000001
├── Contains LSNs: 0/01000000 to 0/02000000 (16MB segment)
├── Data Files: base/12345/16384 (table file)
└── Page pd_lsn field: Last LSN that modified this page

Neon's LSN Mapping:
├── Delta Layer: LSN range (1000, 2000], contains WAL records
│   ├── Internal Index: LSN → WAL record offset
│   ├── Key Filter: Only WAL records for specific page ranges
│   └── BST Structure: Fast LSN-based WAL record lookup
├── Image Layer: Exact LSN 2000, contains materialized pages
│   ├── Reconstructed Page: All WAL up to LSN 2000 applied
│   ├── pd_lsn = 2000: Page header shows materialization point
│   └── Binary Identical: Exact PostgreSQL page format
```

**Mapping**: `users` table (relation 16384) pages → Keys: `rel_16384_blk_0`, `rel_16384_blk_1`, etc.
**Time dimension**: Each key exists at multiple LSNs for historical access

**Key Format Origin**: The `rel_16384_blk_5` format comes from:
- **Binary Implementation**: Stored internally as 6-field struct in `/libs/pageserver_api/src/key.rs`
- **Human-Readable Format**: Used in documentation, layer filenames, and debugging
- **Conversion Functions**: PostgreSQL relation OIDs mapped via `pgdatadir_mapping.rs` functions:
  ```rust
  rel_block_to_key(rel: RelTag, blknum: BlockNumber) -> Key
  ```
- **Layer File Names**: Format appears in actual storage: `[LSN_range]__rel_12345_16384_blk_0-5__[layer_type]`

### Why L0 Layers Create Read Amplification - CORRECTED

**IMPORTANT CORRECTION**: L0 layers do NOT contain "all tables" - they contain only **modified pages** during their LSN range.

**L0 "all pages"** = all **modified** pages across active tables:
```
L0 Layer: users (modified pages) + orders (modified pages) + products (modified pages) + indexes (modified pages)
Query users → must scan layer containing mostly irrelevant data from OTHER modified tables
Read amplification: 10x+ due to unrelated but co-located modified data
```

**Key Insight - Large Table Impact**:
- A single large table with bulk updates can create most L0 layer content
- Example: 1M row update across 50,000 pages → entire L0 layer from ONE table
- "Many pages in L0" ≠ "many tables" - could be few large tables with heavy modifications

**WAL → Layer Flow - Complete Process**:
```sql
UPDATE users SET balance = 1000 WHERE id = 42;
-- PostgreSQL generates WAL record containing:
--   Database OID: 12345, Relation OID: 16384, Block: 5, LSN: 5000
-- Neon extracts: Key = "rel 12345/16384 blk 5" @ LSN 5000
-- WAL record buffered in open layer (memory)
-- Flushed to L0 delta layer when checkpoint_distance reached (256MB)
```

**Neon's Enhanced LSN-to-Page Relationship**:
- **2D Coordinate System**: `(key, LSN)` where key = page identifier, LSN = temporal coordinate
- **LSN Range Semantics**: `(start_lsn, end_lsn]` (exclusive start, inclusive end)
- **GetPage@LSN**: Reconstruct page state at exact LSN by applying WAL records in sequence
- **Time-Travel Queries**: Any historical LSN instantly queryable via layer reconstruction
- **Branch Creation**: Zero-copy branches at any LSN without data duplication
- **Point-in-Time Recovery**: Instant recovery to any historical state

## Core Architecture: L0, L1, and Image Layers

### Layer Types

**L0 (Ingestion)**: All **modified** pages from active tables, specific LSN ranges
- Generated every 256MB of WAL (configurable via `checkpoint_distance`)
- **Content**: Only pages that received writes during LSN range - NOT all database pages
- **Key Range**: Spans "all keys" meaning CAN contain any key, but only contains MODIFIED keys
- Problem: Every read searches ALL L0 layers for relevant changes

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
- Input: 10-20 L0 layers containing mixed modified pages
- Process: Merge-sort by `(page, LSN)`, write 128MB chunks
- **Key insight**: Page boundaries emerge from actual write density, not table boundaries
  - Hot tables → narrow page ranges (frequent modifications)
  - Cold tables → wide page ranges (infrequent modifications)
  - Large tables with bulk operations → many consecutive pages in single L1 layer
- Output: L1 deltas organized by **page access patterns**, not necessarily table ranges

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

**Read Amplification Analysis**:
- **L0**: 10x+ amplification due to scanning irrelevant but co-located modified data
  - NOT because of "all tables" but because of **mixed workload modifications**
  - Single large table updates can also cause amplification if spread across many L0s
- **L1 + Images**: 1.5x amplification (targeted access by page ranges)
- **Root Cause**: WAL ingestion creates temporal locality (same LSN range) but destroys spatial locality (related pages)

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

**Data-Driven Partitioning**: L0→L1 sorts by `(page, LSN)`. Write density determines boundaries:
- **Hot pages** (frequent modifications) → narrow ranges in dedicated L1 layers
- **Cold pages** (infrequent modifications) → wide ranges sharing L1 layers
- **Large table bulk operations** → many consecutive pages in single L1 layer
- **Mixed workload** → interleaved pages from different tables
- **Boundaries emerge from modification patterns**, not table schema

**Layer Navigation**: Start from newest layers, skip by page range, stop at first image layer.

## Best Practices

**Maximum Performance**:
- 8+ shards, `image_creation_threshold = 1`, aggressive L0 compaction
- Interpreted WAL for sharded tenants

**Balanced**:
- 4-8 shards, `image_creation_threshold = 3-4`, monitor layer depth

**Universal Principles**:
- **L0 proliferation** is the enemy of read performance (not L0 existence)
  - Root cause: Mixed modifications creating temporal but not spatial locality
  - Solution: Aggressive L0 compaction to restore spatial locality
- **Images stop layer traversal early** - most impactful optimization
- **Sharding multiplies all benefits** by reducing write mixing
  - Each shard sees subset of workload → better spatial locality
  - Fewer cross-table modifications per shard → cleaner L1 boundaries

This architecture enables cloud-native PostgreSQL with ACID guarantees, instant branching, and time-travel queries.

## Production Configuration Guide: Optimizing Neon for Real-World Workloads

### Configuration Philosophy: Workload-Driven Tuning

Pageserver performance fundamentally balances write ingestion speed, read latency, storage efficiency, and resource utilization. Each workload pattern demands different optimization strategies.

**Key Configuration Dimensions**:
```
Write-Heavy Workloads:
├── Optimize WAL ingestion throughput
├── Reduce checkpoint frequency
├── Minimize L0 compaction overhead
└── Balance Safekeeper storage requirements

Read-Heavy Workloads:
├── Optimize image layer creation
├── Reduce read amplification
├── Maximize cache effectiveness
└── Minimize GetPage@LSN latency

Mixed Workloads:
├── Balance write and read optimization
├── Prevent pathological read amplification
├── Maintain predictable performance
└── Manage storage cost efficiency
```

### Core Configuration Parameters Deep Dive

#### checkpoint_distance - The Foundation Parameter

**What it controls**: Amount of WAL (in bytes) buffered in memory before flushing to L0 delta layer.

**Technical Impact**:
```
Small checkpoint_distance (128MB):
├── Frequent L0 layer creation
├── More L0 files → higher read amplification
├── Lower memory usage
├── Faster crash recovery (less WAL replay)
└── Higher disk I/O frequency

Large checkpoint_distance (2GB):
├── Infrequent L0 layer creation
├── Fewer L0 files → lower read amplification
├── Higher memory usage
├── Slower crash recovery (more WAL replay)
└── Lower disk I/O frequency
```

**Workload-Specific Recommendations**:

**High Write Throughput (OLTP)**:
```toml
[tenant_config]
checkpoint_distance = "1GB"    # Reduce L0 creation frequency
```
- **Rationale**: Sustained write workloads benefit from fewer L0 layers
- **Trade-off**: Higher memory usage, but reduced read amplification

**Low-Latency Mixed Workload**:
```toml
[tenant_config]
checkpoint_distance = "512MB"  # Balance write efficiency and read performance
```

**Analytics/Batch Processing**:
```toml
[tenant_config]
checkpoint_distance = "256MB"  # Standard setting for mixed patterns
```

#### image_creation_threshold - Read Optimization Control

**What it controls**: Number of L0 delta layers that trigger creation of new image layer.

**Technical Impact**:
```
Low threshold (2 layers):
├── Frequent image layer creation
├── Excellent read performance (minimal WAL replay)
├── Higher storage usage (more materialized pages)
├── Higher CPU usage for image creation
└── Optimal for read-heavy workloads

High threshold (10 layers):
├── Infrequent image layer creation
├── Higher read latency (more WAL replay required)
├── Lower storage usage (fewer materialized pages)
├── Lower CPU usage for image creation
└── Acceptable for write-heavy workloads
```

#### compaction_target_size - Controlling Layer Granularity

**What it controls**: Target size for L1 delta layers and image layers created during compaction.

**Configuration Strategies**:

**Random Access Workload (OLTP)**:
```toml
[tenant_config]
compaction_target_size = "128MB"  # Finer granularity for targeted reads
```

**Sequential Scan Workload (Analytics)**:
```toml
[tenant_config]
compaction_target_size = "512MB"  # Larger chunks for efficient sequential access
```

### Advanced Configuration Patterns

#### Time-Travel Optimized Configuration

For workloads requiring frequent historical queries and branching:

```toml
[tenant_config]
# Optimize for time-travel performance
image_creation_threshold = 3      # More frequent image creation
compaction_target_size = "128MB"  # Smaller layers for targeted historical access
gc_horizon = "7200"              # Retain 2 hours of history (seconds)
gc_period = "3600s"              # Garbage collect hourly

# Strategic image placement
checkpoint_distance = "256MB"     # Frequent checkpoints for historical points
```

#### Cost-Optimized Configuration

For development/staging environments prioritizing storage cost over performance:

```toml
[tenant_config]
# Minimize storage usage
image_creation_threshold = 10     # Rare image creation
compaction_target_size = "512MB" # Large, efficient layers
checkpoint_distance = "2GB"      # Minimize layer creation
gc_horizon = "86400"             # Retain only 24 hours
gc_period = "1800s"              # Frequent garbage collection
```

#### High-Performance OLTP Configuration

For latency-sensitive transactional workloads:

```toml
[tenant_config]
# Optimize for low read latency
image_creation_threshold = 2      # Aggressive image creation
compaction_target_size = "128MB"  # Fine-grained layers
checkpoint_distance = "512MB"    # Balanced write efficiency
page_cache_size = "1GB"          # Large page cache

# Reduce compaction overhead
gc_period = "7200s"              # Less frequent GC to reduce background load
```

**Additional Global Settings**:
```toml
[pageserver]
# Prioritize L0 compaction aggressively
background_task_maximum_delay = "10s"
compaction_period = "20s"        # Frequent compaction cycles
```

### Monitoring-Driven Configuration

#### Key Metrics for Configuration Decisions

**L0 Layer Proliferation**:
```
Metric: current_l0_layer_count
Threshold: > 50 layers = pathological read amplification
Action: Reduce checkpoint_distance or increase compaction resources
```

**Read Amplification**:
```
Metric: average_layers_per_read
Target: < 5 layers per GetPage@LSN request
Action: Lower image_creation_threshold if consistently > 5
```

**Storage Efficiency**:
```
Metric: storage_size_ratio (total_storage / logical_database_size)
Target: < 3x logical size (including history)
Action: Increase gc_frequency or image_creation_threshold if ratio > 5x
```

#### Adaptive Configuration Strategy

**Phase 1: Baseline Configuration**
```toml
[tenant_config]
# Conservative starting point
checkpoint_distance = "256MB"
compaction_target_size = "256MB"
image_creation_threshold = 4
gc_horizon = "604800"            # 7 days retention
```

**Phase 2: Workload-Specific Tuning**

Monitor for 24-48 hours, then adjust based on observed patterns:

```
High Write Volume Detected:
├── checkpoint_distance → 512MB or 1GB
├── compaction_target_size → 512MB
└── image_creation_threshold → 6-8

High Read Volume Detected:
├── image_creation_threshold → 2-3
├── compaction_target_size → 128MB
└── page_cache_size → increase if memory available

Read Amplification Issues:
├── Emergency: reduce checkpoint_distance to 128MB
├── Short-term: lower image_creation_threshold to 2
└── Long-term: increase compaction resources
```

### PostgreSQL Configuration for Neon

**Compute Node Optimization**:
```toml
# PostgreSQL settings for Neon compute
wal_buffers = "64MB"          # Batch WAL before streaming
commit_delay = "100µs"        # Group commit optimization
max_wal_size = "16GB"        # Reduce checkpoint frequency
shared_buffers = "25%"       # Standard recommendation

# Neon-specific optimizations
max_connections = 100        # Use connection pooling
```

**Write Throughput Optimization**:
```toml
# For high-volume insert/update workloads
wal_buffers = "64MB"         # Batch WAL before streaming to Safekeepers
commit_delay = "100µs"       # Group commit optimization
checkpoint_distance = "1GB"  # Reduce L0 layer creation
wal_receiver_protocol = "filtered"  # Safekeeper preprocessing
compaction_target_size = "256MB"    # Larger L1 layers
```

### Configuration Anti-Patterns and Validation

#### Common Mistakes

**Anti-Pattern 1: Extremely Large checkpoint_distance**
```toml
# DON'T DO THIS
checkpoint_distance = "10GB"     # Too large
```
**Problems**: Excessive memory usage, very slow recovery, Safekeeper storage pressure

**Anti-Pattern 2: Conflicting Objectives**
```toml
# CONTRADICTORY SETTINGS
checkpoint_distance = "2GB"      # Minimize L0 creation
image_creation_threshold = 2     # Maximize image creation
```
**Problem**: Image creation can't keep up with infrequent L0 layer creation

#### Pre-deployment Validation Checklist

```
1. Safekeeper Storage: checkpoint_distance * number_of_timelines < safekeeper_capacity
2. Memory Usage: checkpoint_distance should be < 25% of pageserver RAM
3. Compaction Ratio: image_creation_threshold * avg_l0_size should be < compaction_target_size
4. GC Alignment: gc_period should be > time_to_create_image_layers
```

### Real-World Configuration Examples

#### E-Commerce Platform (High OLTP + Analytics)
```toml
[tenant_config]
# Primary workload optimization
checkpoint_distance = "512MB"    # Balance writes and reads
image_creation_threshold = 3     # Good read performance
compaction_target_size = "256MB" # Balanced layer size

# Analytics support
gc_horizon = "259200"           # 3 days for reporting
page_cache_size = "2GB"         # Large cache for mixed access
```

#### SaaS Application (Multi-Tenant)
```toml
[tenant_config]
# Optimize for predictable performance
checkpoint_distance = "256MB"    # Consistent layer creation
image_creation_threshold = 4     # Moderate image creation
compaction_target_size = "128MB" # Fine-grained for isolation

# Cost optimization
gc_period = "3600s"             # Hourly cleanup
gc_horizon = "86400"            # 1 day retention per tenant
```

#### Data Warehouse (Bulk Loads + Queries)
```toml
[tenant_config]
# Bulk load optimization
checkpoint_distance = "1GB"      # Handle large transactions
compaction_target_size = "512MB" # Large layers for scans
image_creation_threshold = 6     # Less frequent materialization

# Query optimization
page_cache_size = "4GB"         # Large cache for analytics
gc_horizon = "604800"           # 1 week for historical analysis
```
