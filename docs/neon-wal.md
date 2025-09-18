# Neon PostgreSQL Storage Architecture: A Socratic Dialog

## Q: How is Neon different from traditional PostgreSQL storage?

**A:** Traditional PostgreSQL stores data in 8KB pages within table files on disk. Neon separates storage from compute - it takes PostgreSQL's WAL stream and reorganizes it into a cloud-native, layered storage system that can reconstruct any page at any LSN on demand.

## Q: What happens to the WAL in Neon's architecture?

**A:** Instead of applying WAL to data pages like traditional PostgreSQL, Neon's Pageserver ingests WAL records and organizes them into a multi-dimensional storage system:

```
Traditional PostgreSQL:
WAL → Apply to Pages → Store Pages on Disk

Neon Architecture:
WAL → Pageserver → Layer-based Storage → Reconstruct Pages on Demand
                     ↓
            ┌─────────────────┐
            │   L0 Layers     │  ← Fresh WAL records
            │   L1 Layers     │  ← Compacted deltas  
            │  Image Layers   │  ← Page snapshots
            └─────────────────┘
```

## Q: What are L0 layers and how do they handle incoming WAL?

**A:** L0 (Level 0) layers are the first landing place for incoming WAL records. They cover the entire key range and contain the most recent delta changes:

```
Fresh WAL Records → L0 Delta Layers
┌─────────────────────────────────────────────────────────┐
│ L0 Layer: covers ALL keys for LSN range 1000-2000       │
├─────────────────────────────────────────────────────────┤
│ Key Range: 0x000000...FFFFFF (entire database)          │
│ LSN Range: 0/1000 → 0/2000                             │
├─────────────────────────────────────────────────────────┤
│ Contents (WAL deltas):                                   │
│ ├── LSN 0/1000: UPDATE table 16384, page 100, row 5    │
│ ├── LSN 0/1050: INSERT table 16385, page 200, row 12   │  
│ ├── LSN 0/1100: DELETE table 16384, page 150, row 8    │
│ └── LSN 0/1500: UPDATE table 16386, page 50, row 3     │
└─────────────────────────────────────────────────────────┘

Multiple L0 layers accumulate:
L0_1: LSN 1000-2000 (all keys)
L0_2: LSN 2000-3000 (all keys) 
L0_3: LSN 3000-4000 (all keys)
```

## Q: Why not keep everything in L0 layers?

**A:** Every read must search through all L0 files plus any relevant L1 files, and as the number of L0 files increases, so does read amplification. Too many L0 layers slow down reads dramatically.

## Q: How do L1 layers solve this problem?

**A:** L0 layers are compacted into more efficient L1 files. L1 files cover only part of the key range, allowing for more targeted searches:

```
L0 Compaction Process:
┌─────────────────────────────────────────┐
│ L0_1: Keys[0..FFFF], LSN[1000-2000]     │
│ L0_2: Keys[0..FFFF], LSN[2000-3000]     │  
│ L0_3: Keys[0..FFFF], LSN[3000-4000]     │
└─────────────────────────────────────────┘
                    ↓ Compaction
┌─────────────────────────────────────────┐
│ L1 Delta Layers (Partitioned by Key):   │
├─────────────────────────────────────────┤
│ L1_A: Keys[0..3FFF], LSN[1000-4000]     │  ← Table 16384 changes
│ L1_B: Keys[4000..7FFF], LSN[1000-4000]  │  ← Table 16385 changes
│ L1_C: Keys[8000..BFFF], LSN[1000-4000]  │  ← Table 16386 changes  
│ L1_D: Keys[C000..FFFF], LSN[1000-4000]  │  ← Other tables
└─────────────────────────────────────────┘

Benefits:
- Fewer layers to search per query
- Only search relevant key ranges
- Better compression (related changes together)
```

## Q: How do keys map to PostgreSQL concepts?

**A:** In Neon, a "key" encodes the PostgreSQL relation and page information:

```
Neon Key Format:
┌─────────────────────────────────────────────────────────┐
│ Key = f(Relation OID, Page Number, Additional Metadata)  │
├─────────────────────────────────────────────────────────┤
│ Example Key Ranges:                                      │
│ ├── 0x1000-0x1FFF → Table 16384 (users)                │
│ ├── 0x2000-0x2FFF → Table 16385 (orders)               │
│ └── 0x3000-0x3FFF → Index 16387 (users_pkey)           │
└─────────────────────────────────────────────────────────┘

Traditional PostgreSQL WAL:
"Relation 16384, Block 150, Offset 5"

Becomes Neon Key:
Key 0x1096 (encodes: relation 16384 + page 150)
```

## Q: What are image layers and when are they created?

**A:** Image layers contain a "snapshot" of a range of keys at a particular LSN, while delta layers contain WAL records applicable to a range of keys, in a range of LSNs:

```
Image Layer Creation:
┌─────────────────────────────────────────────────────────┐
│ After many delta layers accumulate:                      │
├─────────────────────────────────────────────────────────┤
│ Delta History:                                           │
│ ├── L1_A: Keys[1000..1FFF], LSN[0-5000]    (500 changes)│
│ ├── L1_B: Keys[1000..1FFF], LSN[5000-10000] (400 changes)│
│ └── L1_C: Keys[1000..1FFF], LSN[10000-15000] (600 changes)│
├─────────────────────────────────────────────────────────┤
│ Compaction creates Image Layer:                          │
│ IMG_1: Keys[1000..1FFF] @ LSN 15000                     │
│ ├── Key 1000: [8KB page data] ← Reconstructed page      │
│ ├── Key 1001: [8KB page data]                           │
│ └── Key 1FFF: [8KB page data]                           │
└─────────────────────────────────────────────────────────┘

Benefits of Image Layers:
- No need to replay long delta chains
- Faster page reconstruction for old LSNs  
- Enables garbage collection of old deltas
```

## Q: How does Neon reconstruct a page at a specific LSN?

**A:** The page server searches the layer map for all relevant layers and reconstructs the page by applying deltas on top of the most recent image file:

```
Page Reconstruction Algorithm:
Request: Get page for Key 0x1096 at LSN 12500

Layer Map Search (2D: Key Range × LSN Range):
┌──────────────────