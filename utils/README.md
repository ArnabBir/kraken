## Utils Module

Foundational utility packages used pervasively across Kraken services. These packages provide focused, dependency-light building blocks: configuration loading, HTTP client ergonomics, structured error handling, synchronization primitives, bandwidth control, in‑memory data structures, logging wrappers, and test helpers. This README is a technical reference for contributors extending or reusing these utilities.

---
### 1. Package Index

| Package | Path | Core Responsibility |
|---------|------|---------------------|
| `bandwidth` | `utils/bandwidth` | Token-bucket ingress/egress rate limiting (bits/sec) |
| `bitsetutil` | `utils/bitsetutil` | Bitset helpers (peer piece maps etc.) |
| `configutil` | `utils/configutil` | Hierarchical YAML load + deep merge + validation |
| `dedup` | `utils/dedup` | De-duplicate concurrent tasks + interval-trigger GC |
| `diskspaceutil` | `utils/diskspaceutil` | Filesystem capacity & free space queries |
| `dockerutil` | `utils/dockerutil` | Docker daemon interaction helpers |
| `errutil` | `utils/errutil` | Error aggregation / multi-error utilities |
| `flagutil` | `utils/flagutil` | CLI flag processing helpers |
| `handler` | `utils/handler` | HTTP error wrapping and ergonomic handler pattern |
| `heap` | `utils/heap` | Priority queue abstraction (min-heap) |
| `httputil` | `utils/httputil` | Robust HTTP client (retry, backoff, TLS, polling) + request parsing |
| `listener` | `utils/listener` | Network listener helpers, config parsing |
| `lockermap` | `utils/lockermap` | Per-key lock map for fine-grained mutual exclusion |
| `log` | `utils/log` | Global zap logger wrapper / migration layer |
| `memsize` | `utils/memsize` | Human-readable memory & bit rate formatting, unit constants |
| `mockutil` | `utils/mockutil` | Test mocks utilities (gomock integration) |
| `netutil` | `utils/netutil` | Network address discovery (local IP) |
| `osutil` | `utils/osutil` | OS-level helpers (signals, process) |
| `randutil` | `utils/randutil` | Randomization helpers |
| `rwutil` | `utils/rwutil` | I/O helpers (capped buffer, pipe patterns) |
| `stringset` | `utils/stringset` | Lightweight set implementation on map[string]struct{} |
| `syncutil` | `utils/syncutil` | Atomic counters / concurrency metrics helpers |
| `testutil` | `utils/testutil` | Test scaffolding (HTTP servers, cleanup chaining) |
| `timeutil` | `utils/timeutil` | Timers, elapsed tracking wrappers |

Only a subset is elaborated below (representative critical packages). Others follow similar minimalist design: one responsibility, no external heavy dependencies, explicit error returns.

---
### 2. Design Principles
1. Zero or minimal external dependencies (standard library + select vetted libs like zap, backoff, cenkalti).
2. Clear invariants and explicit error signaling — never panic except at initialization or truly unrecoverable states (e.g., logger configuration).
3. Concurrency-safe where required; lock granularity chosen to avoid global contention (e.g., dedup limiter per-input condition variable, interval trap).
4. Performance-conscious: avoid allocations in hot paths; use simple structs & slices over generics (historical Go versions compatibility).
5. Test-first: Each package accompanied by targeted *_test.go verifying correctness, race behavior, and edge cases.

---
### 3. Detailed Package Explanations

#### 3.1 `httputil`
High-level resilient HTTP client API layered over `net/http`:

Key Exposed Types / Functions:
| Symbol | Purpose |
|--------|---------|
| `Send(method, url, ...SendOption)` | Core request builder with accepted status validation, retries, backoff, TLS override |
| `Get/Post/Patch/Delete/...` | Convenience wrappers |
| `SendOption` | Functional option to configure body, timeout, headers, accepted codes, redirect policy, retries, context, transport, TLS, HTTP fallback toggle |
| `SendRetry` + `RetryBackoff/RetryCodes` | Exponential or constant backoff control and explicit additional retryable status codes |
| `StatusError` | Error type representing unexpected HTTP status; retains response dump for diagnostics |
| `NetworkError` | Transport-level failure (DNS, connection issues) |
| Helpers: `IsNotFound/IsConflict/IsAccepted/IsRetryable` | Classification functions |
| `PollAccepted` | 202 polling loop (long-running async operations) |
| Request parsing: `ParseParam`, `GetQueryArg`, `ParseDigest` | Uniform error mapping to 400 with contextual messages |

