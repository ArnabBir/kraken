## Nginx Module

This module encapsulates generation and execution of role-specific Nginx reverse proxy configurations for Kraken components: agent, origin, build-index, tracker, and proxy. It provides a programmatic interface (`Run`) which parameterizes templates, injects TLS credentials, and runs Nginx in the foreground (PID 1 in container contexts) with consistent logging and health endpoint behavior.

---
### 1. Goals & Responsibilities
| Goal | Mechanism |
|------|-----------|
| Uniform front-proxy behavior (timeouts, gzip, headers) | Shared BaseTemplate (`config/base.go`) |
| Component specialization (caching, upstream fanout) | Per-role templates (`agent`, `origin`, `build-index`, `tracker`, `proxy`) |
| pluggable TLS (mTLS / client auth) | `WithTLS` option populates SSL directives + CA bundle | 
| Deterministic health / readiness routing | Template function `healthEndpoint` generating location block |
| Safe config generation & isolation | Writes composed config under `/tmp/nginx` with constrained file permissions |
| Operator overrides | `Config.TemplatePath` for fully custom template; or run-time params map |

Out-of-scope: dynamic hot reload (Nginx `-s reload` not invoked here), fine-grained per-route rate limiting beyond built-in `limit_req_zone`.

---
### 2. Architecture Overview
```
					(callers: agent cmd, origin cmd, proxy cmd, tracker cmd)
											 |
											 v
						 +--------------------+
						 | nginx.Config       |
						 |  - Name/Template   |
						 |  - TLS (optional)  |
						 |  - CacheDir/Logs   |
						 +---------+----------+
											 |
							applyDefaults() / inject()
											 |
					getTemplate() or GetDefaultTemplate(Name)
											 |
						 populateTemplate(site)
											 |
					wrap inside BaseTemplate (site substitution)
											 |
					write /tmp/nginx/<Name> config file
											 |
								exec nginx -c <file> -g 'daemon off;'
```

Two-stage templating:
1. Role-specific template produces server/upstream blocks.
2. Base template wraps with global http{} / logging / SSL / gzip directives.

---
### 3. `Config` Structure
| Field | Purpose | Validation / Default |
|-------|---------|----------------------|
| `Binary` | Path to nginx executable | Default `/usr/sbin/nginx` |
| `Root` | If true, prefixes command with `sudo` | false by default |
| `Name` | Identifier selecting default template (e.g. `kraken-agent`) | Required unless `TemplatePath` provided |
| `TemplatePath` | Override file path; takes precedence over `Name` | Optional |
| `CacheDir` | Directory used for Nginx `proxy_cache_path` zones (per template) | Required |
| `LogDir` | Base directory for default log paths when specific not set | Required unless all explicit paths set |
| `StdoutLogPath` | Where merged STDOUT/ERR of nginx binary is written | Derived from `LogDir` if empty |
| `AccessLogPath` | Access log file path | Derived from `LogDir` if empty |
| `ErrorLogPath` | Error log file path | Derived from `LogDir` if empty |
| TLS (internal) | Populated when `WithTLS` option used | Validates cert/key/passphrase presence |

Reserved parameter keys disallowed in `params` map: `cache_dir`, `access_log_path`, `error_log_path` (auto-injected).

---
### 4. Template Function Injection
`populateTemplate` adds `healthEndpoint` helper:
```
{{healthEndpoint "agent-server"}}
```
Expands to a location block forwarding `/health` and `/readiness` to a specified upstream with `access_log off` to prevent noisy metrics skew.

This function allows consistent health endpoint proxying across all component templates.

---
### 5. Base Template Key Directives
File: `config/base.go`
Highlights:
* Worker tuning: `worker_processes 4`, `worker_connections 2048`, `worker_rlimit_nofile 4096`.
* Rate limiting zone: `limit_req_zone $binary_remote_addr zone=per_ip_limit:10m rate=100r/s;` reused by proxy `/proxy` location to limit prefetch requests.
* Standard proxy headers preserving client IP and URI: `X-Forwarded-For`, `X-Real-IP`, `X-Original-URI`.
* `proxy_redirect` rewrites upstream Location headers containing externally visible scheme/host to relative path enabling agent/cluster internal host usage.
* Conditional SSL block: enabled only if server TLS not disabled (set by `WithTLS`).
* Client verification logic (see next section) prepared for optional/required semantics.
* JSON structured access log format embedding rich fields (host, upstream timings, user agent). Useful for log ingestion systems without further parsing.

