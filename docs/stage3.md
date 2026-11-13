# Stage 3: Coalescer, L1 data cache, shared memory

Written in ASD-STE100 Simplified Technical English.

## 1. Result

- The load/store unit (LSU) no longer sends one request for each lane. A
  **coalescer** puts all lanes that use the same 32-byte line into one
  transaction. A warp that reads 8 consecutive words makes 1 transaction,
  not 8.
- A **2 KB L1 data cache** (2-way, 32 sets, 32-byte lines, LRU) holds the
  lines that the core reads. It is write-through with no write-allocate.
- **Shared memory**: 1 KB for each block, in 8 banks, with two new
  instructions (`lds`, `sts`). The LSU finds bank conflicts and serves the
  lanes over more cycles. Lanes that read the same word share one access
  (broadcast).
- The memory port now moves 32-byte lines, with a word mask for writes.
- New perf counters: memory transactions, L1 hits, L1 misses, bank-conflict
  cycles.
- **The golden model computes the exact number of transactions and of
  bank-conflict cycles.** The testbench checks both numbers in each test,
  like the warp-instruction count.
- All 71 tests pass on Icarus Verilog and on Vivado xsim.

## 2. Commands

No change. `.\scripts\run_tests.ps1` builds and runs all tests. The result
line of each test now also shows `txn`, `l1_hit`, `l1_miss` and
`bank_conflict`.

## 3. What changed

| File | Change |
|---|---|
| `rtl/core/lsu.v` | Rewritten, 237 lines. Coalescer, cache control (FSM), shared-memory bank arbiter. |
| `rtl/core/l1_cache.v` | New, 81 lines. Tags, data, valid and LRU bits. |
| `rtl/core/smem.v` | New, 32 lines. 8 banks of 32 words, one port each, synchronous read. |
| `rtl/core/sm_core.v` | 256-bit memory port, `lds`/`sts`, error code 5, four new counters. |
| `rtl/core/decode.v` | `is_shared` output. `ld`/`lds` and `st`/`sts` share the load and store paths. |
| `tools/golden.py` | Shared memory, error code 5, and the `txn` and `bank_conflict` counts. |
| `tools/build_tests.py` | Random gather loads, scatter stores, shared-memory loads and stores. |
| `dv/tb_core.sv` | Line-based memory model. Checks the two new counts. |

## 4. How it works

### 4.1 The LSU

```
  EX --> LSU (one warp instruction at a time)
          |
          +-- global (ld/st) --> coalescer --> L1 cache --> memory port (32-byte lines)
          |
          +-- shared (lds/sts) --> bank arbiter --> 8 banks x 32 words
          |
          +--> one register write for all lanes at the end of a load
```

### 4.2 The coalescer

Each cycle, the coalescer takes the lowest lane that still waits. This lane
is the leader. All waiting lanes with the same line address (address bits
[31:5]) as the leader go into the same transaction.

| Transaction | What happens | Cycles |
|---|---|---|
| Load, hit | The lanes take their words from the cache line. | 1 |
| Load, miss | Read the line from memory, put it in the cache, give the lanes their words from the returned line. | memory latency + 2 |
| Store | Write the line to memory with an 8-bit word mask. If the line is in the cache, update the same words there. | 1 (if the memory is ready) |

The number of transactions for one instruction is the number of different
lines that its active lanes touch. That is a property of the program, not
of the hardware timing, so the golden model can compute it exactly.

| Lane pattern (`coalesce.s`) | Transactions per warp |
|---|---|
| Unit stride, line-aligned | 1 |
| Unit stride, one word late | 2 |
| Stride 2 words | 2 |
| Stride 8 words | 8 |
| All lanes read one word | 1 |
| Lanes reversed inside a line | 1 |

### 4.3 The L1 cache