Retry Conditions:
* By default only 200 accepted; custom statuses added via `SendAcceptedCodes`.
* Retries occur on `NetworkError`, 429, 502, 503, 504, and any extra codes flagged.
* Backoff strategy defaults to Stop (no retry) unless `SendRetry` applied; typical config: constant 250ms max 2 attempts.

Fallback-to-HTTP Logic (during TLS migration):
* If HTTPS request errors and fallback enabled (disabled by default in code snippet via `httpFallbackDisabled: true` in default opts) attempt same request downgrading scheme.
* Combined error message preserves original HTTPS failure for root cause analysis.

Robustness Considerations:
* Body read/dump in `NewStatusError` ensures debugging details (bounded by response size of endpoint; consider future streaming if large bodies expected).
* Context propagation via `SendContext` supports cancellation and deadlines.

#### 3.2 `configutil`
Hierarchical YAML configuration loader with single-chain inheritance and deep merge semantics:

Mechanics:
1. `Load(filename, &cfg)` → `resolveExtends` recursively traverses `extends` chain (linked list only; no DAG) building ordered list base→leaf.
2. Sequential YAML unmarshal merges maps, overwrites arrays (last writer wins), setting scalar fields each pass.
3. Final merged struct validated via `validator.v2`; failures wrapped in `ValidationError` exposing per-field errors.

Constraints / Invariants:
* Cycle detection via `seen` `stringset.Set`; encountering previously seen path → `ErrCycleRef`.
* Relative paths in `extends` resolved relative to including file directory.
* Only single inheritance supported (explicit design to avoid ambiguous conflict resolution).

Usage Pattern:
```
type Config struct { ... }
if err := configutil.Load("production.yaml", &cfg); err != nil { ... }
```

Schema Evolution Notes:
* Array override vs merge is intentional: ensures a child can fully replace list semantics without referencing parent items.
* Map merge additive: supports feature toggles accumulation.

#### 3.3 `dedup`
Concurrency primitive to deduplicate expensive identical tasks and cache results with TTL:

Components:
| Type | Description |
|------|-------------|
| `Limiter` | Global task map keyed by input; orchestrates execution & caching |
| `TaskRunner` | User-supplied interface returning (output, ttl) for given input |
| `IntervalTrap` | Periodic GC trigger throttled by access frequency (lazy evaluation) |

Algorithm (Limiter.Run):
1. Fast path shared read lock lookup; create `task` struct lazily under write lock if absent.
2. Acquire task's condition lock:
	 * If not expired → return cached output.
	 * If another goroutine executing (`running=true`) → Wait() then return output.
3. Mark running, release lock, execute user `TaskRunner.Run`.
4. Re-lock, store output + expiry, mark not running, Broadcast to waiting goroutines.

GC Behavior:
* `IntervalTrap.Trap()` called each `Run` invocation; if interval elapsed, executes GC: remove tasks whose TTL expired and not currently running.
* Clock is injectable (`clock.Clock`) facilitating deterministic tests.

Edge Cases:
* Returned TTL of zero → immediate expiry; next call reruns task.
* Task output race avoided via per-task condition variable ensuring one writer at a time.

#### 3.4 `bandwidth`
Implements duplex bandwidth throttling with coarse token granularity to avoid overflow:

Config Fields:
| Field | Meaning |
|-------|---------|
| `EgressBitsPerSec` / `IngressBitsPerSec` | Baseline configured rates (required if `Enable=true`) |
| `TokenSize` | Bit size per token (default 8 Mbit) for scaling numeric range |
| `Enable` | Feature toggle (disabled prints warning) |

Runtime Behavior:
* Two independent `rate.Limiter` instances (egress/ingress) sized: `bps / tokenSize` tokens per second, burst equal to that rate (1 second worth of traffic).
* `Reserve*` methods compute tokens = ceil((bytes*8)/tokenSize); reserve with delay, sleep for enforced pacing.
* `Adjust(denominator)` modifies active limit while preserving original config (non-compounding scaling) — useful for adaptive throttling (e.g., network contention signals).

