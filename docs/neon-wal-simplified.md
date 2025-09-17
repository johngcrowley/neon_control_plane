# Neon WAL System: Simplified Deep Dive

Read [this](https://github.com/neondatabase/neon/blob/85ce109361be068ff890f9fece786a81f0724136/docs/pageserver-compaction.md) excellent piece, first.

This document breaks down the most confusing parts of Neon's WAL system in simple terms.

## 1. L0 vs L1 Layers: The Filing Cabinet Analogy

### Think of it like organizing papers in a filing cabinet:

**L0 Layers = Messy Inbox**
- When WAL records come in, they get dumped into L0 layers
- These are "raw" - just WAL records in the order they arrived
- Like throwing all your mail into an inbox without sorting
- **Problem**: To find something specific, you have to dig through many piles

**L1 Layers = Organized Filing Cabinets**
- These are created by cleaning up and organizing multiple L0 layers
- WAL records are sorted, deduplicated, and efficiently indexed
- Like taking your messy inbox and filing everything alphabetically
- **Benefit**: Finding something is much faster

### Why L0 → L1 Compaction Happens

```
Problem: Too many L0 layers = Read Amplification
┌─────────────────────────────────────────────────────────┐
│ Want to read page 42? You need to check:               │
│ ├── L0-Layer-1  (scan all records for page 42)         │
│ ├── L0-Layer-2  (scan all records for page 42)         │
│ ├── L0-Layer-3  (scan all records for page 42)         │
│ ├── ...                                                 │
│ └── L0-Layer-50 (scan all records for page 42)         │
│                                                         │
│ Result: 50 disk reads just to get 1 page!              │
└─────────────────────────────────────────────────────────┘

Solution: L0 Compaction
┌─────────────────────────────────────────────────────────┐
│ Merge L0-Layer-1 through L0-Layer-10 into:             │
│ └── L1-Layer-1 (only records for pages 1-50, sorted)   │
│                                                         │
│ Result: 1 disk read to get any page in range 1-50!     │
└─────────────────────────────────────────────────────────┘
```

### Why Compaction is Intensive

1. **Read Multiple Files**: Must read all the L0 layers being merged
2. **Sort Everything**: WAL records must be sorted by (page, LSN)
3. **Remove Duplicates**: If page 42 was updated 5 times, keep only the final state
4. **Build New Index**: Create efficient lookup structure for the merged layer
5. **Write New File**: Write the organized L1 layer to storage
6. **Clean Up**: Delete the old L0 layers

**Real Example:**
```
Before Compaction:
├── L0-Layer-1: 50MB (contains updates to pages 1-100)
├── L0-Layer-2: 45MB (contains updates to pages 1-100)
├── L0-Layer-3: 48MB (contains updates to pages 1-100)
└── Total: 143MB across 3 files

After Compaction:
└── L1-Layer-1: 85MB (deduplicated, organized updates to pages 1-100)
   └── Savings: 58MB less storage + much faster reads
```

## 2. Key Space / LSN 2D System: The Coordinate System

### Think of Neon storage like a 2D grid:

```
                    LSN (Time Axis) →
                    1000   2000   3000   4000   5000
                     │      │      │      │      │
Key Space   page_1  ├──────┼──────┼──────┼──────┤
(Space      page_2  ├──────┼──────┼──────┼──────┤
Axis)       page_3  ├──────┼──────┼──────┼──────┤
↓           page_4  ├──────┼──────┼──────┼──────┤
            page_5  ├──────┼──────┼──────┼──────┤

Each cell (page_X, LSN_Y) represents the state of that page at that time
```

### Key Space = "Where" (Which table page)
- **Database OID**: Which database (e.g., 12345)
- **Relation OID**: Which table (e.g., users table = 16384)
- **Block Number**: Which 8KB page in that table (e.g., block 0, 1, 2...)

**Key Format**: `rel 12345/16384 blk 3`
- Database 12345, Table 16384, Page 3

### LSN = "When" (Point in time)
- Every change gets a sequential LSN number
- LSN 1000 happened before LSN 2000
- LSN represents exact moment in database history

### How WAL Records Find Their Key Space

When a WAL record arrives, it contains:

```
WAL Record Example:
┌──────────────────────────────────────────────────┐
│ Type: HEAP_UPDATE                                │
│ LSN: 5000                                        │
│ Transaction ID: 1001                             │
│ Database OID: 12345                              │  ← Identifies database
│ Relation OID: 16384                              │  ← Identifies table
│ Block Number: 3                                  │  ← Identifies page
│ Old Tuple: (id=42, balance=100)                 │
│ New Tuple: (id=42, balance=200)                 │
└──────────────────────────────────────────────────┘

Key Space Calculation:
Database: 12345
Table: 16384
Page: 3
→ Key: "rel 12345/16384 blk 3"
→ Coordinate: (rel 12345/16384 blk 3, LSN 5000)
```

### When Does WAL Go to a New Key Space?

**Same Key Space** (same coordinate):
```sql
UPDATE users SET balance = balance + 10 WHERE id = 42;  -- page 3
UPDATE users SET balance = balance + 20 WHERE id = 43;  -- page 3 (same page)
→ Both updates go to same key space: "rel 12345/16384 blk 3"
```

**Different Key Space** (different coordinate):
```sql
UPDATE users SET balance = balance + 10 WHERE id = 42;     -- page 3
UPDATE orders SET status = 'shipped' WHERE id = 100;       -- different table, page 5
→ First:  "rel 12345/16384 blk 3"  (users table, page 3)
→ Second: "rel 12345/16385 blk 5"  (orders table, page 5)
```

**New Page in Same Table**:
```sql
-- Users table grows, needs new page
INSERT INTO users (name, balance) VALUES ('New User', 1000);
→ If this creates page 4: "rel 12345/16384 blk 4"
```

### Large Table Update Scenario

User asks: "When ingesting a very large table that keeps updating the same area, what happens?"

**Example**: Bulk update to users table, pages 1-10 get updated repeatedly

```
Time 1 (LSN 1000-1100): Update all users in pages 1-10
Time 2 (LSN 1101-1200): Update same users again
Time 3 (LSN 1201-1300): Update same users again

Result:
┌─────────────────────────────────────────────────────────┐
│ L0-Layer-1: LSN 1000-1100 (pages 1-10 updated)        │
│ L0-Layer-2: LSN 1101-1200 (pages 1-10 updated again)  │
│ L0-Layer-3: LSN 1201-1300 (pages 1-10 updated again)  │
└─────────────────────────────────────────────────────────┘

Problem: Reading page 5 at LSN 1250 requires:
1. Check L0-Layer-3 for changes 1201-1300
2. Check L0-Layer-2 for changes 1101-1200
3. Check L0-Layer-1 for changes 1000-1100
4. Apply all changes in LSN order

Compaction helps:
└── L1-Layer-1: LSN 1000-1300 (pages 1-10, deduplicated)
   └── Only final state of each page kept
```

## 3. Byte Hexadecimal Offset Math: Simple Breakdown

### PostgreSQL LSN Format: `0/1A2B3C4D`

This looks scary but it's just a big number split in half:

```
LSN Format: HIGH/LOW
           ─┬─  ─┬─
            │    └── Low 32 bits (byte offset)
            └── High 32 bits (file/timeline number)
```

### Breaking Down `0/1A2B3C4D`:

**High Part**: `0`
- In decimal: 0
- This is the WAL file/segment number

**Low Part**: `1A2B3C4D`
- This is a hexadecimal number
- Let's convert to decimal step by step:

```
Hex: 1A2B3C4D
     │ │ │ │
     │ │ │ └── D = 13
     │ │ └──── C = 12
     │ └────── B = 11
     └──────── A = 10

Position values in hex:
1A2B3C4D = 1×16⁷ + A×16⁶ + 2×16⁵ + B×16⁴ + 3×16³ + C×16² + 4×16¹ + D×16⁰

Substituting A=10, B=11, C=12, D=13:
= 1×268435456 + 10×16777216 + 2×1048576 + 11×65536 + 3×4096 + 12×256 + 4×16 + 13×1
= 268435456 + 167772160 + 2097152 + 720896 + 12288 + 3072 + 64 + 13
= 439041101 (in decimal)
```

### What This Means:

`LSN 0/1A2B3C4D` means:
- **WAL File**: 0 (the first/current WAL file)
- **Byte Position**: 439,041,101 (byte offset within that file)

**Simple way to think about it:**
- It's like saying "Page 0, Line 439,041,101"
- The high part (0) is which book
- The low part (1A2B3C4D) is which line in that book

### Practical Example:

```
LSN Sequence:
0/1A2B3C4D → 0/1A2B3C4E → 0/1A2B3C4F → 0/1A2B3C50

In decimal:
439041101 → 439041102 → 439041103 → 439041104

This means:
- Each LSN is just the next byte position
- WAL records are written sequentially
- LSN differences show WAL record sizes
```

### WAL File Boundaries:

When WAL files reach 16MB (typical size), the high part increments:

```
End of file:   0/00FFFFFF (16MB - 1 byte)
Start of next: 1/00000000 (next file, byte 0)

So LSN progression:
0/00000000 → 0/00000001 → ... → 0/00FFFFFF → 1/00000000
```

## 4. Putting It All Together: Complete Example

Let's trace a complete transaction:

```sql
UPDATE users SET balance = balance + 100 WHERE id = 42;
```

### Step 1: WAL Record Creation
```
WAL Record:
├── LSN: 0/1A2B3C4D (file 0, byte 439041101)
├── Type: HEAP_UPDATE
├── Database: 12345
├── Table: 16384 (users)
├── Page: 3 (where user 42 lives)
├── Old tuple: (id=42, balance=500)
└── New tuple: (id=42, balance=600)
```

### Step 2: Key Space Assignment
```
Key Calculation:
├── Database OID: 12345
├── Relation OID: 16384
├── Block Number: 3
└── Result: "rel 12345/16384 blk 3"

2D Coordinate: (rel 12345/16384 blk 3, LSN 0/1A2B3C4D)
```

### Step 3: Layer Storage
```
WAL record gets buffered in current L0 layer:
└── L0-Layer-Current
    ├── LSN Range: (0/1A000000, 0/1A2FFFFF]
    ├── Contains: This update + thousands of other updates
    └── Index: (rel 12345/16384 blk 3, 0/1A2B3C4D) → byte offset 50234
```

### Step 4: Future Read
```sql
SELECT balance FROM users WHERE id = 42;
```

```
GetPage@LSN Request:
├── Key: "rel 12345/16384 blk 3"
├── Target LSN: 0/1A2B4000 (current time, after our update)

Pageserver Process:
1. Find image layer: Image-Layer-page_3@LSN_0/1A000000
2. Find delta layers: L0-Layer-Current (contains our update)
3. Reconstruct:
   ├── Start with image (balance=500)
   ├── Apply WAL at LSN 0/1A2B3C4D (balance=600)
   └── Result: Page showing balance=600
```

This is how Neon transforms a simple SQL UPDATE into a 2D coordinate system that enables time-travel, branching, and efficient storage!
