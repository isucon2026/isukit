# ISUCON trigger -> fix table

This is the diagnosis table referenced by SKILL.md. Every row requires literal tool output as evidence before acting.

### 1. alp (nginx access log)
| Signal | Diagnosis | Fix | Effort | Risk |
|---|---|---|---|---|
| High COUNT *and* high SUM on one URI | Highest-leverage target | Profile that handler w/ pprof or slow log next; don't guess | Low | none (diagnostic) |
| High AVG, low COUNT | Occasional severe delay: lock contention, cold cache, GC pause | Look for locking / rare-path N+1 / per-request expensive compute | Low | low priority, don't over-invest |
| URIs not aggregating (each id its own row) | Missing `-m` regex grouping | Add `-m` patterns for every dynamic segment as step 1 | Low | misreading ungrouped output burns early triage |
| Nonzero 5xx on an endpoint | App erroring under load (panic, DB conn exhaustion) | Cross-ref app log / journal at same timestamps | Low-Med | failed requests cost score directly, can cascade to fail |
| nginx absorbing SUM on static assets | Static served through app or slow disk | nginx try_files/sendfile, Cache-Control/ETag | Low | bench may expect specific headers/content-type |

### 2. pt-query-digest / slow query log
| Signal | Diagnosis | Fix | Effort | Risk |
|---|---|---|---|---|
| Huge Rows_examined, small Rows_sent, many executions | N+1 | Single `WHERE id IN (...)` / JOIN; bulk INSERT | Med | batching changes ordering/dedup semantics -> consistency check |
| EXPLAIN: possible_keys NULL / type ALL | No usable index | Composite index matching actual WHERE + ORDER BY column order | Low-Med | wrong column order gives ~nothing; write overhead on INSERT-heavy tables |
| GROUP BY/aggregate scanning millions when few rows matter | Denormalized accumulation | Dedup/compact the table via /initialize or migration | Med | MUST run inside /initialize or it's undone on reset |
| High Lock_time relative to Query_time | Lock contention (e.g. flock for consistency) | Row-level transactions / optimistic concurrency | Med-High | removing a lock reintroduces races the bench WILL catch |
| Query recomputing a derived value every request | Redundant recomputation | Compute once at the state-transition event, persist, read after | Med | must invalidate on EVERY mutation path or stale data fails validation |

ISUCON12 winners (NaruseJun): obtainPresent N+1 +5,954; gachaDraw N+1 +31,944.
ISUCON13: reference impl deliberately unindexed, 3-4x from indexing alone.
ISUCON12 講評: visit_history 3.2M->200K rows, player_score 3.7M->180K.

### 3. pprof / language profiler
| Signal | Diagnosis | Fix | Effort | Risk |
|---|---|---|---|---|
| One app function dominates cumulative CPU | Expensive user code on hot path (ID gen, hashing, format conv) | Cheaper algorithm (e.g. Snowflake ID vs DB round-trip) | Med | custom ID schemes break uniqueness/ordering assumptions |
| Serialization (JSON/protobuf) a large slice | Inefficient marshal path / redundant struct conversion | Faster JSON lib, fewer conversions, smaller payload | Low-Med | field ordering/precision may be validated byte-for-byte |
| Repeated identical pure computation (SHA256 of same image per request) | Missing memoization | Cache the deterministic value or precompute at write time | Low | must invalidate when the input changes |
| CPU spread thin, no dominant frame | Bottleneck moved off CPU to DB/IO, or CPU wins already taken | Go back to iostat/vmstat + alp + slow log | Low | wasting time micro-optimizing cheap functions |
| Mutex/block profile shows goroutines blocked | App-level lock contention serializing parallel requests | Narrow lock scope, shard state, singleflight | Med-High | removing sync reintroduces races under bench concurrency |

NaruseJun: generateID->Snowflake +16,183. Thundering herd on master_version cache -> singleflight
turned a 200k-270k swing into a reliable 270k+ band.