---
### 6. Client Verification Logic
Template snippet (from `config/default.go`):
```
ssl_verify_client optional;
set $required_verified_client 1;
if ($scheme = http) { set $required_verified_client 0; }
if ($request_method ~ ^(GET|HEAD)$) { set $required_verified_client 0; }
if ($remote_addr = "127.0.0.1") { set $required_verified_client 0; }
set $verfied_client $required_verified_client$ssl_client_verify;
if ($verfied_client !~ ^(0.*|1SUCCESS)$) { return 403; }
```
Behavior:
* All modifying methods over HTTPS require successful client cert verification unless request qualifies for exemptions (local address or read-only method or plain HTTP).
* Allows incremental rollout: clients without certificates still permitted for GET/HEAD.
* Security upgrade path: tighten rule set by removing exemptions (custom template or future config flags).

User override: Provide custom `client_verification` parameter in `params` map (if absent, default inserted).

---
### 7. Per-Role Template Semantics

| Role | File | Key Features |
|------|------|--------------|
| Agent | `config/agent.go` | Dual upstreams: registry backend + optional backup; CIDR allowlist + default deny; proxies all other URIs to local registry; health endpoints forwarded to `agent-server`; `gzip on` for JSON/text |
| Origin | `config/origin.go` | Single upstream; increases `client_max_body_size 10G` (large uploads); health endpoints passed-through |
| Build-Index | `config/build-index.go` | Multiple proxy caches: `/tags`, `/repositories/.../tags`, `/list` each with distinct zone & TTL; `proxy_cache_lock` avoids thundering herds; `/list` has extended `proxy_read_timeout 2m` |
| Tracker | `config/tracker.go` | Cache zone `metainfo` (levels=1:2) for torrent metadata; specialized location regex for `.../metainfo` with 5m 200 cache vs 1s negative cache; health endpoint; general requests no cache |
| Proxy | `config/proxy.go` | Multi-server listen across provided ports; three upstreams: registry, registry-override (for /v2/_catalog), proxy-server; per-location host header rewriting for local dev hostnames; rate limit on `/proxy` path; large body timeout extension |

Caching Strategy Rationale:
* Short negative cache (1s) prevents rapid repeat expensive backend hits for short-lived errors.
* Positive cache TTL tuned per endpoint semantics (fast-moving vs rarely changing metadata).
* Directory layout for cache path: `<CacheDir>/<zone-key>` (e.g. `/tmp/cache/tags`). Zones sized in memory (10–20m) for keys; content persistently stored on disk respecting `max_size` where declared.

---
### 8. TLS Handling & CA Bundle
If server TLS enabled (`tls.Server.Disabled == false`):
1. Validate existence of server cert, key, optional passphrase file, and client CA certs on disk.
2. Concatenate all CA certs into `/tmp/nginx/ca.crt` to satisfy `ssl_client_certificate` directive.
3. Enable SSL directives in base template; else TLS block omitted and server listens plain HTTP.

Security Notes:
* CA bundle path deterministic; ensure directory permissions prevent tampering.
* Passphrase file supported via `ssl_password_file` enabling encrypted private keys.
* Optional future improvement: generate ephemeral DH params / stricter cipher suite selection based on config.

---
### 9. Execution Flow (`Run`)
Pseudo-code distilled from `nginx.go`:
```
config.applyDefaults()
validate required fields (Name/TemplatePath, CacheDir)
apply options (WithTLS)
mkdir /tmp/nginx and CacheDir
TLS: verify files, write ca bundle if enabled
inject reserved params (cache_dir, access_log_path, error_log_path)
site := populate(role template, params)
src := populate(base template, map{"site": site, ssl_*})
write /tmp/nginx/<Name>
open stdout log file
exec [sudo] nginx -g 'daemon off;' -c /tmp/nginx/<Name>
```
Foreground execution (`daemon off;`) ensures Kubernetes / systemd supervision captures process exit; logs directed to a single file facilitating container log scraping.

---
### 10. Logging Strategy
Access log: structured JSON fields (see BaseTemplate). Error log separate. Binary STDOUT/ERR multiplexed into `StdoutLogPath` enabling capture of Nginx startup diagnostics + runtime warnings. Health endpoints disable access logging to reduce noise.

Filtering / Analytics: Downstream log pipeline can parse one JSON object per line; consistent keys across roles make cross-component dashboards simpler.

---
### 11. Performance Considerations
| Aspect | Choice | Rationale |
|--------|--------|-----------|
| Workers | 4 processes | Balance moderate parallelism with low overhead for typical host sizes |
| worker_connections | 2048 | Supports high concurrent peer requests, especially for tracker/proxy |
| Caching | Disk + shared memory zones | Offload repeated metadata/tag lookups; memory zones hold keys only |
| Gzip | Enabled for JSON/text; disabled globally in base? (agent/origin override to on) | Reduce bandwidth for metadata, negligible for binary blobs |
| Rate limiting | per IP zone + burst config | Protect proxy endpoint from abuse (preheating storms) |
| Host header rewriting | inline `if` blocks | Workaround for Docker for Mac / local dev host resolution inconsistencies |

