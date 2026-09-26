# P0 - Observability and Analytics Discovery (Read-Only)

Generated 2026-09-25. Read-only fact-gathering pass covering Phase 1 (OpenTelemetry/Prometheus/ClickHouse/Grafana monitoring), Phase 2 (ClickHouse analytics for `admin_actions`, `platform_stats`, `user_events`), and Phase 3 (ScyllaDB inventory for the message module, inventory only).

## Summary

The backend has no tracing infrastructure today: no OpenTelemetry SDK/exporter, no Micrometer Tracing bridge, and the `traceId` MDC field in every log line always resolves to the literal string `none` (no code ever calls `MDC.put("traceId", ...)`).
`/actuator/prometheus` is exposed but gated behind `hasRole('ADMIN')` unless an explicit opt-in property is set; no per-profile actuator overrides exist.
No AMQP message anywhere carries or reads a W3C `traceparent` header; `DomainEventEnvelope` has no header/metadata field for one, and every `@RabbitListener` consumer parses only the message body via a shared `DomainEventMessageParser`.
`DeadLetterPublisher` does preserve whatever headers exist across dead-lettering, so a future trace header would survive that path without further changes.
RabbitMQ runs the management-only image (`rabbitmq:4-management`); the `rabbitmq_prometheus` plugin is not enabled and its port is not published.
`pg_stat_statements` is not configured anywhere (no `shared_preload_libraries`, no init SQL); the Postgres image is a bare `postgres:latest` build.
Gorse's config has no `[metrics]` section; whether the binary exposes an implicit metrics endpoint is unverifiable without web/runtime access.
`admin_actions` is written exclusively through one chokepoint (`AdminActionRecorder`, deliberately non-`@Transactional` so it always joins the caller's transaction) across 21 call sites, giving Phase 2's "stays in Postgres, replicate via outbox" plan a clean single integration point.
`platform_stats` and `user_events` both have single, well-isolated writer paths (`StatsCollectionJob`/`StatsRollupJob`, and `UserEventRecorder`/`RecommendationFeedbackConsumer` respectively), consistent with a full migration off Postgres.
`user_events` feeds Gorse in real time per event via `insertFeedback`, not through any batch/scheduled rebuild — no code path does a bulk resync; that is a documented manual operational procedure only.
`post_interaction_scores` and `user_similarity` are dormant: schema exists, no Java code writes or reads either table.
Testcontainers is pinned at 1.21.4; RabbitMQ and Redis integration tests use plain `GenericContainer`, not dedicated Testcontainers modules, and the test RabbitMQ image (`rabbitmq:3.13-alpine`) differs from the compose stack's `rabbitmq:4-management`.
No local Docker daemon was reachable from this sandbox, so live local database/container state (row counts, table sizes, `docker ps`) is UNKNOWN throughout; production host access is UNKNOWN by design (no host access from this environment).
Frontend sends no tracing header today, and the backend CORS `allowedHeaders` allow-list does not include one, so adding trace propagation from the browser would require a CORS config change first.

---

## A. Build, dependencies, and framework support

**A1. Observability-related dependencies (resolved versions)**, via `./mvnw -o dependency:tree -Dincludes="io.micrometer,io.opentelemetry,ch.qos.logback,org.slf4j,net.ttddyy"` from `backend/`:

- `org.springframework.boot:spring-boot-starter-actuator:4.0.6` (`backend/pom.xml:44-46`).
- `io.micrometer:micrometer-observation:1.16.5`, `io.micrometer:micrometer-commons:1.16.5`, `io.micrometer:micrometer-jakarta9:1.16.5` (all transitive of the actuator starter).
- `io.micrometer:micrometer-core:1.16.5`, `io.micrometer:micrometer-registry-prometheus:1.16.5` (`backend/pom.xml:155-158`, runtime scope).
- `io.micrometer:micrometer-tracing:1.6.5` — not declared directly; pulled in only transitively via `net.ttddyy.observation:datasource-micrometer:2.2.1` (`backend/pom.xml:92-94`). No `micrometer-tracing-bridge-brave` or `micrometer-tracing-bridge-otel` is present anywhere in the tree.
- `io.micrometer:context-propagation:1.2.1` (transitive of micrometer-tracing).
- `io.opentelemetry:opentelemetry-api:1.55.0`, `opentelemetry-context:1.55.0`, `opentelemetry-common:1.55.0` — all runtime scope, pulled in solely as transitive dependencies of `co.elastic.clients:elasticsearch-java:9.2.8` (via `spring-data-elasticsearch:6.0.5`). No `opentelemetry-sdk`, no exporter, no instrumentation artifact exists. This presence is incidental to the Elasticsearch client, not wired for tracing.
- `net.ttddyy.observation:datasource-micrometer-spring-boot:2.2.1` and `datasource-micrometer:2.2.1` (`backend/pom.xml:92-94`, `net.ttddyy:datasource-proxy:1.11.0` transitive).
- Logging: `ch.qos.logback:logback-classic:1.5.32`, `logback-core:1.5.32` (transitive of `spring-boot-starter-logging`); `org.slf4j:jul-to-slf4j:2.0.17`; `org.slf4j:slf4j-api:2.0.17`. No Log4j2 bridge, no `logstash-logback-encoder`, no other logging bridge.

**A2. Spring Boot version and BOM-managed versions**

- Spring Boot `4.0.6` (`backend/pom.xml:5-9`, parent).
- `micrometer-tracing.version` = `1.6.5`, confirmed via `./mvnw -o help:evaluate -Dexpression=micrometer-tracing.version -q -DforceStdout`.
- `opentelemetry.version` = `1.55.0`, confirmed via `./mvnw -o help:evaluate -Dexpression=opentelemetry.version -q -DforceStdout`.
- `micrometer-core`/`micrometer-observation` line = `1.16.5` (observed directly in the dependency tree).

**A3. What Spring Boot 4.0.x officially provides for OpenTelemetry**

UNKNOWN — no web access available in this environment to consult the official Spring Boot 4.0 reference documentation for exact starter names or OTLP-export support claims. Would require reading `docs.spring.io` for the Spring Boot 4.0 Actuator/Observability chapter.

**A4. OpenTelemetry Java agent compatibility with this Spring Boot 4.0.x + Java 21 setup**

UNKNOWN — no web access to verify current `opentelemetry-javaagent` compatibility matrices against Spring Boot 4.0.x / the Spring Framework version it embeds.

**A5. Actuator configuration per profile**

- Base config (`backend/src/main/resources/application.yaml:499-513`): `management.endpoints.web.exposure.include: health,info,prometheus` (line 507); `management.health.elasticsearch.enabled: true` (508-510); `management.endpoint.health.show-details: when-authorized` (511-513). No `management.server.port`/`base-path` override anywhere, so actuator runs on the application's own HTTP port at the default `/actuator` base path.
- `application-dev.yml` and `application-prod.yml` contain no `management:` block at all — both profiles inherit the base config unmodified. `application-prod.yml:13-16` only sets `logging.file.path`.
- Reachability of `/actuator/prometheus`: `SecurityConfig.java` — `PUBLIC_INFRA_PATHS` (lines 99-106) permits `/actuator/health` publicly; `METRICS_PATH = "/actuator/prometheus"` (line 97) is opened via `permitAll()` only when `app.security.public-metrics-endpoint=true` (a WARN is logged when enabled, lines 306-312). Otherwise it falls through to `auth.requestMatchers("/actuator/**").hasRole("ADMIN")` (line 315). No profile sets that property to true, so scraping requires an authenticated ADMIN session by default in both dev and prod.

## B. Existing observability code

**B1. Custom meters / `@Observed` / `ObservationRegistry` / `MeterRegistry`**

No `@Observed` or direct `ObservationRegistry` usage anywhere in `backend/src/main/java`. Five classes inject `MeterRegistry` directly:

- `com.app.modules.comment.observability.CommentMetrics` — Timer `comment.create.latency`, Timer `comment.fanout.latency`, Counter `comment.idempotency.replays`, Counter `comment.ws.push.failures`, Gauge `comment.ws.connections` (sourced from `CommentWebSocketSessionRegistry.totalSessions()`), Counter `comment.moderation.rejected` tagged by `reason`.
- `com.app.modules.comment.observability.CommentSubsystemHealthIndicator` — not a meter; `HealthIndicator` pinging Redis and (if available) checking RabbitMQ channel state.
- `com.app.modules.recommendation.observability.RecommendationMetrics` — Counter family `recommendation.feed.fallback` tagged `outcome` (`zero_accept_round`, `chronological_fallback`).
- `com.app.common.turnstile.TurnstileMetrics` — Counter `turnstile.verification.total` tagged `outcome`/`surface`, Timer `turnstile.verification.duration`.
- `ElasticsearchConfig` — matched only because its Javadoc documents relying on Spring Boot's auto-configured `elasticsearchHealthIndicator`; no `MeterRegistry` usage itself.

Both named `observability/` packages contain exactly: `comment.observability` → `CommentMetrics.java`, `CommentSubsystemHealthIndicator.java`; `recommendation.observability` → `RecommendationMetrics.java`.

**B2. `traceId` in the logback pattern**

Pattern is `%X{traceId:-none}` (`backend/src/main/resources/logback-spring.xml:16,30`) — an MDC lookup defaulting to `none`. No code anywhere calls `MDC.put("traceId", ...)` (the only `MDC.put` calls found are for `serverId`, `eventId`, `postId`, `userId`, `commentId` in `PostLiveFanoutConsumer`, `CommentLiveFanoutConsumer`, `CommentServiceImpl`). Because no tracing bridge is on the classpath (A1) and no `Tracer` bean exists, Spring Boot's automatic tracer-backed MDC population never activates. The `traceId` field in every log line today is always the literal string `none`.

**B3. `logback-spring.xml` summary**

51-line file. Includes Spring Boot's default logback config. Properties: `APP_NAME=app`; `LOG_PATH` from env with a dev/test-only fallback (prod sets it via `logging.file.path` in `application-prod.yml:13-15`); `ACTIVE_PROFILE` declared via `springProperty` but never referenced elsewhere in the file. Two appenders (`CONSOLE`, rolling `FILE`) share the identical pattern `%d{yyyy-MM-dd HH:mm:ss.SSS} | %-5level | %thread | %X{traceId:-none} | %logger{36} | %msg%n`. `FILE` rolls at 50MB/10 files/500MB cap. One explicit override pins `ExceptionHandlerExceptionResolver` to `ERROR` to suppress a WARN-level leak of raw field errors that could include a submitted password. Root logger `INFO`. No `springProfile` blocks exist — appenders/pattern are identical across every profile; the only profile-driven logging difference is `logging.file.path` in prod and a few framework loggers set to `OFF` in the base `application.yaml`.

**B4. Health indicators and circuit breakers**

- Health: auto-configured composite (`db`, `diskSpace`, etc.), auto-configured `elasticsearchHealthIndicator` (enabled via `management.health.elasticsearch.enabled: true`), and one custom indicator — `CommentSubsystemHealthIndicator` (Redis ping + optional RabbitMQ channel check). Exposed via `/actuator/health` (public), with `show-details: when-authorized` gating per-indicator detail to authenticated callers. No custom health groups configured.
- Circuit breakers (Resilience4j, by `@CircuitBreaker(name=...)` instance): `elasticsearchSearch` (three call sites: `HashtagSearchServiceImpl`, `PostSearchServiceImpl`, `PostByHashtagSearchReader`), `gorse` (two call sites: `GorseNeighbourSource`, `RecommendationSource`). A `default` instance is configured in `resilience4j-{dev,prod}.yml` per struct.md but no explicit annotation site was found using it directly. No dedicated Resilience4j actuator endpoints (`/actuator/circuitbreakers`, `/actuator/circuitbreakerevents`) are reachable — not in the `management.endpoints.web.exposure.include` list (only `health,info,prometheus`).

## C. Asynchronous boundaries relevant to trace propagation

**C1. Outbox write path**

`OutboxService.enqueue` (`backend/src/main/java/com/app/common/outbox/service/OutboxService.java:22-28`), impl `OutboxServiceImpl.enqueue` (`.../impl/OutboxServiceImpl.java:36-76`), `@Transactional(propagation = Propagation.MANDATORY)` — joins the caller's own transaction, no thread/scheduler/broker boundary here. `DomainEventEnvelope` fields (`backend/src/main/java/com/app/common/outbox/model/DomainEventEnvelope.java:8-15`): `eventId, eventType, occurredAt, actorId, aggregateType, aggregateId, data (Map<String,Object>)` — exactly 7 fields, no header/metadata/traceparent field. `outbox_events` columns (`backend/database/schema.sql:1259-1282`): `id, event_id, aggregate_type, aggregate_id, event_type, routing_key, payload (JSONB), status, attempt_count, next_retry_at, last_error, created_at, published_at, claim_id, claimed_at, claimed_until` — no dedicated header column; a `traceparent` could in principle be smuggled into the `data` JSON map (it wouldn't trip the sensitive-key/value validation), but nothing does this today.

