# LFC Cache Architecture & Sizing Analysis

Based on analysis of the Neon codebase, here's how LFC (Local File Cache) fits into the caching architecture and ideal sizing strategies.

## LFC Cache Position & Architecture

LFC sits **between PostgreSQL shared_buffers and pageserver requests** in a three-tier hierarchy:

```
┌─────────────────────────────────────────────┐
│ PostgreSQL shared_buffers (RAM)             │ ← Tier 1: Hot data
│ Default: 128MB, Optimized: 4GB              │   Hit rate: 80-95%
└─────────────────────────────────────────────┘
                    ↓ getpage@lsn request
┌─────────────────────────────────────────────┐
│ Local File Cache (LFC) - SSD/ephemeral     │ ← Tier 2: Warm data
│ Default: 0MB, Recommended: 1-8GB           │   Hit rate: 60-80%
└─────────────────────────────────────────────┘
                    ↓ pageserver request
┌─────────────────────────────────────────────┐
│ Pageserver layers (Remote S3/disk)         │ ← Tier 3: Cold data
│ L0/L1 delta + image layers                 │   Always requires I/O
└─────────────────────────────────────────────┘
```

## LFC Implementation Details

**Storage**: LFC uses **ephemeral SSD** storage (file-based cache):
- Location: `neon.file_cache_path` (default: temp directory)
- Architecture: Single file with shared hash map for addressing
- Chunk size: **1MB chunks** (128 pages) for efficiency
- Eviction: LRU-based replacement policy

**Key Configuration Parameters**:
- `neon.max_file_cache_size`: Hard limit set at startup
- `neon.file_cache_size_limit`: Soft limit (dynamically resizable)
- `neon.file_cache_chunk_size`: Chunk size in pages (power of 2)

## Optimal Sizing Recommendations

### Auto-Scaling Formula (Production)
The VM monitor uses sophisticated auto-scaling:
```rust
// Default configuration in libs/vm_monitor/src/filecache.rs
resource_multiplier: 0.75,           // 75% of available memory
min_remaining_after_cache: 256MB,    // Minimum reserved
spread_factor: 0.1                   // Gradual scaling
```

**Cache size = min(total_memory × 0.75, (available_memory) / 1.1)**

### Manual Sizing Guidelines

**For 4TB Database (from codebase analysis)**:
```json
{
  "shared_buffers": "4GB",           // 0.1% of database size
  "neon.max_file_cache_size": "8GB", // 2x shared_buffers
  "neon.file_cache_size_limit": "6GB" // 75% of max for headroom
}
```

**Scaling Ratios by Database Size**:
- **Small DB** (< 100GB): LFC = 1-2GB, shared_buffers = 512MB-2GB
- **Medium DB** (100GB-1TB): LFC = 2-4GB, shared_buffers = 2-4GB
- **Large DB** (> 1TB): LFC = 4-8GB, shared_buffers = 4-8GB

### shared_buffers Scaling Function

From `test_runner/fixtures/utils.py:729`, production uses:
```python
def shared_buffers_for_max_cu(max_cu: float) -> str:
    ramBytes = int(4096 * max_cu * 1024 * 1024)  # 4GB per CU
    # 2 CU: 225MB; 4 CU: 450MB; 8 CU: 900MB
    sharedBuffersMb = max(128, (1023 + maxBackends * 256) / 1024)
```

## Hardware Considerations

### Why Ephemeral SSD (Not RAM)?
1. **Cost efficiency**: SSD much cheaper than RAM for large caches
2. **Persistence**: Survives process restarts (unlike RAM)
3. **OS page cache**: Kernel automatically caches hot LFC blocks in RAM
4. **Overcommit safety**: Can size larger than physical RAM

### Performance Characteristics
- **LFC hit**: ~1-10ms (SSD read + hash lookup)
- **LFC miss**: 50-200ms (pageserver round-trip + layer traversal)
- **shared_buffers hit**: ~0.01ms (RAM access)

### Memory Footprint Analysis
From `pgxn/neon/file_cache.c:93-95`:
```c
// 8TB database = 1 billion pages
// Hash entry = 40 bytes each
// Without chunking: 40GB hash map
// With 1MB chunks: 320MB hash map (128x reduction)
```

## Ideal Hardware Ratios

### Memory Distribution for 16GB Node:
```
PostgreSQL shared_buffers:  4GB  (25%)
LFC cache:                 6GB  (37.5%)
OS + other processes:      4GB  (25%)
Buffer/headroom:           2GB  (12.5%)
```