| Parameter | Value |
|---|---|
| Size | 2 KB |
| Line | 32 bytes (8 words = one word for each lane) |
| Organization | 2-way set associative, 32 sets |
| Address split | tag [31:10], set [9:5], word [4:2] |
| Replacement | An invalid way first, else LRU (1 bit per set) |
| Write policy | Write-through, no write-allocate |
| Misses in flight | 1 (blocking) |

### 4.4 Shared memory and bank conflicts

Shared memory is 256 words in 8 banks. Word `i` is in bank `i % 8`, at row
`i / 8`. Each bank has one port, so it can read or write one word in each
cycle.

Each cycle, for each bank, the arbiter takes the lowest waiting lane that
uses this bank. All waiting lanes that use the same word go with it. Lanes
that use a different word in the same bank wait for the next cycle.

```
  stride 8 words: all 8 lanes in bank 0, 8 different rows
  cycle:   1    2    3    4    5    6    7    8      -> 7 extra cycles
  lane:    0    1    2    3    4    5    6    7

  stride 9 words: lanes in banks 0,1,2,...,7       -> 1 cycle, no conflict
```

An `lds`/`sts` takes as many cycles as the busiest bank has different
words. The golden model computes the same number.

| Lane pattern (`smem_bank.s`) | Extra cycles per warp |
|---|---|
| Stride 1 word | 0 |
| Stride 2 words | 1 |
| Stride 8 words | 7 |
| Stride 9 words | 0 |
| All lanes read one word (broadcast) | 0 |
| 2 different words in one bank | 1 |

## 5. Decisions

### 5.1 Line size = one word for each lane

A 32-byte line holds exactly the 8 words of a unit-stride warp access. A
smaller line breaks the most common access into 2 transactions. A larger
line moves more data for each miss, and the extra words are often not used.

### 5.2 Write-through and no write-allocate

The cache never holds data that memory does not have. Thus:

- There is no dirty bit, no write-back, and no eviction path to memory.
- Stage 4 has 2 cores. Each core's L1 can only hold old (stale) data, never
  newer data than memory. An invalidate at kernel start is enough for the
  GPU memory model, where blocks do not share written data inside one
  kernel. That is much simpler than the MESI protocol in TinyTrust.
- The cost is memory traffic: each store goes to memory. GPU stores are
  usually streaming (written once), so a write-back cache would not save
  much for them.

A store miss does not bring the line into the cache. A kernel usually
writes its output and does not read it back.

### 5.3 One miss at a time

The LSU stops at a miss and waits for the line. A non-blocking cache needs
MSHRs (miss status registers) to track many misses, and responses can come
back for different warps in a different order. That is the next large
improvement, but it is a large block. Other warps still run ALU
instructions during a miss, so the core is not idle.

### 5.4 Shared memory in the LSU

Shared memory uses the same LSU, the same register write port, and the
same `busy` signal as global memory. Real GPUs do the same: NVIDIA's L1
and shared memory are one SRAM with one pipeline. The cost is that a
shared access waits while a global miss is in progress.

### 5.5 The model computes the counts

The number of transactions and bank-conflict cycles depends only on the
addresses of the active lanes. It does not depend on timing. Thus the
golden model can compute them, and the testbench checks them exactly. A
coalescer bug that makes too many transactions gives correct data, so a
data check alone cannot find it. The count check finds it.

The L1 hit and miss counts depend on the order in which warps run. The
model does not know this order, so the testbench prints them but does not
check them.

### 5.6 Errors

A shared address of 1024 or more stops the core with error code 5. The
hardware does not wrap the address, because a wrapped address writes a
different thread's data and gives a wrong result with no error.

## 6. Numbers

### 6.1 The old LSU and the new LSU

The stage 1 LSU sent one request for each lane. Stage 2 did not change it.