Failure Cases:
* Creating limiter with zero bps returns error; with disabled config returns functional no-op limiter (methods succeed immediately).
* Oversized reservations relative to burst -> error returned; caller decides strategy (chunking, degrade).

#### 3.5 `handler`
Error-first HTTP handler pattern eliminating boilerplate:
* Define business logic `ErrHandler` returning `error`.
* Wrap with `handler.Wrap` which interprets custom `*handler.Error` types (status, headers, message) else defaults to 500.
* Logs (info) only 4xx (excluding 404) / 5xx statuses with context.

Advantages:
* Uniform error mapping; reduces duplicate header/status write code.
* Facilitates structured metrics middleware higher in the stack (status classification centrally). 

#### 3.6 `rwutil` (CappedBuffer)
Write-at buffer with enforced maximum capacity (supporting multi-part writes typical in ranged / piece assembly):
* Backed by AWS SDK `WriteAtBuffer` (slice). 
* `WriteAt` returns error if write would exceed capacity — prevents unbounded memory growth.
* `DrainInto` streams accumulated content to destination writer then caller can discard buffer (no direct zeroing provided).

#### 3.7 `stringset`
Lightweight set operations built atop map; purposely not thread-safe (caller provides synchronization if required). Operations O(1) average-case membership, difference, copy. Sampling returns at most n arbitrary members (deterministic order not guaranteed due to map iteration). Suitable for small / moderate sets (peer IDs, config names).

#### 3.8 `log`
Wrapper around global zap `SugaredLogger` to:
* Provide migration layer (if logging backend replaced, internal API stable).
* Offer convenience global functions (Infof, Warnw, etc.).
* `ConfigureLogger` sets global with caller skip for friendly file:line referencing call site outside wrapper.
* Production config: console encoding, ISO8601 timestamps, stack traces disabled by default; can be overridden via external module configs.

---
### 4. Concurrency & Memory Patterns
| Pattern | Packages | Notes |
|---------|----------|-------|
| Fine-grained per-key locking | `dedup.Limiter` | Cond var per task prevents head-of-line blocking across keys |
| Periodic lazy execution | `IntervalTrap` | Runs GC only when invoked & interval elapsed; avoids dedicated ticker goroutine |
| Token bucket pacing | `bandwidth` | Sleep-based enforcement; minimal memory (constant) |
| Request-level idempotency via caching | `dedup` | TTL output caching reduces computation & upstream calls |
| Buffer capacity guard | `rwutil` | Prevents OOM from unforeseen large stream assembly |

---
### 5. Error Semantics Summary
| Package | Custom Errors | Classification Helpers |
|---------|---------------|------------------------|
| `httputil` | `StatusError`, `NetworkError` | `IsNotFound`, `IsRetryable`, etc. |
| `configutil` | `ValidationError`, `ErrCycleRef` | Field-level accessor `ErrForField` |
| `dedup` | internal (none exported) | - |
| `handler` | `*Error` with status/header | Wrapped by `Wrap` |
| `rwutil` | `exceededCapError` | Caller compares by type |

Guideline: Always return sentinel or typed error for programmatic branching (e.g. 404 vs 500). Logging done at boundary layers, not deep utils (except initialization warnings / critical misconfig).

---
### 6. Performance Considerations
| Package | Hot Path Optimization |
|---------|-----------------------|
| `httputil` | Reuses http.Client per call scope; avoids reflection heavy frameworks; minimal allocations in SendOption chain |
| `dedup` | Fast read lock path for cache hit, only write lock when creating task |
| `bandwidth` | Token granularity reduces integer overflows & lock contention (burst=rate) |
| `configutil` | Sequential unmarshalling simple; acceptable since infrequent at startup |
| `rwutil` | Single underlying growing slice; no copy on `WriteAt` until drain |

Potential future enhancements: connection pooling config surface in `httputil`; lock-free path for dedup expiration using atomic timestamp; dynamic bandwidth smoothing via leaky bucket variant.

---
### 7. Security Considerations
* `httputil` TLS enabling via `SendTLS` ensures scheme upgrade; fallback downgrade must be explicitly enabled—avoid enabling in security sensitive contexts to prevent downgrade vectors.
* `configutil` merges last-writer-wins for arrays; ensure secrets arrays not unintentionally overwritten (separate secrets file recommended — already supported).
* `handler` hides internal details by default (empty message uses generic server error).
* `log` global logger holds potential sensitive data if logged; sanitize inputs at call sites.