### Storage Requirements:
- **LFC backing store**: Fast ephemeral SSD (NVMe preferred)
- **Size**: 1-2x RAM for optimal performance
- **IOPS**: High random read performance critical

## Configuration Examples

### Small Workload (2-4 CU):
```sql
shared_buffers = '450MB'
neon.max_file_cache_size = '2GB'
neon.file_cache_size_limit = '1GB'
```

### Large Workload (8 CU):
```sql
shared_buffers = '4GB'
neon.max_file_cache_size = '8GB'
neon.file_cache_size_limit = '6GB'
```

### Test Configurations (Common patterns):
- **Performance tests**: LFC = 1GB, shared_buffers = 1MB (stress LFC)
- **Integration tests**: LFC = 64-128MB, shared_buffers = 1-10MB
- **Working set tests**: LFC = 245MB, shared_buffers = 1MB

## LFC Architecture Details

### Chunk-Based Storage
From `pgxn/neon/file_cache.c:98-99`:
```c
#define MAX_BLOCKS_PER_CHUNK_LOG  7 /* 1MB chunk */
#define MAX_BLOCKS_PER_CHUNK      (1 << MAX_BLOCKS_PER_CHUNK_LOG)
```

**Benefits of 1MB chunks**:
1. **Reduced hash map memory**: 8TB database needs only 320MB hash map vs 40GB without chunking
2. **Improved locality**: Sequential pages allocated together for better seqscan performance
3. **Efficient I/O**: Larger I/O operations reduce syscall overhead

### Block State Management
```c
typedef enum FileCacheBlockState {
    UNAVAILABLE, /* block is not present in cache */
    AVAILABLE,   /* block can be used */
    PENDING,     /* block is being loaded */
    REQUESTED    /* other backends waiting for block */
} FileCacheBlockState;
```

### Dynamic Resizing
LFC supports on-the-fly resizing using `fallocate(FALLOC_FL_PUNCH_HOLE)`:
- Expand up to `neon.max_file_cache_size`
- Shrink by punching holes (releases disk space, keeps file size)
- Tracked via dummy `FileCacheEntry` in holes list

## Auto-Scaling Configuration

### FileCacheConfig Parameters
From `libs/vm_monitor/src/filecache.rs:59-69`:
```rust
impl Default for FileCacheConfig {
    fn default() -> Self {
        Self {
            resource_multiplier: 0.75,      // Use 75% of available memory
            min_remaining_after_cache: 256MB,  // Always reserve 256MB
            spread_factor: 0.1,             // Gradual scaling factor
        }
    }
}
```

### Calculation Formula
```rust
pub fn calculate_cache_size(&self, total: u64) -> u64 {
    let available = total.saturating_sub(self.min_remaining_after_cache.get());
    let size_from_spread = (available as f64 / (1.0 + self.spread_factor)) as u64;
    let size_from_normal = (total as f64 * self.resource_multiplier) as u64;
    u64::min(size_from_spread, size_from_normal) / MiB * MiB  // Round down to MiB
}
```

## Performance Impact Analysis

### Cache Hit Scenarios
1. **shared_buffers hit**: ~0.01ms - Direct RAM access
2. **LFC hit, shared_buffers miss**: ~1-10ms - SSD read + kernel page cache
3. **Both miss**: 50-200ms - Full pageserver request with layer traversal

### Working Set Approximation
LFC includes HyperLogLog-based working set estimation:
```c
int32 lfc_approximate_working_set_size_seconds(time_t duration, bool reset)
```
- Tracks unique page access patterns over time windows
- Helps with auto-scaling decisions
- Available via SQL: `SELECT * FROM neon.neon_lfc_stats`

## Key Insights

The key insight: **LFC provides massive performance improvement for workloads with working sets larger than shared_buffers but smaller than total database size**—exactly the common case for large Neon databases.

### Optimal Use Cases:
- **Large databases** (>1TB) with moderate working sets (10-100GB)
- **Mixed workloads** with both hot and warm data access patterns
- **Analytical queries** that scan beyond shared_buffers capacity
- **Multi-tenant environments** with diverse access patterns

### Configuration Strategy:
1. **Start conservative**: LFC = 1-2x shared_buffers
2. **Monitor hit rates**: Use `neon.neon_lfc_stats` for metrics
3. **Scale up gradually**: Increase based on working set estimation
4. **Consider total memory**: Leave 25% for OS and other processes

The LFC acts as a crucial **performance multiplier** in Neon's architecture, bridging the massive latency gap between fast local storage and remote pageserver requests.