| Test | Stage 1 cycles | Stage 3 cycles | Speedup | Requests (stage 1) | Transactions (stage 3) |
|---|---|---|---|---|---|
| matmul | 2146 | 893 | 2.4x | 1088 | 136 |
| matmul_1warp | 3216 | 1832 | 1.8x | 1088 | 136 |
| vec_add | 808 | 504 | 1.6x | 384 | 48 |
| vec_add_slow (20-cycle memory) | 1439 | 1023 | 1.4x | 384 | 48 |
| loop_sum | 1436 | 770 | 1.9x | | 88 |

In matmul, 112 of the 128 load transactions hit in L1: all 4 warps read the
same rows of A and the same columns of B.

### 6.2 Bank conflicts: transpose

| Test | Shared row stride | Bank-conflict cycles | Cycles |
|---|---|---|---|
| transpose | 8 words | 112 | 568 |
| transpose_pad | 9 words | 0 | 456 |

One pad word for each row of the shared tile removes all conflicts and
saves 20% of the cycles. This is the usual fix on real GPUs.

### 6.3 L1 replacement: l1_thrash

Three lines go into the same 2-way set. One warp, so the order is fixed.

| Access order | Result |
|---|---|
| A B C A B C ... (4 times) | 12 misses: LRU always evicts the line that comes next |
| A B A B ... (4 times) | 2 misses, then 6 hits |
| A C A C ... (4 times) | A hits, so B becomes the LRU line. C replaces B: 1 miss, then 7 hits |

The RTL counts 13 hits and 15 misses, as expected. The test sets
`.expect_l1 13 15`, and the testbench checks the two counts. This is the
only kind of test where the L1 counts are fixed: one warp, so the access
order does not depend on the scheduler.

The third phase is necessary. A small Python model of the set showed that
phases 1 and 2 give 6 hits and 14 misses also when a hit does not update
the LRU bit. Phase 3 gives 12 hits and 16 misses with that bug.

### 6.4 Shared memory is not always faster

| Test | Cycles | Global transactions | Bank conflicts |
|---|---|---|---|
| matmul (global memory + L1) | 893 | 136 | 0 |
| matmul_smem (tiles in shared memory) | 1166 | 32 | 0 |

matmul_smem makes 4x fewer memory transactions, but it is 30% slower. The
reasons:

- The matrices are small (2 x 256 bytes). They fit in the L1, so matmul
  already hits on 112 of 128 loads.
- An `lds` keeps the LSU busy for one more cycle than an L1 hit. The bank
  memory has a synchronous read, so the data comes one cycle after the
  access.
- matmul_smem has more instructions (the copy into shared memory) and a
  `bar`.

Shared memory helps when the data does not fit in the L1, or when many
blocks compete for the L1. On this small test, the cache does the work.
This is an honest result, and it is a good interview example: measure, do
not assume.

## 7. Verification

### 7.1 Tests

| Kind | Tests | What they cover |
|---|---|---|
| Coalescer | coalesce | 6 lane patterns; store to one word from 8 lanes |
| L1 | l1_reuse, l1_thrash | Hits, store update of a cached line, partial word mask, eviction, LRU, tag check |
| Shared memory | smem_reverse, smem_bank, smem_reduce | Exchange across warps with bar, 6 bank patterns, a tree reduction with divergence and bar |
| Kernels | matmul_smem, transpose, transpose_pad | Tiling, conflicts, padding |
| Negative | err_smem | Error code 5 |
| Random straight-line | rand_00..19 | Gather loads, scatter stores into a line for each warp, shared loads and stores, a shared table read at random addresses after bar |
| Random with branches | rbr_00..19 | Gather loads, shared loads and stores in divergent paths |

### 7.2 Mutation checks