---
### 8. Testing Infrastructure
Representative tests (some referenced):
| Package | Focus |
|---------|-------|
| `bandwidth/limiter_test.go` | Token accounting, adjust behavior |
| `configutil/config_test.go` | Extend chain resolution, cycle detection, merge semantics |
| `dedup/limiter_test.go` | Concurrent runs, TTL expiry, GC removal |
| `dedup/interval_trap_test.go` | Interval scheduling correctness |
| `httputil/httputil_test.go` | Retry logic, status classification, fallback behavior |
| `httputil/tls_test.go` | TLS handshake, fallback toggling |
| `rwutil/cappedbuffer_test.go` | Capacity enforcement, drain correctness |
| `syncutil/counters_test.go` | Atomic increment accuracy |
| `timeutil/timer_test.go` | Timer accuracy & elapsed measurement |

`testutil` provides ephemeral HTTP server start helpers and cleanup aggregator (LIFO resource release) encouraging deterministic teardown.

---
### 9. Extension Points
| Area | Strategy |
|------|----------|
| HTTP advanced retry | Add jitter backoff or circuit breaker wrapper around `Send` |
| Config validation | Extend with custom validator tags for domain-specific constraints |
| Dedup eviction policies | Add size-based eviction or LRU for memory bound control |
| Bandwidth limiter | Support dynamic token size adaptation or multi-priority queues |
| Logging | Switch to structured fields-only mode or multi-sink fan-out |
| CappedBuffer | Add streaming-while-writing interface for early consumption |

---
### 10. Usage Examples

HTTP GET with retry + custom accepted codes:
```
resp, err := httputil.Get(url,
	httputil.SendRetry(),
	httputil.SendAcceptedCodes(http.StatusOK, http.StatusAccepted),
	httputil.SendTimeout(5*time.Second))
```

Config load with inheritance:
```
var cfg MyConfig
if err := configutil.Load("production.yaml", &cfg); err != nil { panic(err) }
```

Deduplicated expensive computation:
```
type runner struct{}
func (runner) Run(input interface{}) (interface{}, time.Duration) {
	v := compute(input.(string))
	return v, 30*time.Second
}
lim := dedup.NewLimiter(clock.New(), runner{})
out := lim.Run("key1").(ResultType)
```

Bandwidth reservation before sending piece:
```
if err := limiter.ReserveEgress(int64(len(piece))); err != nil { return err }
send(piece)
```

HTTP handler with uniform error mapping:
```
func getBlob(w http.ResponseWriter, r *http.Request) error {
	id, err := httputil.ParseParam(r, "id")
	if err != nil { return err }
	if !exists(id) { return handler.ErrorStatus(http.StatusNotFound) }
	...
	return nil
}
http.HandleFunc("/blob", handler.Wrap(getBlob))
```

---
### 11. Cross-Module References
| Module | Dependency Usage |
|--------|------------------|
| Agent | `httputil` for upstream calls, `handler` for API endpoints, `configutil` for agent config load |
| Origin | `bandwidth` for backend throttling, `dedup` for remote fetch suppression |
| Tracker | `handler` for announce endpoints, `dedup` for metainfo generation caching |
| Proxy | `httputil` for preheat/prefetch registry calls |
| Core | `stringset` used in config extension resolution |

---
### 12. Future Work
| Idea | Benefit |
|------|---------|
| Per-host HTTP connection pooling config | Tune concurrency/latency trade-offs |
| Pluggable metrics callbacks in util packages | Unified observability without circular deps |
| Generic (Go 1.18+) Set / Cache abstractions | Type safety, fewer casts |
| Structured error types across all packages | Uniform machine parsing |
| Hash-based dedup key eviction metrics | Visibility into memory footprint |

---
### 13. Summary

The utils module consolidates well-scoped, production-hardened primitives enabling higher-level Kraken services to remain lean and focused. Changes here can have wide impact; follow principles of minimalism, backward compatibility, and explicit error contracts. When extending, add comprehensive tests and update this document to keep the catalog authoritative.