Potential future enhancements: dynamic worker count (auto scale by CPU cores), Brotli compression plugin, upstream keep-alive tuning, connection pooling metrics exports.

---
### 12. Failure Modes & Diagnostics
| Failure | Symptom | Cause | Mitigation |
|---------|---------|-------|-----------|
| Missing TLS file | Startup error (invalid TLS config) | Path incorrect / secret not mounted | Validate config earlier or add readiness pre-flight |
| Permission denied writing `/tmp/nginx` | Immediate failure | Container FS restrictions | Pre-create mount with proper perms |
| Bad template name | `get default template` error | Typo or unsupported role | Provide correct `Name` or custom `TemplatePath` |
| 403 responses unexpectedly | Client verification rule triggered | No client cert for modifying request | Adjust rules or supply certificate |
| Cache ineffective (low hit ratio) | High upstream load | TTL too low / cache zone size insufficient | Tune TTLs, enlarge zone memory |

Debug Steps:
1. Inspect stdout log file for template path, startup errors.
2. Tail access log to confirm routing decisions (upstream_addr & status).
3. Use `curl -v` on `/health` to ensure upstream mapping correct.

---
### 13. Extension Points
| Need | Approach |
|------|---------|
| Alternate logging format | Supply custom `TemplatePath` or extend base with new `log_format` | 
| Additional role | Add template + register in `_nameToDefaultTemplate` map |
| Auth layer (JWT, Basic) | Modify role template to inject `auth_request` or `proxy_set_header` flows |
| Dynamic reload | After writing config, send `nginx -s reload` on changes (requires PID file mgmt) |
| Rate limiting customization | Expose rate/zone as config params (currently hard-coded) |
| Fine-grained TLS cipher policy | Extend `Config` to accept cipher/protocol overrides |

---
### 14. Usage Examples
Agent startup snippet (see `agent/cmd/cmd.go`):
```
nginx.Run(config.Nginx, map[string]interface{}{
	"allowed_cidrs": config.AllowedCidrs,
	"port": flags.AgentRegistryPort,
	"registry_server": nginx.GetServer(cfg.Registry.Docker.HTTP.Net, cfg.Registry.Docker.HTTP.Addr),
	"agent_server": fmt.Sprintf("127.0.0.1:%d", flags.AgentServerPort),
	"registry_backup": config.RegistryBackup,
}, nginx.WithTLS(config.TLS))
```

Custom template override:
```
cfg := nginx.Config{Name: "kraken-agent", TemplatePath: "/etc/custom/agent.tmpl", CacheDir: "/var/cache/nginx", LogDir: "/var/log/nginx"}
if err := nginx.Run(cfg, params); err != nil { panic(err) }
```

Creating a new role:
1. Add `<role>.go` with `<Role>Template` constant.
2. Register name in `_nameToDefaultTemplate` (e.g. `"kraken-<role>"`).
3. Provide `Name: "kraken-<role>"` in config.

---
### 15. Security Considerations
* Mutual TLS enforcement optional; ensure sensitive deployments do not run with `Server.Disabled=true`.
* Default client verification allows GET/HEAD unauthenticated; if stronger model required, override template removing exemptions.
* CA bundle concatenation trust root: restrict write permissions on `/tmp/nginx/ca.crt` (written each start, not rotated).
* Headers preserve original client IP (X-Forwarded-For) enabling downstream rate limiting & auditing.
* Strict cipher suite list excluding legacy/weak algorithms; only TLSv1.2 enabled (consider TLSv1.3 addition).

---
### 16. Cross-Module Integration
| Module | Interaction |
|--------|------------|
| Agent | Launches nginx for on-node registry + agent server multiplexing |
| Origin | Uses origin template to front origin HTTP handlers with optional client cert requirements |
| Tracker | Caches metainfo requests via tracker template |
| Build-Index | Provides tag/repository/list cache zones lowering DB/API load |
| Proxy | Handles multi-port registry/proxy endpoints with host header rewriting & request throttling |

---
### 17. Future Enhancements
| Proposal | Benefit |
|----------|---------|
| Template linting / dry-run command | Detect template syntax errors pre-deploy |
| Hot reload watcher | Seamless config updates without downtime |
| Pluggable cache invalidation API | Real-time purge of stale metadata entries |
| Automatic TLS cert reload (SIGHUP) | Rotate certificates without restart |
| Configurable structured log keys | Adapt to external logging schema expectations |

---
### 18. Summary
The Nginx module centralizes key reverse proxy concerns for Kraken components: secure client handling, efficient caching, structured observability, and consistent health routing—while remaining extensible via templates and parameters. Any template change can impact production traffic; accompany modifications with integration tests and update this document to maintain clarity.

