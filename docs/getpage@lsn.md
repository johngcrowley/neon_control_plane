# Neon Storage Layers & GetPage@LSN Request Flow Analysis

This document traces the complete lineage of GetPage@LSN requests through the Neon architecture, from PostgreSQL commands to storage layer compaction strategies.

## Part 1: GetPage@LSN Request Flow Architecture

### **Page Identifier → Storage Key Conversion**

When PostgreSQL needs a page, it gets converted to a Neon storage Key via `rel_block_to_key()`:

```rust
// libs/pageserver_api/src/key.rs:500
pub fn rel_block_to_key(rel: RelTag, blknum: BlockNumber) -> Key {
    Key {
        field1: 0x00,           // Relation data prefix
        field2: rel.spcnode,    // Tablespace OID
        field3: rel.dbnode,     // Database OID
        field4: rel.relnode,    // Relation OID
        field5: rel.forknum,    // Fork number (main, fsm, vm)
        field6: blknum,         // Block number
    }
}
```

The Key structure provides an 18-byte encoded identifier:
```rust
// libs/pageserver_api/src/key.rs:18
#[derive(Debug, Clone, Copy, Hash, PartialEq, Eq, Ord, PartialOrd, Serialize, Deserialize)]
pub struct Key {
    pub field1: u8,
    pub field2: u32,
    pub field3: u32,
    pub field4: u32,
    pub field5: u8,
    pub field6: u32,
}
```

### **Complete GetPage@LSN Flow**

1. **SQL Command → PostgreSQL Buffer Manager**
2. **Buffer Manager → Neon Storage Manager (SMGR)**
3. **SMGR → Local File Cache (LFC) Check**
4. **LFC Miss → Communicator → Pageserver**
5. **Pageserver → Timeline::get() → Layer Traversal**
6. **Layer Processing → Page Reconstruction**

## Part 2: SQL Command Traces

### **INSERT Command Flow**

```sql
INSERT INTO users (name, email) VALUES ('John', 'john@example.com');
```

**Path through system:**
1. **PostgreSQL Executor** → Calls `heap_insert()`
2. **Buffer Manager** → `ReadBufferExtended()` to get target page
3. **Neon SMGR** → `pagestore_smgr.c:neon_read()`
4. **LFC Check** → `file_cache.h:lfc_read()`
```c
// pgxn/neon/file_cache.h:73
static inline bool
lfc_read(NRelFileInfo rinfo, ForkNumber forkNum, BlockNumber blkno,
         void *buffer)
{
    bits8 rv = 0;
    return lfc_readv_select(rinfo, forkNum, blkno, &buffer, 1, &rv) == 1;
}
```

5. **LFC Miss** → `communicator.c:communicator_read_at_lsnv()`
6. **Pageserver Request** → `PagestreamGetPageRequest`
```c
// pgxn/neon/pagestore_client.h:96
typedef struct
{
    NeonRequest hdr;
    NRelFileInfo rinfo;
    ForkNumber  forknum;
    BlockNumber blkno;
} NeonGetPageRequest;
```

7. **Timeline Processing** → `timeline.rs:1227:get()`
8. **Layer Search** → L0/L1 traversal
9. **Page Reconstruction** → WAL redo if needed
10. **Response** → Written to LFC, returned to PostgreSQL

**INSERT generates WAL** that will eventually create delta layers containing the new tuple data.

### **SELECT Command Flow**

```sql
SELECT * FROM users WHERE id = 123;
```

**Path through system:**
1. **PostgreSQL Executor** → Calls `heap_beginscan()`
2. **Buffer Manager** → `ReadBuffer()` for index/heap pages
3. **Shared Buffer Pool Check** → PostgreSQL's standard buffer pool
4. **Buffer Miss** → Delegate to Neon SMGR
5. **LFC Check** → Fast local cache lookup
6. **LFC Hit** → Return cached page (common case)
7. **LFC Miss** → Same flow as INSERT but **read-only**

