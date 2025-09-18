# PostgreSQL WAL Architecture: A Socratic Dialog

## Q: How does PostgreSQL track changes to data on disk?

**A:** PostgreSQL uses a Write-Ahead Log (WAL) system. When you execute a SQL statement, it doesn't immediately change the data files. Instead, it first writes a description of the change to the WAL, then modifies the data in memory.

## Q: What exactly gets stored in the WAL?

**A:** The WAL doesn't store your SQL statement. Instead, it stores binary-encoded instructions about exactly what to change where:

```
SQL Statement:
UPDATE users SET name = 'John' WHERE id = 1;

Gets converted to WAL record (binary):
┌─────────────────────────────────────┐
│ WAL Record Header (24 bytes)        │
├─────────────────────────────────────┤
│ xl_tot_len: 59                      │  (total record length)
│ xl_xid: 734                         │  (transaction ID)  
│ xl_prev: 0/01518C18                 │  (previous LSN)
│ xl_info: HEAP_UPDATE                │  (operation type)
│ xl_rmid: RM_HEAP                    │  (resource manager)
│ xl_crc: [checksum]                  │  (integrity check)
├─────────────────────────────────────┤
│ Main Data:                          │
│ ├── Relation OID: 16384             │  (which table)
│ ├── Block number: 150               │  (which page)
│ ├── Offset: 5                       │  (which row)
│ ├── Old tuple: [binary data]        │  (before image)
│ └── New tuple: [binary data]        │  (after image)
└─────────────────────────────────────┘
```

## Q: How is this WAL stream organized?

**A:** The WAL is an append-only stream that gets chunked into segment files:

```
WAL Stream (continuous):
[Record1][Record2][Record3][Record4][Record5][Record6]...
    ↓
Chunked into segment files (16MB each):
┌─────────────────────────────────────┐
│ 000000010000000000000001            │  ← Segment file 1
│ [Record1][Record2][Record3]         │
└─────────────────────────────────────┘
┌─────────────────────────────────────┐
│ 000000010000000000000002            │  ← Segment file 2  
│ [Record4][Record5][Record6]         │
└─────────────────────────────────────┘
```

## Q: What is an LSN and how does it work?

**A:** LSN (Log Sequence Number) is a pointer to a specific location in the WAL stream:

```
LSN Format: timeline/offset
Example: 1/A4B6C8D0

Breakdown:
├── 1        = WAL segment number (file 000000010000000000000001)
└── A4B6C8D0 = Hexadecimal byte offset within that segment

Converting hex to decimal:
A4B6C8D0₁₆ = 2,762,180,816₁₀ bytes into segment file 1

So LSN 1/A4B6C8D0 means:
"Byte position 2,762,180,816 in segment file 000000010000000000000001"
```

## Q: How is the actual data organized on disk?

**A:** PostgreSQL organizes data in a strict hierarchy:

```
Database Storage Hierarchy:
┌─────────────────────────────────────┐
│ Table: users                        │
├─────────────────────────────────────┤
│ ├── File: 16384 (relation OID)      │  ← One file per table
│ │   ├── Page 0 (8KB)               │  ← Pages within file
│ │   │   ├── Row 1                   │  ← Rows within page
│ │   │   ├── Row 2                   │
│ │   │   └── Row N                   │
│ │   ├── Page 1 (8KB)               │
│ │   └── Page N (8KB)               │
│ ├── File: 16384_fsm                 │  ← Free space map
│ └── File: 16384_vm                  │  ← Visibility map
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│ Table: customers                    │
├─────────────────────────────────────┤
│ ├── File: 16385 (different OID!)    │  ← Separate file
│ │   ├── Page 0 (8KB)               │  ← Own page numbering
│ │   └── Page 1 (8KB)               │
│ └── ...                             │
└─────────────────────────────────────┘
```

## Q: How does WAL connect to the physical data?

**A:** Each WAL record contains precise coordinates to locate data:

```
WAL Record says: "Relation 16384, Block 150, Offset 5"
                          ↓
Physical Location:
┌─────────────────────────────────────┐
│ File: 16384 (users table)           │
│ ├── Page 0                          │
│ ├── Page 1                          │  
│ ├── ...                             │
│ ├── Page 150  ← Target page         │
│ │   ├── Row 1                       │
│ │   ├── Row 2                       │
│ │   ├── Row 3                       │
│ │   ├── Row 4                       │
│ │   ├── Row 5   ← Target row (offset 5) │
│ │   └── ...                         │
│ └── ...                             │
└─────────────────────────────────────┘

The coordinates are unambiguous:
- Relation 16384 = exactly one table/index
- Block 150 = exactly one 8KB page within that table
- Offset 5 = exactly one row within that page
```

## Q: How does this all work together during a transaction?

**A:** Here's the complete flow:

```
Transaction Flow:
1. SQL: UPDATE users SET name = 'John' WHERE id = 1;
           ↓
2. Create WAL record at next LSN (e.g., 1/A4B6C8D0)
   ┌─────────────────────────────────────┐
   │ WAL Record:                         │
   │ ├── Relation: 16384                 │
   │ ├── Block: 150                      │ 
   │ ├── Offset: 5                       │
   │ ├── Old data: [binary]              │
   │ └── New data: [binary]              │
   └─────────────────────────────────────┘
           ↓
3. Append WAL record to segment file
   000000010000000000000001 at byte A4B6C8D0
           ↓  
4. Modify data page 150 in file 16384
   ┌─────────────────────────────────────┐
   │ Page 150 in file 16384:             │
   │ ├── pd_lsn: 1/A4B6C8D0             │ ← Track last change
   │ ├── Row 5: name = 'John'            │ ← Updated data
   │ └── ...                             │
   └─────────────────────────────────────┘
           ↓
5. Eventually write dirty page to disk
```

## Q: What makes this design powerful?

**A:** This architecture enables several critical features:

- **Crash Recovery**: Replay WAL records from last checkpoint to restore consistent state
- **Replication**: Stream WAL records to standby servers  
- **Point-in-Time Recovery**: Replay WAL up to any specific LSN
- **Transaction Isolation**: Each page tracks its last modification LSN
- **Durability**: Changes are logged before being applied to data

The key insight is that **LSN is just a bookmark** in the WAL stream, while the **WAL record at that LSN contains the precise instructions** for what to change where in the physical data files.