| Mutant | Bug | Tests that fail (of 71) |
|---|---|---|
| `no_coalesce` | One transaction for each lane | 67 (count check) |
| `store_low_wins` | The lowest lane wins when lanes store to one word | 15 |
| `ld_word_by_lane` | A lane takes word `lane` of the line, not its own word | 43 |
| `no_store_update` | A store does not update a cached line | 7 |
| `hit_way_swap` | A hit returns the data of the other way | 48 |
| `tag_2bits` | The tag check of way 0 uses only 2 bits | 42 |
| `fill_no_valid` | A fill into way 1 does not set the valid bit | 1 (l1_thrash) |
| `no_lru_touch` | A load hit does not update LRU | 1 (l1_thrash) |
| `smem_serial` | Shared memory serves one lane per cycle | 46 (count check) |
| `smem_no_row_check` | A bank serves all its lanes the leader's word | 34 |
| `conflict_count_all` | The first bank cycle also counts as a conflict | 46 |
| `no_oob_check` | No error for a shared address past 1 KB | 1 (err_smem) |
| `lsu_lane_mask` | Load data goes to inactive lanes too | 15 |

The unchanged RTL passes all 71 tests.

Three results needed changes:

- **`store_low_wins` failed only 1 test at first.** The random programs
  never let two lanes of one store write the same word. Now each warp of a
  random program has its own line for scatter stores (random words, so
  lanes often hit the same word). The mutant now fails 15 tests.
- **`fill_no_valid` passed all tests.** It is a performance bug: the data
  stays correct, and only the miss count changes. The new `.expect_l1`
  directive lets a test give the expected L1 counts, when the access order
  is fixed. l1_thrash uses it.
- **`no_lru_touch` passed the first l1_thrash.** See section 6.3: phase 3
  was added for it.

Mutants that only change timing and never data or counts are possible.
For example, the arbiter could take the highest lane as the bank leader:
the number of cycles is the same, and the data is the same. Such a mutant
is equivalent, and no test can find it.

## 8. Limits of stage 3

- One miss at a time (no MSHRs). Other warps' memory instructions wait.
- The LSU handles one warp instruction at a time.
- An `lds` takes one cycle more than an L1 hit.
- The cache lookup is combinational from flip-flop arrays. An SRAM-based
  cache has a synchronous read and needs one more pipeline stage. Stage 6
  (synthesis) will show the cost.
- No invalidate yet. Stage 4 adds it at kernel start, for 2 cores.

## 9. Interview questions

**Q: What is memory coalescing?**
A: The lanes of a warp make their accesses at the same time. If the
addresses fall in the same cache line, the hardware merges them into one
transaction. My coalescer takes the lowest waiting lane, groups all lanes
in its 32-byte line, and repeats. A unit-stride warp is 1 transaction; a
stride of 8 words is 8.

**Q: What is a bank conflict, and how do you remove it?**
A: Shared memory is split into banks, and each bank can serve one word per
cycle. If two lanes need different words in the same bank, the access takes
two cycles. Lanes that need the same word do not conflict: they share the
read (broadcast). The usual fix is padding: a tile with rows of 9 words
instead of 8 puts a column on 8 different banks. In my transpose test that
removes 112 conflict cycles.

**Q: Why write-through for a GPU L1?**
A: GPU L1 caches are usually not coherent. With write-through, the L1 never
holds data that is newer than memory. To see another core's writes, it is
enough to invalidate the L1 at a kernel boundary. A write-back L1 would need
a flush or a coherence protocol.

**Q: How do you verify a coalescer? The data is correct even if it does not coalesce.**
A: The number of transactions depends only on the lane addresses, so my
golden model computes it, and the testbench checks it exactly in every
test. A mutant that sends one transaction for each lane gives correct data,
but the count check fails it in 67 of 71 tests.

**Q: Is shared memory always faster than the L1?**
A: No. My tiled matmul in shared memory is 30% slower than the plain
version, because the small matrices already fit in the L1, and the shared
path has one more cycle of latency. Shared memory wins when the working
set does not fit in the cache or many blocks fight for it.

**Q: What would you build next in this memory system?**
A: A non-blocking L1 with MSHRs. Today one miss stops all memory
instructions of all warps. With MSHRs, hits from other warps go on during
a miss, and several misses overlap their latency.
