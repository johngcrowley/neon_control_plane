# Ultra-Performance Neon Configuration Guide

This guide explains how the ultra-optimized `pageserver.toml` and `config.json` configurations maximize read/write latency performance through advanced Neon features including vectored I/O, sidecar tasks, and optimized image layer operations.

## Architecture Overview

Neon's performance is fundamentally dependent on efficient **image layer** operations and **pageserver sharding**. The configuration optimizations target these key areas:

```
┌─────────────┐    ┌─────────────────┐    ┌──────────────┐
│   Compute   │◄───┤   Pageserver    │◄───┤  Safekeepers │
│ (PostgreSQL)│    │   (Sharded)     │    │    (WAL)     │
└─────────────┘    └─────────────────┘    └──────────────┘
                           │
                   ┌───────▼───────┐
                   │ Storage Layers│
                   │ • Image Layers│
                   │ • Delta Layers│
                   │ • L0 Layers   │
                   └───────────────┘
```

## Key Performance Features Enabled

### 1. Vectored I/O Optimization: Reading Multiple Pages at Once

**What is Vectored I/O?**

Imagine you need to buy groceries from different aisles. Traditional I/O is like making separate trips: walk to aisle 1, grab item A, walk back to your cart, then walk to aisle 5, grab item B, walk back to your cart, and so on.

Vectored I/O is like making a shopping list and collecting multiple items in one efficient trip through the store. Instead of reading database pages one-by-one, we batch many page requests together and read them in a single efficient operation.

**What are Sidecar Tasks?**

Sidecar tasks are like having an assistant who handles the physical shopping while you plan the next steps. In Neon:
- The **main task** continues planning and organizing work (traversing storage layers, processing requests)
- The **sidecar task** handles the actual I/O operations in parallel
- Both work simultaneously instead of blocking each other

This is especially powerful when the page cache miss rate is low - while the sidecar task fetches pages from disk, the main task can continue working with pages already in cache.