**Key difference**: SELECTs don't generate WAL, only consume existing layer data.

## Part 3: Layer Architecture & File Naming

### **Storage Layer Organization**

Neon uses a **two-level LSM tree variant**:

[`is_l0`](https://github.com/neondatabase/neon/tree/main/pageserver/src/tenant/layer_map.rs#L793) function determines layer classification:

```rust
// pageserver/src/tenant/layer_map.rs:793
pub fn is_l0(key_range: &Range<Key>, is_delta_layer: bool) -> bool {
    is_delta_layer && key_range == &(Key::MIN..Key::MAX)
}
```

#### **L0 Layers (Recent Changes - Delta Only)**
- **Coverage**: Full key range (`Key::MIN..Key::MAX`)
- **Content**: WAL records/deltas only
- **Problem**: High read amplification - every read searches all L0 layers
- **File naming**:
```
000000000000000000000000000000000000-FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF__<LSN_start>-<LSN_end>
```

Example L0 stack:
```
| All Pages @ LSN 0400-04ff |  ← Most recent
| All Pages @ LSN 0300-03ff |
| All Pages @ LSN 0200-02ff |
| All Pages @ LSN 0100-01ff |
| All Pages @ LSN 0000-00ff |  ← Oldest
```

#### **L1 Layers (Compacted Storage)**

**Delta Layers** - Contain WAL records for key ranges (see [`DeltaLayerName`](https://github.com/neondatabase/neon/tree/main/pageserver/src/tenant/storage_layer/layer_name.rs#L16)):
```rust
// pageserver/src/tenant/storage_layer/layer_name.rs:16
pub struct DeltaLayerName {
    pub key_range: Range<Key>,
    pub lsn_range: Range<Lsn>,
}
```
**File naming**: `<key_start>-<key_end>__<LSN_start>-<LSN_end>`

**Image Layers** - Contain materialized pages (see [`ImageLayerName`](https://github.com/neondatabase/neon/tree/main/pageserver/src/tenant/storage_layer/layer_name.rs#L124)):
```rust
// pageserver/src/tenant/storage_layer/layer_name.rs:124
pub struct ImageLayerName {
    pub key_range: Range<Key>,
    pub lsn: Lsn,
}
```
**File naming**: `<key_start>-<key_end>__<LSN>`

Example L1 structure:
```
Delta layers:               |     30-84@0310-04ff      |
Delta layers:    | 10-42@0200-02ff |           | 65-92@0174-02aa |
Image layers: |    0-39@0100    |    40-79@0100    |    80-99@0100    |
```

### **Layer File Name Examples**

**L0 Delta Layer**:
```
000000000000000000000000000000000000-FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF__000000578C6B29-0000000057A50051
```

**L1 Delta Layer**:
```
000000067F000032BE0000400000000020B6-000000067F000032BE0000400000000030B6__000000578C6B29-0000000057A50051
│────────── key_start ──────────│─────────── key_end ──────────│  │─ LSN_start ─│─ LSN_end ─│
```

**L1 Image Layer**:
```
000000067F000032BE0000400000000020B6-000000067F000032BE0000400000000030B6__000000578C6B29
│────────── key_start ──────────│─────────── key_end ──────────│  │─── LSN ────│
```

## Part 4: Layer Processing & Compaction Strategies

### **GetPage@LSN Layer Traversal Algorithm**

[`get_vectored_reconstruct_data_timeline()`](https://github.com/neondatabase/neon/tree/main/pageserver/src/tenant/timeline.rs#L4670) function:

1. **[`LayerFringe`](https://github.com/neondatabase/neon/tree/main/pageserver/src/tenant/timeline.rs#L4631) Initialization**: Priority queue orders layers by LSN (newest first)
```rust
// pageserver/src/tenant/timeline.rs - LayerFringe structure
let mut fringe = LayerFringe::new();
```

2. **Layer Selection Strategy**:
   - **L0 layers**: Direct vector access (fast)
   - **L1 layers**: R-tree spatial search (efficient range queries)

3. **Data Extraction Order**:
   - Traverse from newest LSN to oldest
   - Stop at first page image found
   - Collect all necessary WAL deltas

4. **Page Reconstruction**:
```rust
// Apply deltas in reverse chronological order to base image
let reconstructed_page = apply_wal_records(base_image, wal_records);
```

### **Compaction Strategy Differences**

#### **L0→L1 Compaction** (Structural Cleanup)

**Trigger**: When L0 layer count > `compaction_threshold` (default: 10)

**Process**:
1. **Input**: Bottom 10-20 L0 layers (full key range, different LSN ranges)
2. **Method**: Merge-sort by Key+LSN
3. **Output**: L1 delta layers partitioned by key range (~128MB each)
4. **Goal**: **Reduce read amplification** by eliminating overlapping L0 layers

```rust
// pageserver/src/tenant/timeline/compaction.rs:73
/// Maximum number of deltas before generating an image layer in bottom-most compaction.
const COMPACTION_DELTA_THRESHOLD: usize = 5;
```

See [`COMPACTION_DELTA_THRESHOLD`](https://github.com/neondatabase/neon/tree/main/pageserver/src/tenant/timeline/compaction.rs#L73) definition.

**Before L0→L1**:
```
Read for Page 50 @ LSN 350 must search:
├── L0 layer @ LSN 300-399 ✓ (contains Page 50 delta)
├── L0 layer @ LSN 200-299 ✓ (might contain Page 50)
├── L0 layer @ LSN 100-199 ✓ (might contain Page 50)
└── L0 layer @ LSN 000-099 ✓ (might contain Page 50)
= 4 layer reads
```

**After L0→L1**:
```
Read for Page 50 @ LSN 350 searches:
├── L1 delta layer @ Pages 40-60, LSN 300-399 ✓ (contains Page 50)
└── Done - only 1 layer read needed
```

#### **L1 Image Compaction** (Data Materialization)

**Trigger**: When key range has ≥ `image_creation_threshold` (default: 3) delta layers above image layer

**Process**:
1. **Input**: Delta layers + underlying image layer for a key range
2. **Method**: **Vectored reconstruction** - materialize pages by applying all deltas to base images
3. **Output**: New image layer with materialized pages at target LSN
4. **Goal**: **Accelerate future reads** by pre-computing page states

```rust
// From docs/pageserver-compaction.md:62
// L1 image compaction scans across the L1 keyspace at some LSN,
// materializes page images by reading the image and delta layers below the LSN
// (via vectored reads), and writes out new sorted image layers
```

**Before Image Compaction** (for Page 45 @ LSN 350):
```
Timeline needs to reconstruct page by:
├── Read base image: Page 45 @ LSN 100
├── Apply delta 1: Page 45 delta @ LSN 150
├── Apply delta 2: Page 45 delta @ LSN 250
└── Apply delta 3: Page 45 delta @ LSN 320
= 4 layer reads + WAL redo work
```

**After Image Compaction**:
```
Timeline can directly read:
└── Image layer: Page 45 @ LSN 350 (pre-materialized)
= 1 layer read, no WAL redo needed
```

#### **GC Compaction** (Garbage Collection)

**Enhanced GC Bottom-Most Compaction** removes old versions:

See [`GcCompactionCombinedSettings`](https://github.com/neondatabase/neon/tree/main/pageserver/src/tenant/timeline/compaction.rs#L91):

```rust
// pageserver/src/tenant/timeline/compaction.rs:91
pub struct GcCompactionCombinedSettings {
    pub gc_compaction_enabled: bool,
    pub gc_compaction_verification: bool,
    pub gc_compaction_initial_threshold_kb: u64,
    pub gc_compaction_ratio_percent: u64,
}
```

**Process**: Removes layer data below `gc_horizon` LSN that's no longer needed for PITR.

## Part 5: Table Coverage Across Layers

### **Table Coverage Strategy**

**Small Tables** (< 128MB):
- **L0**: Contains all changes across entire table
- **L1**: Single delta/image layer per LSN range
- **Compaction**: Entire table fits in one layer file

**Large Tables** (> 128MB):
- **L0**: Still contains all changes (full key range coverage)
- **L1**: **Horizontally partitioned** into multiple layers by key range
- **Compaction**: Each layer handles ~128MB of key space

```rust
// pageserver/src/tenant/timeline/compaction.rs - compaction_target_size
// Default 128MB layer size means large tables split across multiple layer files
```

**Example for 1GB table**:
```
Table "users" (1GB, 131,072 pages):

L0 Layers:
├── All pages (0-131,071) @ LSN 400-499
├── All pages (0-131,071) @ LSN 300-399
└── All pages (0-131,071) @ LSN 200-299

L1 Layers after compaction:
├── Pages   0-16,383 @ LSN 200-499 (128MB delta layer)
├── Pages  16,384-32,767 @ LSN 200-499 (128MB delta layer)
├── Pages  32,768-49,151 @ LSN 200-499 (128MB delta layer)
└── ... (8 total L1 delta layers)

L1 Image layers after image compaction:
├── Pages   0-16,383 @ LSN 400 (128MB image layer)
├── Pages  16,384-32,767 @ LSN 400 (128MB image layer)
└── ... (8 total L1 image layers)
```

### **Read Performance by Table Size**

**Small Table Read** (Page from 10MB table):
- **L0**: Search 1-10 layers (all contain full table)
- **L1**: Search 1 layer (table fits in single layer)

**Large Table Read** (Page from 1GB table):
- **L0**: Search 1-10 layers (all contain all pages)
- **L1**: Search 1-2 layers (only layers covering target key range)

**This is why L0→L1 compaction is crucial** - it converts full-table scans into targeted key-range lookups.

## Part 6: Local File Cache (LFC) Integration

The Local File Cache sits between PostgreSQL shared buffers and pageserver requests:

See [`FileCacheState`](https://github.com/neondatabase/neon/tree/main/pgxn/neon/file_cache.h#L16) structure:

```c
// pgxn/neon/file_cache.h:16
typedef struct FileCacheState
{
    int32       vl_len_;        /* varlena header */
    uint32      magic;
    uint32      n_chunks;       /* number of cached chunks */
    uint32      n_pages;        /* total pages in cache */
    uint16      chunk_size_log; /* log2 of chunk size */
    BufferTag   chunks[FLEXIBLE_ARRAY_MEMBER];
    /* followed by bitmap */
} FileCacheState;
```

**LFC Hit Path** (fast):
```
PostgreSQL ReadBuffer()
→ neon_read()
→ lfc_read() ✓ HIT
→ Return cached page (microseconds)
```

**LFC Miss Path** (slow):
```
PostgreSQL ReadBuffer()
→ neon_read()
→ lfc_read() ✗ MISS
→ communicator_read_at_lsnv()
→ PageServer GetPage@LSN request
→ Timeline layer traversal
→ Page reconstruction
→ lfc_write() (cache result)
→ Return page (milliseconds)
```

The LFC dramatically improves read performance by caching frequently accessed pages locally, avoiding expensive pageserver round-trips and layer traversals.

## Summary

The GetPage@LSN request flow demonstrates Neon's sophisticated storage architecture:

1. **PostgreSQL** generates page requests during SQL execution
2. **LFC** provides fast local caching to avoid remote calls
3. **Pageserver** maintains LSM-tree storage with L0/L1 layers
4. **Compaction** optimizes layer organization for read performance
5. **Layer files** are named to encode key ranges and LSN ranges
6. **Different compaction strategies** address different performance problems

This architecture enables **separating storage from compute** while maintaining PostgreSQL compatibility and performance through intelligent caching, layer organization, and compaction strategies.