**C2. `OutboxPublisherServiceImpl`**

`@ConditionalOnProperty(...matchIfMissing=true)` — active by default. `@Scheduled(initialDelayString="${app.outbox.publisher.initial-delay:PT10S}", fixedDelayString="${app.outbox.publisher.fixed-delay:PT1S}")` on `publishDueEvents()` — runs on Spring's scheduler infrastructure (virtual-thread-backed `TaskScheduler` given `spring.threads.virtual.enabled: true`), not the original HTTP thread. Batch claim: native SQL `FOR UPDATE SKIP LOCKED` updating `status='PROCESSING'` with a `claim_id`/`claimed_until` (`OutboxEventRepositoryImpl.claimPublishableBatch`). AMQP message built in `buildMessage()`: JSON body of the envelope, headers `eventId, eventType, aggregateType, aggregateId` — no trace-context header set. Publisher confirms: `rabbitTemplate.send(...)` with `CorrelationData` keyed on `eventId`, blocks on the confirm future, also checks for unroutable returns; success calls `markPublished`, failure calls `recordFailure` (retry with backoff or `DEAD` once max attempts reached).

**C3. Every `@RabbitListener` consumer**

14 consumer classes found (struct.md states 21 total listener methods across them; this pass located each class's primary consume method). All domain-event consumers parse via the shared `DomainEventMessageParser.parse(Message)`, which reads only `message.getBody()` — it never calls `message.getMessageProperties().getHeaders()`. Consequently **no consumer in the codebase reads any AMQP header today**; domain fields are all read back out of the JSON body. Three `*.live.events` fanout consumers (`CommentLiveFanoutConsumer`, `PostLiveFanoutConsumer`, `MessageLiveFanoutConsumer`) run with `ackMode="NONE"`; the rest use manual ack via `deliveryTag`.

**C4. `DeadLetterPublisher` and the retry path**

`publish(Message original, ...)` copies every header from the original message via `setHeaderIfAbsent` before adding its own `x-original-*`/`x-dead-lettered-at`/`x-dead-letter-reason` headers — **headers are preserved across dead-lettering**. Publishes to the dead-letter exchange with a 5s confirm timeout, throwing on nack/timeout/unroutable. `PermanentMessageException` (e.g. from an unparseable body) bypasses retry and routes straight to DLQ. A future `traceparent` header on outbound messages would automatically survive this path without further changes to `DeadLetterPublisher`.

**C5. `ProcessedMessageService.processOnce`**

`@Transactional` (default `REQUIRED`) wrapping a single method: `processedMessageRepository.insertIfAbsent(...)` (an `INSERT ... ON CONFLICT DO NOTHING RETURNING`) is attempted first; on empty result, returns `DUPLICATE` without invoking the handler. On success, `handler.run()` executes in the same transaction, so the idempotency marker and the domain side effects commit or roll back atomically together.

**C6. Every `@Scheduled` job and `ApplicationRunner`**

13 `@Scheduled` methods: `OutboxPublisherServiceImpl.publishDueEvents`, `WebSocketRevocationSweepService`, `StatsCollectionJob`, `StatsRollupJob` (`0 20 3 * * *` UTC), `SuspensionExpiryJob`, `RefreshTokenPurgeJob`, `CommentMaintenanceScheduler` (`PT1H`), `HashtagTrendingServiceImpl`, `MessageMaintenanceScheduler` (`PT1H`), `HashtagAffinityJob`, `SuggestionPrecomputeJob`, `UserEventsPartitionJob` (`0 5 0 * * *` UTC), `StoryCleanupScheduler`. `@EnableScheduling` declared once, in `OutboxPublisherConfig.java:9`. Three `ApplicationRunner` implementations: `RetiredQueueCleaner`, `HashtagIndexSeedRunner`, `PostIndexSeedRunner`. All run on Spring's scheduling infrastructure, not a request thread; with `spring.threads.virtual.enabled: true` and no custom `TaskScheduler` bean found, Boot's virtual-thread-backed default applies.

**C7. Custom executors / off-request-thread paths**

- `UserEventRecorder` — dedicated `SimpleAsyncTaskExecutor` (`"user-event-"`, virtual threads), bounded by `Semaphore(MAX_IN_FLIGHT=8)`; a permit-exhausted submission is dropped with a WARN, not queued or blocked. Each write commits independently of the caller's transaction (Javadoc: "never extends the caller's transaction"). The clearest off-request-thread, no-trace-propagation boundary in the codebase — no `ContextSnapshot`/context-propagation wiring around it.
- `MailAsyncConfig` — `@EnableAsync` + `ThreadPoolTaskExecutor` (`mailTaskExecutor`, core 4/max 16/queue 500, plain platform threads, not virtual) backing `@Async` mail dispatch in `MailServiceImpl`.
- `ResendMailSender` — comment states "one virtual thread per call... pool exists only to make the SDK call cancellable."

**C8. Outbound clients**

- **Gorse**: synchronous Spring `RestClient` over `JdkClientHttpRequestFactory`/`java.net.http.HttpClient`, headers `X-API-Key`/`X-API-Version: 2` set once at bean construction. Guarded by `@CircuitBreaker(name="gorse")` at call sites, not inside the client itself.
- **Elasticsearch**: Spring Data Elasticsearch 6.0.5 over the official `co.elastic.clients:elasticsearch-java:9.2.8` client — the source of the incidental OTel API presence noted in A1; no OTel SDK/exporter configured, so any instrumentation hooks in that client are inert.
- **Redis**: Lettuce, pinned to `ProtocolVersion.RESP2` to avoid a `HELLO 3`-before-`AUTH` incompatibility against a `requirepass`-protected server. Single `StringRedisTemplate` bean; no generic/JSON `RedisTemplate`.
- **R2**: AWS SDK v2 `S3Presigner` only (not a full `S3Client`) — the backend never streams object bytes, consistent with the pre-signed-upload flow rule.
- **Resend**: `com.resend.Resend` client, conditional on `app.mail.transport=resend`; actual sends happen on the per-call virtual thread pattern noted in C7, invoked from the `mailTaskExecutor`-backed `@Async` mail path.

**C9. STOMP/SockJS live fanout path**

`WebSocketBrokerConfig` uses Spring's in-memory simple broker (`enableSimpleBroker("/topic")`) — no external STOMP relay, so fanout is local to each application instance's own subscriber set. Each `*.live.events` exchange feeds a per-instance, uniquely named queue (e.g. `#{postLiveServerQueueInitializer.queueName}`); the `@RabbitListener` on it runs `ackMode="NONE"` (fire-and-forget). Traced end-to-end via `PostLiveFanoutConsumer`: parses body only (no headers), re-reads the live counter at push time rather than trusting a stale captured value, resolves blocked counterparties and attaches them as a STOMP header, then `messagingTemplate.convertAndSend(...)`. Delivery failures are caught, logged WARN, and dropped — best-effort by design, with client reconnect + REST resync as the recovery path (matches `GLOBAL_RULES.md` §8's stated degradation). No trace-context propagation exists anywhere across this chain.

## D. Tables targeted by Phase 2

*(No local database was reachable — `docker ps` failed with "the system cannot find the file specified," meaning Docker Desktop's engine is not started. Row counts and on-disk sizes for all three tables are UNKNOWN; resolvable by starting Docker Desktop, running `docker compose up -d postgres` from `backend/`, and querying `pg_stat_user_tables`/`pg_total_relation_size`.)*

### D.1 `admin_actions`

**DDL** (`backend/database/schema.sql:931-946`): `id UUID PK DEFAULT gen_random_uuid()`, `admin_id UUID`, `action_type admin_action_type NOT NULL`, `target_user_id UUID`, `target_entity_type VARCHAR(50)`, `target_entity_id UUID`, `report_id UUID`, `reason TEXT`, `metadata JSONB`, `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`. FKs: `admin_id → users(id) ON DELETE SET NULL`, `report_id → reports(id) ON DELETE SET NULL`, `target_user_id → users(id) ON DELETE SET NULL`. Append-only — no `updated_at`, no soft delete. Not partitioned, no triggers. Indexes (all `CREATE INDEX CONCURRENTLY`, V74/V82): `idx_admin_actions_admin (admin_id, created_at DESC)`, `idx_admin_actions_created (created_at DESC, id DESC)`, `idx_admin_actions_target (target_user_id) WHERE target_user_id IS NOT NULL`, `idx_admin_actions_target_created (target_user_id, created_at DESC, id DESC) WHERE target_user_id IS NOT NULL`.

**Foreign keys referencing it**: `user_warnings.admin_action_id NOT NULL REFERENCES admin_actions(id)`; `user_strikes.admin_action_id NOT NULL REFERENCES admin_actions(id)`; `support_tickets.admin_action_id REFERENCES admin_actions(id) ON DELETE SET NULL` (nullable); `user_verifications.granted_action_id`/`revoked_action_id → admin_actions(id) ON DELETE SET NULL`; `email_deliveries.admin_action_id → admin_actions(id)` (nullable, no declared ON DELETE). `notifications.admin_action_id` carries **no declared FK constraint** — an unconstrained, application-level reference populated via `NotificationDraft`.

**Writers**: single chokepoint, `AdminActionRecorder.record(...)` (`backend/src/main/java/com/app/modules/admin/service/AdminActionRecorder.java:74-98`), deliberately not `@Transactional` so it always joins the caller's transaction ("an audit row that could commit independently of the state change it describes would let the log and the data disagree"). 21 call sites across `AdminHashtagServiceImpl`, `AdminServiceImpl` (7 call sites), `AdminUserServiceImpl` (3), `SuspensionExpiryServiceImpl`, `UserDisciplineServiceImpl` (4, two with `admin_id = null` for automatic ladder actions), `SupportTicketServiceImpl` (2), `VerificationServiceImpl` (3) — every one inside a `@Transactional` service method that mutates the domain row and records the audit row in the same method body. Seed writers: `ModerationSeedWriter`, `SupportSeedWriter` (dev-only, `SEED_DATA=true` gated).

**Readers**: `AdminActionRepositoryImpl.findActions` — optional `adminId`/`targetUserId`/`actionType` filters, half-open `[from,to)` on `createdAt`, keyset pagination on `(createdAt DESC, id DESC)` (not offset; a comment cites a measured 48,248 buffers/23.3ms without the cursor predicate versus 24 buffers/0.07ms with it). `findMostRecentAppealable` — native query with a `NOT EXISTS` anti-join against `support_tickets.admin_action_id`. `findById` — PK lookup.

**Same-transaction guarantee**: structurally enforced by `AdminActionRecorder`'s lack of `@Transactional` (it always joins the caller's), matching `backend/docs/modules/admin/DATA_RULES.md:53-74`'s rule-by-rule table.

**Every dereference of `admin_actions.id`**: `user_warnings`/`user_strikes` (NOT NULL FK); `support_tickets.admin_action_id` (appeal linkage, anti-join guard before creating an appeal); Redis reverse index `support:token:appeal:subject:{adminActionId}` in `SupportTokenServiceImpl.createAppealToken` (rationale: "one account may hold appealable decisions against several actions at once"); `email_deliveries.admin_action_id`; `notifications.admin_action_id` (read in `NotificationFeedRepository`, hydrated in `NotificationItemAssembler` for appeal-eligibility display); `VerificationServiceImpl` contested-rejection linkage; the outbox payload field `"adminActionId"` set by `AdminActionRecorder.enqueueModerationNotice`.

**REST endpoints**: `GET /api/v1/admin/actions` (filters + cursor/limit) → `CursorPageResponse<AdminActionSummaryResponse>`; `GET /api/v1/admin/actions/{actionId}` → `AdminActionResponse` (includes `metadata`, the only endpoint that does); `GET /api/v1/admin/actions/users/{userId}` → `CursorPageResponse<AdminActionSummaryResponse>`; plus 15 `PATCH`/mutation endpoints across `AdminController`, `AdminDisciplineController`, `AdminUserController`, `AdminHashtagController` that write through `AdminActionRecorder`.

**Tests**: `AdminActionKeysetRowLossIT`, `AdminActionRepositoryTest`, `AdminActionRecorderTest`, `AdminServiceImplTest`, `AdminHashtagServiceImplTest`, `AdminUserServiceImplTest`, `SuspensionExpiryServiceImplTest`, `UserDisciplineServiceImplTest`, `ModerationMailEventHandlerTest`, `AppealRecoveryServiceImplTest`, `SupportTicketServiceImplTest`, `VerificationServiceImplTest`, `DomainWritersSeedWriterIT`, `SupportSeedWriterIT`, incidental in `AdminUserEventControllerIT`.

**Documentation**: `backend/docs/modules/admin/DATA_RULES.md` §1/§2/§3A/§3B/§4 (append-only rule, admin-deletion-preserving-audit-rows rule via V29, null-actor-strike rule); `backend/docs/modules/GLOBAL_RULES.md:184`; `backend/.claude/rules/struct.md` module roster + 35-value `admin_action_type` enum table; `backend/docs/modules/support/DATA_RULES.md` (extensive cross-references for the appeal/verification flows).

### D.2 `platform_stats`

**DDL** (`backend/database/schema.sql:999-1007`, from V70): `bucket_start TIMESTAMPTZ`, `granularity stat_granularity` (`half_hour`|`day`), `metric_key VARCHAR(64)`, `dimension VARCHAR(64) DEFAULT ''`, `value BIGINT`, `computed_at TIMESTAMPTZ DEFAULT NOW()`, composite PK `(bucket_start, granularity, metric_key, dimension)`. No FKs held or referencing it — a standalone pre-aggregated projection. One index (V71, `CONCURRENTLY`): `idx_platform_stats_series (metric_key, granularity, bucket_start DESC)`.

**`StatsCollectionJob`**: `@Scheduled(fixedDelayString="${app.stats.interval:PT30M}")`. Tracks `lastWrittenBucket` in memory; writes every completed bucket from `next` up to the newest complete bucket, capped at 48 buckets/pass; the in-progress bucket is never written; no backfill of a missed bucket is possible after the fact. Upsert via `ON CONFLICT (...) DO UPDATE SET value = EXCLUDED.value, computed_at = EXCLUDED.computed_at`. 14 metrics with exact source queries: GAUGEs `users_total`, `users_by_status`, `users_by_role`, `posts_total`, `comments_total`, `stories_total`, `reports_by_status`, `reports_by_reason` (each filtered by the source table's liveness/status condition as of `bucket_start`); FLOWs `registrations`, `posts_created`, `comments_created`, `follows_created`, `likes_created`, `admin_actions_by_type` (each a `[from,to)` count/group-by over the bucket window, no liveness filter).

**`StatsRollupJob`**: `@Scheduled(cron="0 20 3 * * *", zone=UTC)`. Compacts each UTC day's `half_hour` rows into one `day` row per `(metric_key, dimension)` — FLOWs sum, GAUGEs take the latest value ordered by `bucket_start DESC`. Aggregate-then-delete ordering is deliberate so a failed delete never loses an unrecoverable day.

**Retention**: `deleteFineBuckets` removes that day's half-hour rows immediately after the rollup insert (same transaction); `deleteDailyRowsBefore(now - dailyRetention)` prunes old daily rows from `pruneDailyRows`. Config (`StatsProperties`): `interval=PT30M`, `fineRetention=P30D`, `dailyRetention=P365D`, `rollupCron="0 20 3 * * *"`.

**Readers/endpoints**: `GET /api/v1/admin/stats/current` (no params) → `AdminStatsCurrentResponse` (snapshot fields plus one always-live field, `topHashtags`/`topHashtagsLive=true`, sourced directly from `hashtagRepository.findTopActiveByPostCount(10)` rather than a stored bucket). `GET /api/v1/admin/stats/timeseries` (params `metric`, `granularity?`, `from?`, `to?`; defaults to last 24h; rejects a single bound; validates window ≤ 1 year; server resolves granularity — an explicit `half_hour` request past the fine-retention horizon is rejected 400) → `AdminStatsTimeseriesResponse{metric, granularity, from, to, points[]}`. Both endpoints are `hasRole('ADMIN')` plus a service-layer `assertActorIsAdministrator` gate.

**Tests**: `PlatformStatsIT` (gauge/flow semantics, idempotent re-run, rollup sum/last-value, rollback ordering, retention pruning), `StatsCollectionJobTest`, `StatsBucketsTest`, `AdminStatsControllerIT` (403 for moderators, snapshot vs live read, default window, retention-boundary serving from daily rows).

**Seed writer**: `AnalyticsSeedWriter` seeds 90 daily buckets plus 30 days of half-hour buckets; must run last in the seed pipeline since its gauges anchor on final seeded row counts elsewhere.

**Documentation**: `backend/.claude/rules/struct.md` §7 (single-instance assumption, no distributed lock, upsert-idempotency); `backend/docs/modules/admin/DATA_RULES.md:14,16,26-27,28,119`.

### D.3 `user_events`

**DDL** (`backend/database/schema.sql:1169-1184`): `id UUID`, `user_id UUID NOT NULL`, `session_id UUID`, `event_type event_type NOT NULL` (20 declared enum values; only 6 are ever actually produced), `entity_type VARCHAR(50)`, `entity_id UUID`, `metadata JSONB`, `ip_address INET`, `user_agent TEXT`, `platform VARCHAR(10)` with a CHECK constraining it to `ios`/`android`/`web`, `created_at TIMESTAMPTZ`. Composite PK `(id, created_at)` (required because the partition key must be part of every unique constraint). `PARTITION BY RANGE (created_at)`, with a `user_events_default` catch-all. FK: `user_id → users(id) ON DELETE CASCADE`. Nothing references `user_events.id`. Indexes per partition: `idx_user_events_entity`, `idx_user_events_type`, `idx_user_events_user`. Partition history: V14 declared monthly partitions through 2026-06; V28 added a one-shot current+2-months fill; V69 closed a gap between V14's horizon and V28's start — with a documented, measured behavior that a write into an undeclared month lands silently in the DEFAULT partition and can never be moved into a real partition automatically afterward.

**Writers (two, opposite durability contracts)**:
- `UserEventRecorder` — fire-and-forget, writes `session_start`, `search`, `profile_view`. Runs on a `Semaphore(8)`-bounded virtual-thread `SimpleAsyncTaskExecutor`; permit exhaustion drops the write with a WARN; any JDBC exception is caught, logged, and swallowed, never rethrown. Call sites: `AuthServiceImpl` (login), `UserServiceImpl` (viewing another profile — own-profile views record nothing), `UserSearchServiceImpl`/`PostSearchServiceImpl` (search).
- `RecommendationFeedbackConsumer` — durable, `@RabbitListener`, manual ack/nack with DLQ on failure. Double idempotency: the shared `ProcessedMessageService.processOnce` inbox guard, plus a row-level `INSERT ... ON CONFLICT (id, created_at) DO NOTHING` in `UserEventJdbcRepository`. Consumes `post.liked.v1`, `post.saved.v1`, `post.viewed.v1`, `comment.created.v1`, `comment.liked.v1`, `message.post-shared.v1`.

**Gorse rebuild path (precise)**: `RecommendationFeedbackConsumer` calls `gorseClient.insertFeedback(...)` **synchronously, per event, immediately after the `user_events` insert succeeds** — this is real-time incremental feedback push, not a batch/scheduled rebuild. Gorse accumulates value for a repeated `(type,user,item)` tuple, so redelivery safety depends entirely on the inbox idempotency guard, not on Gorse itself. **No scheduled bulk rebuild job exists in application code** — grep of the recommendation module's `@Scheduled` methods finds only `HashtagAffinityJob`, `SuggestionPrecomputeJob`, `UserEventsPartitionJob`, none of which touches Gorse or bulk-reads `user_events`. Per `backend/docs/modules/recommendation/README.md` §7, a real Gorse resync is a manual operational procedure only, with two documented options: a full dev/seed reset (`SeedResetService.reset()` + `SeedOutboxEmitter.emitFullVolume()`, which replays post-index events, not user-events specifically), or an undocumented one-off manual push of current rows through Gorse's REST API ("No such script is checked into the repository"). The demo `gorse/seed/seed.py push` script pushes only synthetic data, not a real rebuild.

**Administrator activity log read path**: `AdminUserEventServiceImpl.listUserEvents` mandates a bounded `[from,to)` window of at most 30 days (`validateWindow` rejects null bounds, `to <= from`, or a window over `MAX_WINDOW_DAYS`); optional `userId`/`eventType` filters; keyset pagination via `UserEventRepository.findPage`. Endpoint `GET /api/v1/admin/user-events` — `hasRole('ADMIN')` plus a second explicit service-layer authorization gate (the class Javadoc notes the class-level check alone is insufficient because moderators also match the broader `/api/v1/admin/**` matcher). Response: `CursorPageResponse<UserEventResponse>` with fields `id, userId, eventType, entityType, entityId, metadata, createdAt`.

**`UserEventsPartitionJob`**: daily `0 5 0 * * *` UTC, creates current month + 2 months ahead (`LEAD_MONTHS=2`) via `CREATE TABLE IF NOT EXISTS ... PARTITION OF user_events FOR VALUES FROM ... TO ...`; a per-month DDL failure is logged and does not abort the other months; dropping old partitions is explicitly out of scope (the DEFAULT partition is the permanent safety net and rows landing there are the alert signal for horizon drift).

**Entity mapping**: `UserEvent` is `@Immutable`, all columns `updatable=false`; class Javadoc states all writes happen via plain JDBC outside the persistence context (`UserEventJdbcRepository`, no reads exposed from it).

**Tests**: `UserEventRepositoryImplIT`, `UserEventRecordingIT` (end-to-end login/search/profile-view behavior including negative cases), `UserEventsPartitionJobTest`, `AdminUserEventControllerIT`, `RecommendationFeedbackConsumerTest`, `GorseClientImplTest`, `RecommendationSourceTest`, `AdminUserEventServiceImplTest`, incidental coverage in several auth/search/user service tests, `DomainWritersSeedWriterIT`.

**Documentation**: `backend/.claude/rules/struct.md` §7 (partitioning trap + mandatory-read-bound invariant paragraphs, with measured partition-pruning figures); `backend/docs/modules/recommendation/README.md` (full write-path/rebuild architecture, §7 "Rebuild Gorse from PostgreSQL", "Known limitations" — fit-cycle lag, in-transaction Gorse call, drift-on-out-of-band-reset risk); `backend/docs/modules/recommendation/DATA_RULES.md` (two-writers statement, partitioning rules, FK cascade rule, append-only/immutable rule, "engagement write must never fail the triggering action" rule, mandatory time-bound section with an `EXPLAIN (ANALYZE, BUFFERS)` result: 24 partitions declared, 4 scanned for a bounded read, 61ms total); `backend/docs/modules/admin/DATA_RULES.md:93,138` (mandatory 30-day window; recommendation module named as the activity log's sole upstream dependency).

**Cross-cutting**: all three tables are written exclusively by server-side application/scheduled code, never directly from a client request body. The only direct relationship among the three is `platform_stats`'s `admin_actions_by_type` FLOW metric reading from `admin_actions`; `user_events` has no relationship to either.

## E. Other relational tables with telemetry character

**`email_deliveries`**: writer — `ModerationMailEventHandler` (four call sites) via `EmailDeliveryRepository.save(...)`, a bare `JpaRepository` with no custom finder methods. Reader — none found anywhere in `backend/src/main/java`; write-only in current code (append-only per its own Javadoc). Retention/cleanup — none found across all 13 `@Scheduled` classes. Status: written, never read, not dormant (actively written on every moderation-notice path).

**`processed_messages`**: writer/reader — `ProcessedMessageRepositoryImpl.insertIfAbsent`, an `INSERT ... ON CONFLICT DO NOTHING RETURNING`, called from `ProcessedMessageServiceImpl.processOnce` and used by every `@RabbitListener` consumer for idempotent processing; the insert result itself is the read (no separate query). Retention — none found. Status: actively written and consumed on every message-consumer path, not dormant.

**`outbox_events`**: writers — `OutboxServiceImpl` (enqueue), called from 20 domain service files across post/comment/notification/message/social/story/hashtag/media/auth/admin/recommendation/support modules. Readers — `OutboxPublisherServiceImpl` (claim/publish/mark). Retention — none found; rows accumulate indefinitely in `PUBLISHED`/`DEAD` state, no scheduled deletion. Status: actively written and read, core infrastructure, not dormant.

**`post_interaction_scores`**: no entity, repository, service, or job references it anywhere in `backend/src/main/java`. Only appears in `backend/database/schema.sql:1188` (DDL, comment states "updated by background scheduler" — that scheduler does not exist in code) and `SeedResetService.java:99` (truncation list). **Dormant.**

**`user_similarity`**: same situation — only in `backend/database/schema.sql:1201` and `SeedResetService.java:113`. No Java references anywhere. **Dormant.**

## F. Message module inventory for Phase 3 (inventory only, no design proposed)

**Repository methods / native queries** (`backend/src/main/java/com/app/modules/message/repository/`):
- `MessageRepository`: `findByIdAndConversationId`; `findFirstByConversation` (JPQL, newest-first, includes tombstoned rows); `findByConversationBefore` (keyset on `created_at`); `findLastMessagePerConversation` (native `SELECT DISTINCT ON (conversation_id)`); `countUnreadPerConversation`/`countTotalUnreadForUser` (native, joins `conversation_participants`, uses `IS DISTINCT FROM`); `findSenderIdForModeration` (native, bypasses tombstones); `isAdminRemoved` (native); `applyAdminModeration` (native `UPDATE ... admin_removed_at`).
- `ConversationRepository`: `findDirectConversationBetween` (native, double EXISTS + COUNT=2); `deleteEmptyDirectConversation` (native, `direct_pair_key` match + `NOT EXISTS` messages guard); `findFirstMyConversations`/`findMyConversationsBefore` (native keyset on `last_message_at DESC NULLS LAST, id DESC`, excludes pinned); `findMyPinnedConversations` (native, unpaginated).
- `ConversationRepositoryImpl.lockDirectConversationPair` — `pg_advisory_xact_lock(hashtextextended(pair.key,0))` using the same `LEAST/GREATEST` pair key as `direct_pair_key`.
- `ConversationParticipantRepository`: `existsByIdConversationIdAndIdUserIdAndLeftAtIsNull`, `findByIdConversationIdAndIdUserId`, `findByIdConversationIdOrderByJoinedAtAsc`, `findByIdConversationIdInAndLeftAtIsNull`, `countByIdConversationIdAndLeftAtIsNull`, `findActiveUserIdsByConversationId` (native, joins `users`, excludes muted + soft-deleted).
- `MessageIdempotencyRepository`: `findByUserIdAndIdempotencyKey`, `insertIfAbsent` (native `ON CONFLICT DO NOTHING`), `updateResponseBody`, `deleteByCreatedAtBefore` (purge).
- `archived_group_conversations`/`archived_group_participants`/`archived_group_messages`: **no Java code references them** at all — only a comment in `MessageSeedWriter.java:32`. Write-once-by-migration (V50), never touched by the application afterward.

**Transactional invariants**:
- Idempotency (V31, `message_write_idempotency`): `(user_id, idempotency_key)` UNIQUE, `ON CONFLICT DO NOTHING` reservation, purged hourly by `MessageMaintenanceScheduler.cleanupIdempotency()` using a configurable TTL.
- `direct_pair_key` (V33): deterministic `LEAST/GREATEST` pair key backed by a partial unique index; primary defense is the Postgres advisory lock in `ConversationRepositoryImpl`/`ConversationServiceImpl.createDirectConversation`, the index is the backstop.
- Sender history (V32): `messages.sender_id` FK changed `ON DELETE CASCADE` → `ON DELETE SET NULL`, made nullable, so a deleted sender's messages survive as history.
- `admin_removed_at` (V77): independent moderation tombstone, orthogonal to the sender-owned `is_deleted`/`deleted_at` pair; content preserved for restore; hidden when either tombstone is set.
- Unread flags (V53): `conversation_participants.is_manually_unread` — independent visual marker, not derived from `last_read_at`.
- Participant customization (V52): `pinned_at`, `is_muted`, `nickname` — additive nullable/defaulted columns.

**Cross-module dependencies**:
- **Blocks/social**: `MessageServiceImpl` and `ConversationServiceImpl` both call `socialService.isBlockedBetween(...)` to gate sends and conversation creation.
- **Reports**: `ReportType.MESSAGE` enum value, referenced by `AdminServiceImpl.moderateMessage` (routes message moderation through the report-resolution path).
- **Notifications/moderation**: `AdminServiceImpl.moderateMessage` calls `notifyContentRemoved(..., NotificationType.MESSAGE_REMOVED, ...)` and writes an `admin_actions` row via `AdminActionRecorder` (entity type `"message"`).
- **User status**: `findSenderIdForModeration`/`findActiveUserIdsByConversationId` account for soft-deleted senders and the nullable `sender_id` introduced by V32.

## G. Infrastructure

**G1. `backend/docker-compose.yaml` services** (all ports loopback-bound `127.0.0.1:*`):

| Service | Image | Ports | Key env | Volumes | Healthcheck |
|---|---|---|---|---|---|
| postgres | build `./docker/postgres` (base `postgres:latest`) | 5432 | `POSTGRES_DB/USER/PASSWORD`, `TZ` | `postgres_data` | `pg_isready` |
| rabbitmq | `rabbitmq:4-management` | 5672, 15672 | `RABBITMQ_DEFAULT_USER/PASS` | `rabbitmq_data` | `rabbitmq-diagnostics -q ping` |
| redis | `redis:7-alpine` | 6379 | `REDIS_PASSWORD` (+ `command: --requirepass`) | none | `redis-cli -a ... ping` |
| elasticsearch | `docker.elastic.co/elasticsearch/elasticsearch:9.0.3` | 9200 | `discovery.type=single-node`, `xpack.security.enabled=false`, `ES_JAVA_OPTS=-Xms512m -Xmx512m` | `elasticsearch_data` | `curl _cluster/health` |
| gorse | `zhenghaoz/gorse-in-one:0.5.11` | 8088 | Postgres-backed data/cache store, `GORSE_SERVER_API_KEY`, dashboard credentials | `config.toml:ro`, `gorse_data` | bash `/dev/tcp` probe of `/api/health/ready` |

**G2**: RabbitMQ `rabbitmq_prometheus` plugin — not enabled. The `4-management` image enables only the management UI plugin; no `enabled_plugins` file, Dockerfile, or config references `rabbitmq_prometheus` anywhere in `backend/`; port 15692 is not published.

**G3**: Gorse metrics endpoint — `backend/gorse/config/config.toml` has no `[metrics]` section or any prometheus/metrics key; `[master]` exposes `http_port=8088` for the dashboard/REST API only. Whether `gorse-in-one:0.5.11` exposes an implicit `/metrics` on that port is UNKNOWN — not resolvable without running the container or consulting upstream Gorse docs.

**G4**: Elasticsearch security — locally `xpack.security.enabled=false` (deliberate, given loopback-only binding). Production "xpack security enabled" is stated only in the user-supplied initiative context, not independently verifiable from this repository. A production exporter would need either HTTP Basic Auth (matching `ELASTICSEARCH_USERNAME`/`ELASTICSEARCH_PASSWORD` in `backend/.env.example:144-145`, which `ElasticsearchConfig` wires as optional) or an API key — UNKNOWN which scheme production actually uses, no production config in this repo.

**G5**: `pg_stat_statements` — not configured anywhere; no `shared_preload_libraries`/`pg_stat_statements` match across any SQL/Dockerfile/yaml/conf in `backend/`. `backend/docker/postgres/Dockerfile` builds from bare `postgres:latest`, adds only a timezone symlink, and copies an `init/` directory that only creates the `gorse` database. To accommodate it: a custom `postgresql.conf` or a `command: postgres -c shared_preload_libraries=pg_stat_statements` plus a `CREATE EXTENSION pg_stat_statements;` added to init SQL — `shared_preload_libraries` requires a server restart and cannot be set via `CREATE EXTENSION` alone.

**G6**: Observability/logging/management env vars — `backend/.env.example`: `APP_SECURITY_PUBLIC_METRICS_ENDPOINT` (gates unauthenticated `/actuator/prometheus`), `APP_NAME`, `LOG_PATH` (the only two vars logback-spring.xml reads directly). `application.yaml`: `management.endpoints.web.exposure.include`, `management.health.elasticsearch.enabled`, `management.endpoint.health.show-details`, `app.security.public-metrics-endpoint`, several `logging.level.*` overrides. `frontend/.env.example`: no observability/logging/management-related variables at all — only API URL, OAuth, app name/env, Turnstile site key.

**G7**: `docker ps` from this sandbox failed (`error during connect ... open //./pipe/dockerDesktopLinuxEngine: The system cannot find the file specified`) — Docker Desktop's engine is not running here, so live local environment state is UNKNOWN. Production host state is UNKNOWN — no host access, as expected for this sandbox.

## H. Frontend impact check

**H1**: Frontend files calling endpoints exposing these three tables (all in `frontend/src/features/admin/api/adminApi.js`):
- `getActions()` → `GET /admin/actions` (params `adminId, actionType, targetUserId, from, to, cursor, limit`); rows never carry `metadata`.
- `getAction(actionId)` → `GET /admin/actions/{actionId}`; the only place `metadata` is present.
- `getCurrentStats()` → `GET /admin/stats/current` (no params); consumes `computedAt` plus current snapshot figures.
- `getStatsTimeseries()` → `GET /admin/stats/timeseries` (params `metric, granularity, from, to`); consumed by `frontend/src/features/admin/lib/statistics.js` (`groupByDimension`); 14 known metric keys declared there.
- `getUserEvents()` → `GET /admin/user-events` (params `userId, from, to, eventType, cursor, limit`); consumed by `frontend/src/features/admin/hooks/useUserEvents.js`.
- Consuming screen: `frontend/src/features/admin/screens/ActivityLogScreen.jsx` for user events; other screens consume actions/stats via `adminApi`.

**H2**: The frontend sends no tracing header anywhere (`grep -i "traceparent|X-Trace|trace-id|X-Request-Id|traceId"` under `frontend/src` — no matches). Backend CORS `allowedHeaders` (`SecurityConfig.java:408-416`): `Authorization, Content-Type, Accept, Accept-Language, X-Requested-With, X-Device-ID, Idempotency-Key`. No tracing header is allow-listed; `exposedHeaders` is `Retry-After, X-Total-Count`. Adding a browser-originated tracing header would require adding it to `allowedHeaders` first, or the preflight would reject it.

## I. Test infrastructure

**I1**: Testcontainers pinned at `1.21.4` (`testcontainers.version`, `backend/pom.xml:33`, imported via `testcontainers-bom:1.21.4`). Declared artifacts: `spring-boot-testcontainers`, `org.testcontainers:postgresql`, `org.testcontainers:junit-jupiter`, `org.testcontainers:elasticsearch`. No dedicated `rabbitmq` or `redis` module artifact is declared.

**I2**: ClickHouse Testcontainers module availability for 1.21.4 — a `org.testcontainers:clickhouse` module has existed since roughly the 1.16 line and should be present in the 1.21.4 BOM catalog, but exact artifact coordinates/presence cannot be confirmed without web access. UNKNOWN with moderate confidence it exists; resolvable by fetching the 1.21.4 BOM POM or release notes.

**I3**: How integration tests obtain each service (verified against `AuthControllerIT`, `OutboxPublisherRabbitMqIT`, `ElasticsearchHealthIT`):
- **PostgreSQL**: `@Container @ServiceConnection PostgreSQLContainer<>("postgres:16-alpine")` — the enforced pattern.
- **Redis**: plain `GenericContainer<>(DockerImageName.parse("redis:7-alpine"))`, wired manually via `@DynamicPropertySource` — no dedicated Testcontainers Redis module.
- **RabbitMQ**: plain `GenericContainer<>(DockerImageName.parse("rabbitmq:3.13-alpine"))` — no `org.testcontainers:rabbitmq` module; note the pinned test image (`3.13-alpine`) differs from the compose stack's `rabbitmq:4-management`.
- **Elasticsearch**: `org.testcontainers.elasticsearch.ElasticsearchContainer` on `docker.elastic.co/elasticsearch/elasticsearch:9.0.3` with `xpack.security.enabled=false` — matches the compose image/version/security setting exactly.
- No shared base class provides any of this setup — each integration test class declares its own containers.

## J. Risks, conflicts, and unknowns

These are findings that conflict with the stated Phase 1/2 intent, or that require an architectural decision before implementation. No resolution is recommended here, per the discovery scope.

1. **No tracing foundation exists to build the "one continuous trace" requirement on.** Phase 1 asks for a single trace from HTTP request through `outbox_events`, the publisher, RabbitMQ, and every consumer. Today: no OTel SDK/exporter, no Micrometer Tracing bridge is on the classpath (only the OTel API/context/common artifacts are present, and only incidentally via the Elasticsearch client), `traceId` in every log line is always `none`, `DomainEventEnvelope` has no header/metadata field for a `traceparent`, `outbox_events` has no header column, and no `@RabbitListener` consumer reads AMQP headers at all (every one parses the body only via the shared `DomainEventMessageParser`). Evidence: sections A1, B2, C1, C3. Decision needed: whether to add a `traceparent`-carrying field to `DomainEventEnvelope`/`outbox_events` (a schema change) versus stuffing it into the existing `data` JSON map, and whether to introduce `micrometer-tracing-bridge-otel` + `opentelemetry-exporter-otlp` or the OpenTelemetry Java agent (agent compatibility with Spring Boot 4.0.x/Java 21 is itself UNKNOWN, section A4).

2. **The dominant async fan-out paths have no context-propagation mechanism today, and one of them explicitly detaches from the caller's transaction by design.** `UserEventRecorder` runs on its own semaphore-bounded virtual-thread executor with no `ContextSnapshot`/context-propagation wiring, and its Javadoc states its inserts must never extend the caller's transaction. The three `*.live.events` STOMP fanout paths are fire-and-forget (`ackMode=NONE`) by design, with documented best-effort delivery. Evidence: C7, C9. Decision needed: whether Phase 1's "continuous trace" requirement extends into these deliberately-decoupled async paths, or stops at the outbox/RabbitMQ boundary only.

3. **`/actuator/prometheus` is authenticated (`hasRole('ADMIN')`) by default in every profile, with no per-profile override.** A Prometheus scrape target needs either the `app.security.public-metrics-endpoint=true` opt-in (which the code itself logs a WARN about) or a scrape configuration that can authenticate as an ADMIN user. Evidence: A5. Decision needed: how the Prometheus exporter authenticates against this endpoint in both dev and prod, given Coolify's single-host, `coolify` Docker network topology.

4. **RabbitMQ has no Prometheus-compatible metrics surface today.** The compose image is `rabbitmq:4-management` (management UI only); the `rabbitmq_prometheus` plugin is not enabled and its port (15692) is not published. Evidence: G2. Decision needed: switch to a `rabbitmq:4-management` image with the prometheus plugin enabled (or an equivalent image), and publish the new port, before the Phase 1 exporter list can be satisfied.

5. **Gorse's metrics exposure is unverified and the test/compose RabbitMQ image versions already diverge from each other, foreshadowing an image-pinning decision the initiative will need to make broadly.** Gorse's `config.toml` declares no `[metrics]` section (G3, UNKNOWN whether an implicit endpoint exists). Separately, integration tests pin `rabbitmq:3.13-alpine` while compose runs `rabbitmq:4-management` (I3) — not itself a Phase 1/2 blocker, but evidence that image versions across environments are not currently kept in lockstep, which matters once a `rabbitmq_prometheus`-enabled image is chosen for compose/production and needs to be reconciled (or deliberately left unreconciled) against the test image.

6. **`pg_stat_statements` requires a Postgres server restart to enable (`shared_preload_libraries`), which the current Dockerfile/init-SQL setup does not accommodate.** The image is bare `postgres:latest` with only a timezone symlink and a database-creation init script; no `postgresql.conf` customization or `command`-line override exists. Evidence: G5. Decision needed: whether to bake `shared_preload_libraries=pg_stat_statements` into a custom `postgresql.conf` (or compose `command:`) plus an init-SQL `CREATE EXTENSION`, and how that interacts with Coolify's stated rule that mounted config files must pre-exist on the host path.

7. **`admin_actions` has an unconstrained, application-level FK-like reference from `notifications.admin_action_id`, which Phase 2's outbox-replication plan for `admin_actions` should account for.** Unlike every other table that dereferences `admin_actions.id` (`user_warnings`, `user_strikes`, `support_tickets`, `user_verifications`, `email_deliveries`, all with real FKs), `notifications.admin_action_id` has no declared foreign-key constraint at all. Evidence: D.1 (foreign keys section). Decision needed: whether this is acceptable for Phase 2 as-is, or whether the lack of a DB-level constraint here is itself a latent data-integrity gap worth fixing independent of the ClickHouse migration.

8. **`user_events` feeds Gorse in real time per event, not via any batch job — Phase 2's plan to move `user_events` fully to ClickHouse and drop the partitioned Postgres table must account for `RecommendationFeedbackConsumer`'s synchronous `insertFeedback` call, which currently happens in the same handler that inserts the Postgres row.** There is no scheduled/batch rebuild path in code to fall back on if the Postgres write path were removed — only a manual, undocumented operational procedure is described for a full resync. Evidence: D.3 (Gorse rebuild path), README §7. Decision needed: how the real-time Gorse feedback push is preserved once the durable `user_events` write target changes from Postgres to ClickHouse, especially given the existing double-idempotency guard (`processed_messages` + `ON CONFLICT DO NOTHING` on the Postgres row) that a ClickHouse target would need an equivalent for.

9. **`post_interaction_scores` and `user_similarity` are fully dormant** — schema exists, comments describe an intended background-scheduler/ML-job writer, but no Java code writes or reads either table today. Evidence: E. This doesn't conflict with Phase 1/2/3 directly, but it means any future design that assumes these tables are "live" (e.g. treating them as telemetry sources) would be building on tables with zero current activity, contrary to what `GLOBAL_RULES.md` §8's scope-simplification table implies is an active, if lagging, pipeline.

10. **Local verification of current table sizes/row counts, and any production-host facts, were both unavailable in this pass** — Docker Desktop's engine was not reachable from this sandbox (G7, D preamble) and production host access is out of scope by design. Evidence: repeated `docker ps` failures across all three research passes. Decision needed (procedural, not architectural): re-run the row-count/size queries once Docker Desktop is started locally, and gather the production host facts (G7 item 7) through whatever channel does have host access, before finalizing Phase 1/2 capacity planning.