### 4. OS level
| Signal | Diagnosis | Fix | Effort | Risk |
|---|---|---|---|---|
| vmstat high `r` + %usr+%sys ~100% | CPU-bound | Go to pprof or DB query optimization; caching/IO fixes won't move it | Low | misattributing to IO wastes effort |
| vmstat high `b` + %iowait + iostat %util/await high | IO-bound, usually undersized buffer pool | Raise innodb_buffer_pool_size; batch writes | Low-Med | oversized pool -> OOM/swap; check free -h first |
| %iowait high but await normal, vmstat si/so nonzero | Memory pressure / swap thrash masquerading as IO | Cut memory footprint before touching disk config | Low->Med | any nonzero swap during a run is urgent |
| DB pegged while app servers idle | DB is the system-wide bottleneck | Split write-heavy vs read servers, or shard by natural key | High | app must route/shard correctly and stay consistent for the bench |
| A metric improves but score doesn't move | You fixed a non-bottleneck | Re-run full triage after EVERY fix — the bottleneck moves | Low (discipline) | most commonly reported mistake in the corpus |
| df trending to zero from logs | Verbose logging left on | Rotate/disable before scoring runs; keep slow log only during measurement windows | Low | turning it off blinds you — re-enable per measurement pass |

ISUCON12 winners: user-ID sharding 61,546 -> 162,000+.
ISUCON11 + ISUCON13 講評 both call out "load moves to the next bottleneck" as THE standard failure mode.

### 5. Benchmarker's own output
| Signal | Diagnosis | Fix | Effort | Risk |
|---|---|---|---|---|
| `ERR: validation:` / consistency-check failure | App state diverged from expectation: lost write, stale cache, async race | Trace the named field back to its write path; check cache invalidation | Med-High | #1 way caching turns into a score-destroying bug |
| Timeouts / context deadline exceeded, count rising | Endpoint exceeding the bench's response budget under load | Profile that endpoint; do NOT just add workers/threads | Low (diag) | rising timeouts hide a stability problem that bites at final scoring |
| Fail on post-contest restart despite a good live score | State doesn't survive cold restart; /initialize incomplete | Deliberately test restart -> bench -> bench during the contest | Med | invisible unless you restart on purpose |
| /initialize missing a required field or too slow | The initialize CONTRACT, not perf | Return exact response shape; use fastest reset (physical copy not mysqldump) | Med | "just barely" under limit when warm blows it when cold |
| Score swings on UNCHANGED code | Your own nondeterminism (rand, map order) or infra noise | Re-run 2-3x; hunt randomness in your hot path before blaming infra | Low (discipline) | mis-attributing noise to a fix burns the scarcest resource |

## Known traps (ranked by how often they appear in writeups)
1. Caching without invalidation correctness — the single most reported score-destroyer.
2. Never restarting during the contest (p1ass lost ISUCON10 qualification to exactly this).
3. Deleting logs instead of rotating/disabling — destroys your own diagnostics.
4. Fixing a resource that isn't the binding constraint.
5. Indexes that don't match the actual query shape (wrong composite column order).
6. Disk exhaustion from verbose logging left on through the final window.
7. Changing instance type / security groups / envcheck service = DQ territory (ISUCON13 notes).
8. Randomness in logic that should be deterministic — makes every measurement untrustworthy.
9. Any server operation after the end time.

## Sources
- ISUCON2026 regulations: https://isucon.net/archives/59966826.html
- ISUCON12 講評: https://isucon.net/archives/56850281.html
- ISUCON13 講評: https://isucon.net/archives/58001272.html
- ISUCON14 講評: https://isucon.net/archives/58869617.html
- ISUCON11 講評: https://isucon.net/archives/56044867.html
- ISUCON10 trouble postmortem: https://isucon.net/archives/55084867.html
- ISUCON13 cautionary_note: https://github.com/isucon/isucon13/blob/main/docs/cautionary_note.md
- NaruseJun (ISUCON12 winners): https://zenn.dev/tohutohu/articles/8c34d1187e1b21
- p1ass ISUCON10 postmortem: https://blog.p1ass.com/posts/isucon10/
- alp usage: https://zenn.dev/tkuchiki/articles/how-to-use-alp
- cheat sheet: https://gist.github.com/south37/d4a5a8158f49e067237c17d13ecab12a
