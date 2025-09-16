### MVCC

PostgreSQL utilizes MVCC (multi-version currency control) to prevent blocks from happening, so that several users can talk to the same data but have their own transactions going. 

For example, as a row is fetched into memory, if it gets `UPDATE`-ed or
`DELETE`-ed, PostgreSQL creates an additional "row" in the shared buffers with a new, sequential "Transaction ID". At each new query, as the query goes to fetch some rows from the memory buffer, Postgres checks:
1. Is each row's Transaction ID earlier (smaller than) my current Transaction ID?
2. Is each row's Transaction ID in the list of "currently still running transactions"?
3. Has each row been committed?

### Why `vacuum`?

Those transaction IDs keep counting up and up until a certain point (`xmax`, a system column for max transaction ID). This is why `vacuum` is needed: to prevent _transaction ID wraparound_. In short, it's job is to minimize tables from getting too big from all the various versions of those rows coexisting on the file system. 

### When `vacuum`  Isn't vacuuming, a study:
- We are going to create two tables, both with 6 `text` columns.
- The first will be made by a 5-column `insert` statement, following by an `alter table add column` + an `update` .
- The second will be made by a `create table as select`.
- We will explore the differences in bloat and the effects of vacuuming.

---
 Create first table:
```
create table padme (name text, age text, address text, story text, flavor text);
```

Insert 1 Million `text` records:
```
insert into padme (name,age,address,story,flavor)                                   
select 
	left(md5(random()::text),55)
	,left(md5(random()::text),55)
	,left(md5(random()::text),55)
	,left(md5(random()::text),55)
	,left(md5(random()::text),55)
from generate_series(1,10000000);
```

Check size:
```
 Schema |   Name    | Type  |  Owner   | Persistence | Access method |  Size   |
--------+-----------+-------+----------+-------------+---------------+---------+
 dummy  | padme     | table | postgres | permanent   | heap          | 1906 MB |
 
```

Add column and Update that value:
```
alter table padme add column jarjar varchar;
update padme set jarjar = left(md5(random()::text),55);
```

Check size:
```
 Schema |   Name    | Type  |  Owner   | Persistence | Access method |  Size   |
--------+-----------+-------+----------+-------------+---------------+---------+
 dummy  | padme     | table | postgres | permanent   | heap          | 4139 MB |
```

Check the amount of "dead"  tuples from that transaction:
```
select relname, n_live_tup, n_dead_tup, last_vacuum 
from pg_stat_all_tables where relname = 'padme';
 relname | n_live_tup | n_dead_tup | last_vacuum 
---------+------------+------------+-------------
 padme   |    9945501 |   10063853 | 
```
- We have doubled the number of rows in the table due to the `update` transaction. The same would be the case for a `delete`.

Run a regular `vacuum` :
```
select relname, n_live_tup, n_dead_tup, last_vacuum from pg_stat_all_tables where relname = 'badme';
 relname | n_live_tup | n_dead_tup | last_vacuum 
---------+------------+------------+-------------
 padme   |   10000000 |          0 | 
```

Great! Except our table is still bloated at `4139MiB`!

In comparison, let's say we made table `bananakin`, via `create table as select`. Essentially, this would be the same as creating the table with all 6 columns and running the same 10 million record `insert`:

```
create table dummy.bananakin (name,age,address,story,flavor,jarjar) as select ...
```

Further, we will run `vacuum full padme;`. They're now the same size. When we solely ran `vacuum`, we only seemed to reclaim the dead tuples, but now we've reclaimed physical space:
```
kitchen=# \d+
                                      List of relations
 Schema |   Name    | Type  |  Owner   | Persistence | Access method |  Size   | Description 
--------+-----------+-------+----------+-------------+---------------+---------+-------------
 dummy  | padme     | table | postgres | permanent   | heap          | 2232 MB | 
 dummy  | bananakin | table | postgres | permanent   | heap          | 2233 MB | 

```

`vacuum` = Optimizes for the query planner with better statistics. This means there are less "hint bits" to sift through. This helps your memory operations. It labels the tuples as reusable, meaning, those transaction IDs are reclaimed and able to be used for new `update` or `delete` transactions.

`vacuum full` = Reclaims physical disk, by doing the above but also removing the extra tuples.


More on  data page anatomy and transaction IDs below.


---

### Transaction IDs give us a WAL

The row's header holds "hint bits" that are pointers to if this transaction has been committed or not (added to the commit log). In order to be committed, this transaction must also be written to the WAL log on disk. There may be some confusion here. This means that the DML of the transaction is written to disk, i.e. the description of the changes on a particular row -- but the _change to the row itself is not yet written to disk_. This is how we de-couple the _sequential, low I/O write to an ever-growing WAL log_ from blocking the speed of our transactions in the user experience: we write a move reel, and then run it through the projector later on.


### Anatomy of a Data Page

A quick refresher on the russian doll ancestry of Postgres storage:

--------------------
 ```
 -- DB
 --- Table           : a table is comprised of 1 GB files
 ------ File         : a file is comprised of 8 KB pages
 -------- Page       : a page is comprised of rows and looks like:
 ----------- Row     
 
 Page:      [ Header | Row pointer | FREE SPACE | Row1 | Row2 | etc... ]
 Row:       [ Header | Field 1 | ... | Field N ]
 ```
 
 **Page Header** = contains "page LSN", the next byte after last byte of WAL record for last change to this page. Basically a pointer to the WAL log that
 says "this change updated this page". During a CHECKPOINT, when the page is written to disk (updating the actual files), the "page LSN" must be <= the
 "flushed LSN", i.e., the last change that we have already put into the disk. It also contains Row pointers to make looking up a particular row faster.
 
 **Row Header** = contains the transaction ids for MVCC and the "hint bits" described above. These "hint bits" are basicaly a 1 or a 0 if the transaction was committed or not. These hints exist to save PostgreSQL the round trip of going to the commit log per row per query.