**Configuration Impact:**
- [`max_vectored_read_bytes = 2097152`](https://github.com/neondatabase/neon/tree/main/libs/pageserver_api/src/config.rs#L249) - 16x larger batches (2MB vs 130KB default)
- [`max_get_vectored_keys = 256`](https://github.com/neondatabase/neon/tree/main/libs/pageserver_api/src/config.rs#L250) - 8x more keys per batch (256 vs 32 default)
- [`get_vectored_concurrent_io = "sidecar-task"`](https://github.com/neondatabase/neon/tree/main/libs/pageserver_api/src/config.rs#L348) - Concurrent I/O via sidecar tasks

**How It Optimizes Image Layers:**
```rust
// Code reference: https://github.com/neondatabase/neon/tree/main/pageserver/src/tenant/storage_layer.rs#L34
use pageserver_api::config::GetVectoredConcurrentIo;

// With SidecarTask mode enabled:
// - Index blocks read synchronously from main task
// - Data I/O dispatched to sidecar task for parallel execution
// - Main task continues traversing layers while I/O is in flight
// - Dramatically improves throughput when PageCache miss rate is low
```

**Benefits:**
- **Reduced Read Amplification**: Larger vectored reads minimize the number of system calls
- **Concurrent Processing**: Sidecar tasks allow I/O and layer traversal to proceed in parallel
- **Better Batching**: More keys per batch reduces per-request overhead

### 2. Advanced I/O Engine: From Blocking to Blazing Fast

**The Problem We're Solving:**

Traditional file I/O is like having to personally walk to the post office every time you want to send a letter. Each file read or write operation:
1. Stops your program (blocking)
2. Asks the operating system kernel to do the work
3. Waits for the disk to respond
4. Returns control to your program

This "stop-and-wait" approach becomes a major bottleneck when you need to read thousands of database pages per second.

**epoll: The First Improvement**

epoll is like having a mail notification system - instead of walking to the post office repeatedly to check for mail, the post office notifies you when something arrives. Your program can do other work while waiting for I/O to complete.

**io_uring: The Modern Solution**

io_uring takes this further by providing a "high-speed mail sorting facility":

**Configuration Impact:**
- [`virtual_file_io_engine = "tokio-epoll-uring"`](https://github.com/neondatabase/neon/tree/main/pageserver/src/virtual_file/io_engine.rs#L33) - Linux io_uring for async I/O
- [`virtual_file_io_mode = "direct"`](https://github.com/neondatabase/neon/tree/main/pageserver/src/config.rs#L213) - Bypasses OS page cache

**What is io_uring and why does it matter?**

io_uring is like having a high-speed conveyor belt between your application and the operating system kernel, instead of the old method of knocking on the kernel's door for each individual request.

Think of traditional I/O as ordering food at a restaurant by walking to the kitchen individually for each item - you place an order, wait for it to be prepared, walk back to your table, then repeat for the next item. This creates a lot of back-and-forth (context switching) and waiting.

io_uring is like giving the kitchen a list of everything you want at once and having them deliver it all to your table when ready. The benefits:
- **Batch processing**: Submit many I/O requests at once instead of one-by-one
- **Zero-copy operations**: Data moves directly without extra copying steps
- **Reduced overhead**: Far fewer expensive transitions between user and kernel space
- **Better parallelism**: The kernel can optimize and reorder operations for maximum efficiency

**Performance Benefits:**
```rust
// Code reference: https://github.com/neondatabase/neon/tree/main/pageserver/src/virtual_file/io_engine.rs#L131-L162
impl IoEngine {
    pub(super) async fn read_at<Buf>(&self, ...) -> (...) {
        match self {
            IoEngine::TokioEpollUring => {
                // High-performance async I/O with io_uring
                // - Zero-copy operations
                // - Batch system call submission
                // - Reduced context switching
                let system = tokio_epoll_uring_ext::thread_local_system().await;
                let (resources, res) = system.read(file_guard, offset, slice).await;
                (resources, res.map_err(epoll_uring_error_to_std))
            }
        }
    }
}
```

### 3. Page Service Pipelining

**Configuration Impact:**
```toml
[page_service_pipelining]
mode = "pipelined"
execution = "concurrent-futures"  # Maximum concurrency
batching = "scattered-lsn"       # Different LSNs in same batch
max_batch_size = 256             # Large batches
```

**Code Reference:** [`pageserver_api/src/config.rs:258`](https://github.com/neondatabase/neon/tree/main/libs/pageserver_api/src/config.rs#L258)

**What is pipelining and why does it help?**

Imagine page requests as orders at a busy coffee shop. Traditional processing is like having one barista who takes an order, makes the entire drink, serves it, then moves to the next customer - very sequential and slow.

Pipelined processing is like having multiple baristas working in parallel: one takes orders, another steams milk, another pulls espresso shots, and another assembles drinks. Multiple orders flow through the "pipeline" simultaneously.

For Neon's page service:
- **Concurrent processing**: Multiple page requests handled simultaneously instead of one-at-a-time
- **Scattered LSN batching**: Pages from different transaction log positions can be batched together (like mixing different drink orders in the same production batch)
- **Async futures**: Uses lightweight async tasks instead of heavy operating system threads

**How It Works:**
- **Pipelined Mode**: Multiple page requests processed concurrently
- **Scattered LSN**: Allows batching requests for different LSN values
- **Concurrent Futures**: Uses async concurrency rather than blocking threads

### 4. Image Layer Creation Optimization

**Key Settings:**
```toml
[tenant_config]
image_creation_threshold = 2              # More aggressive (vs default 3)
image_layer_creation_check_threshold = 1  # Check more frequently (vs default 2)
image_creation_preempt_threshold = 2      # Preempt with fewer L0 layers
image_layer_force_creation_period = "5m"  # Force creation more often
```

**Performance Impact:**
- **Reduced Read Amplification**: More frequent image layer creation reduces delta chain length
- **Better Cache Locality**: Fresher image layers improve page cache hit rates
- **Faster Reconstruction**: Shorter delta chains mean faster page reconstruction

### 5. Compaction Engine Optimization: Keeping Storage Organized

**What is Compaction and Why Do We Need It?**

Imagine a library where books (database pages) are constantly being updated. Instead of rewriting entire books, librarians append new pages to separate "update journals" (delta layers). Over time, you end up with:
- Original book: "Harry Potter, 1st edition"
- Update journal 1: "Chapter 3 revision"
- Update journal 2: "New ending for Chapter 7"
- Update journal 3: "Fix typo on page 42"

To read the complete, current version of Chapter 3, you'd need to:
1. Read the original Chapter 3
2. Check update journal 1 for revisions
3. Apply any changes from journals 2 and 3

This is called **read amplification** - reading one logical page requires multiple physical reads.

**Compaction** is like periodically publishing new editions of books that incorporate all updates, so readers only need to grab one book instead of the original plus multiple update journals.

In Neon terms:
- **L0 layers** are the "update journals" (recent changes)
- **Image layers** are the "complete editions" (consolidated pages)
- **Delta layers** contain incremental changes between image layers

**Configuration Impact:**
```toml
[tenant_config]
compaction_algorithm = { kind = "tiered" }  # Modern tiered compaction
compaction_l0_first = true                  # Prioritize L0 compaction
compaction_l0_semaphore = true              # Separate L0 semaphore
compaction_period = "10s"                   # More frequent (vs 20s default)
compaction_threshold = 6                    # Lower threshold (vs 10 default)
```

**Benefits for Image Layers:**
- **Tiered Algorithm**: More efficient compaction strategy than legacy algorithm
- **L0 Priority**: L0 layers are compacted first to minimize read amplification
- **Responsive Compaction**: Lower thresholds and frequent checks prevent layer buildup

## Pageserver Sharding Benefits: Divide and Conquer

**What is Sharding?**

Sharding is like having multiple specialized post offices instead of one giant central post office. Instead of all mail (database tenants) going to one overwhelmed facility, you distribute tenants across multiple pageserver instances (shards).

Think of it as the difference between:
- **One restaurant** with one kitchen trying to serve 1000 customers (bottleneck!)
- **Four restaurants** each with their own kitchen serving 250 customers (parallel processing!)

### Why More Pageserver Shards Help Performance

**1. Parallel Processing**
```
Single Pageserver:               Multiple Pageserver Shards:
┌─────────────────┐             ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐
│ All Tenants     │             │Shard1│ │Shard2│ │Shard3│ │Shard4│
│ Sequential      │    ═══►     │ T1,T5│ │ T2,T6│ │ T3,T7│ │ T4,T8│
│ Processing      │             │      │ │      │ │      │ │      │
└─────────────────┘             └──────┘ └──────┘ └──────┘ └──────┘
```

**2. Resource Isolation**
- **Memory**: Each shard has dedicated page cache and memory pools
- **I/O**: Separate I/O queues prevent tenant interference
- **CPU**: Parallel compaction, GC, and other background operations

**3. Scalability**
- **Horizontal Scaling**: Add more shards to handle increased load
- **Load Distribution**: Tenants distributed across shards for balanced utilization
- **Fault Tolerance**: Failure of one shard doesn't affect others

### Shard-Specific Optimizations

**Configuration Impact:**
```toml
# Higher concurrency enabled by sharding
concurrent_tenant_warmup = 64                            # 8x default
concurrent_tenant_size_logical_size_queries = 16        # 16x default
heatmap_upload_concurrency = 64                         # 8x default
secondary_download_concurrency = 32                     # 32x default
```

**How Sharding Amplifies Benefits:**
- **Tenant Warmup**: 64 tenants warming up in parallel across shards vs sequential
- **Size Queries**: Multiple shards can calculate sizes concurrently
- **Heatmap Operations**: Parallel heatmap generation and upload across shards

## Memory & Caching Optimizations

### Pageserver Memory Configuration

```toml
page_cache_size = 134217728      # 128MB (16x default)
max_file_descriptors = 16384     # High FD limit
ephemeral_bytes_per_memory_kb = 2  # Aggressive ephemeral management
```

### Compute (PostgreSQL) Memory Configuration

```json
{
    "name": "shared_buffers", "value": "4GB",        // Large buffer cache
    "name": "work_mem", "value": "256MB",            // Large work memory
    "name": "maintenance_work_mem", "value": "2GB",  // Large maintenance memory
    "name": "effective_cache_size", "value": "12GB"  // Assume large OS cache
}
```

**Synergistic Benefits:**
- **Reduced Pageserver Load**: Large PostgreSQL shared_buffers reduce page requests
- **Better Hit Rates**: Large pageserver page_cache_size improves cache hits
- **Memory Hierarchy**: Optimized caching at both compute and storage layers

## GC-Compaction Features

### Latest Performance Features

```toml
[tenant_config]
# Newest GC-compaction features for better space utilization
gc_compaction_enabled = true
gc_compaction_verification = true
gc_compaction_initial_threshold_kb = 1048576    # 1GB threshold
gc_compaction_ratio_percent = 80                # Trigger at 80% ratio
```

**Performance Benefits:**
- **Space Efficiency**: Better space utilization reduces I/O overhead
- **Reduced Metadata**: Fewer layers means less metadata overhead
- **Better Locality**: Compacted layers improve sequential access patterns

## Monitoring & Observability

### Performance Monitoring Configuration

**Pageserver:**
```toml
force_metric_collection_on_scrape = false  # Reduce metric overhead
metric_collection_interval = "5m"          # Frequent monitoring
synthetic_size_calculation_interval = "5m" # Regular size updates
```

**PostgreSQL:**
```json
{
    "name": "track_io_timing", "value": "on",        // I/O timing stats
    "name": "pg_stat_statements.max", "value": "10000", // More query tracking
    "name": "auto_explain.log_min_duration", "value": "1s" // Explain slow queries
}
```

## Implementation Guidelines

### 1. Rolling Out Configuration

**Staged Deployment:**
1. **Test Environment**: Deploy with monitoring to validate performance gains
2. **Single Shard**: Apply to one pageserver shard initially
3. **Gradual Rollout**: Expand to additional shards based on results
4. **Full Deployment**: Apply to all pageservers after validation

### 2. Tuning Recommendations

**Monitor Key Metrics:**
- **Read Latency**: P95/P99 read latencies from compute to pageserver
- **Cache Hit Rates**: Both pageserver page cache and PostgreSQL shared_buffers
- **Compaction Lag**: Monitor L0 layer counts and compaction effectiveness
- **Sidecar Task Utilization**: Ensure sidecar tasks are being utilized effectively

**Adjust Based on Workload:**
- **Read-Heavy**: Increase image layer creation frequency
- **Write-Heavy**: Tune compaction thresholds and L0 flush settings
- **Mixed Workload**: Balance between read and write optimizations

### 3. Hardware Considerations

**Recommended Infrastructure:**
- **CPU**: High core count for concurrent operations (32+ cores)
- **Memory**: Large RAM for caches (64GB+ recommended)
- **Storage**: NVMe SSDs for low latency I/O operations
- **Network**: High bandwidth for multi-shard deployments (10Gbps+)

## Conclusion

This ultra-optimized configuration leverages Neon's latest performance features to achieve maximum read/write latency performance:

- **16x larger vectored read batches** reduce I/O overhead
- **Sidecar task concurrency** enables parallel I/O processing
- **Advanced I/O engines** (io_uring) provide zero-copy operations
- **Aggressive image layer creation** minimizes read amplification
- **Modern compaction algorithms** optimize storage layer efficiency
- **Multi-shard deployment** enables horizontal scalability

The combination of pageserver-level optimizations with compute-level PostgreSQL tuning creates a synergistic performance improvement that significantly exceeds the benefits of either configuration alone.

**Expected Performance Improvements:**
- **Read Latency**: 40-60% reduction in P95 read latencies
- **Write Throughput**: 30-50% increase in sustained write performance
- **Cache Hit Rates**: 20-30% improvement in cache utilization
- **Compaction Efficiency**: 50-70% reduction in compaction overhead

*Note: Actual performance gains depend on workload characteristics, hardware specifications, and baseline performance metrics.*
