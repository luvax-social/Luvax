# Workspace Structure

## Section 1 — Workspace Layout

```text
<root>/
├── .claude/
│   └── rules/                # Agent rules — workspace scope
│       ├── WORKSPACE.md
│       ├── AGENT_ROUTER.md
│       ├── STRUCT.md
│       └── GLOBAL_RULES.md
├── .agents/
│   └── rules/                # Mirror of .claude/rules/ for Codex/Agents SDK
│       ├── WORKSPACE.md
│       ├── AGENT_ROUTER.md
│       ├── STRUCT.md
│       └── GLOBAL_RULES.md
├── .gitmodules               # Submodule declarations (path + remote URL)
├── .gitignore                # Root-level ignores (no source-code ignores)
├── git-setup.sh              # Setup script — review before running
├── start-app.bat             # Windows one-click launcher: docker infra, backend, frontend
├── observability/            # Observability sub-project (OTel Collector, ClickHouse, Prometheus, Grafana)
├── backend/                  # Backend sub-project (Spring Boot)
└── frontend/                 # Frontend sub-project (React + Vite)
```

### Git Submodule Configuration

| Submodule | Path | Remote | Branch |
|-----------|------|--------|--------|
| Backend | backend/ | https://github.com/luvax-social/backend.git | main |
| Frontend | frontend/ | https://github.com/luvax-social/frontend.git | main |
| Observability | observability/ | https://github.com/luvax-social/observability.git | main |

### Observability

`observability/` holds the Phase 1 monitoring stack, run locally behind a Compose profile (`compose.local.yaml`) and deployed in production as a separate Coolify resource (`compose.prod.yaml`).
See `observability/README.md` for the full runbook.
Its remote has no history under the `zentech-graduation` org to redirect from (unlike backend and frontend, which were renamed into `luvax-social` and kept the old org's URL working); it was created directly under `luvax-social`, so its `.gitmodules` URL does not follow the `zentech-graduation/*` pattern the other two do.

| Service | Image | Role |
|---|---|---|
| `otel-collector` | `otel/opentelemetry-collector-contrib:0.161.0` | OTLP traces/logs in (4317 grpc, 4318 http), container log discovery, exports to ClickHouse |
| `clickhouse` | `clickhouse/clickhouse-server:26.3.33.24` | `otel.otel_logs` (14d TTL) and `otel.otel_traces` (7d TTL); HTTP on 8123 |
| `prometheus` | `prom/prometheus:v3.15.0` | Scrapes the backend's management port (8081) and every exporter below; UI on 9090 |
| `grafana` | `grafana/grafana:13.2.2` | Ten dashboards, Discord-backed alerting; UI on 3000, the only public component in production |
| `docker-socket-proxy` | `tecnativa/docker-socket-proxy:v0.5.0` | Read-only Docker API for the collector's container-log discovery |
| `postgres-exporter`, `redis-exporter`, `elasticsearch-exporter`, `node-exporter`, `cadvisor` | see `observability/compose.local.yaml` | Infrastructure metrics for the dashboards above |

**ClickHouse is pinned to the 26.3 LTS line (`26.3.33.24`) and must not move past 26.5.**
From 26.6 the official build's default target is x86-64-v3 (AVX2); the production host's CPU has no AVX2, and `26.8.10.6` was reproduced crashing with `SIGILL` there.
This constraint outlives Phase 1: Phase 2 analytics work on the same ClickHouse instance inherits it until the host's CPU model changes.

Traces and logs are best effort and disposable, rebuilt from nothing but live traffic; PostgreSQL stays the only source of truth (`GLOBAL_RULES.md` §1).

---

## Section 2 — Backend Overview

Full detail: `backend/.claude/rules/struct.md`

### Technology Stack

| Component | Value |
|-----------|-------|
| Language | Java 21 (virtual threads enabled) |
| Framework | Spring Boot 4.0.6 |
| Database | PostgreSQL |
| Cache | Redis |
| Message Broker | RabbitMQ |
| Build | Maven (`./mvnw`) |
| Migrations | Flyway (126 migrations, V01-V126) |
| Resilience | Resilience4j (Spring Cloud 2025.1.1) |
| Security | Spring Security 6, JWT |
| ORM | Spring Data JPA / Hibernate |
| Formatting | Spotless 2.46.1 (Google AOSP) |
| Testing | JUnit 5, Testcontainers; 264 test classes |

### Application Purpose

Instagram-style social network: profiles, follow graph, photo/video/carousel posts, likes/saves,
nested comments, 24-hour stories, 1-1 and group DMs, hashtags, ranked feed.
Architecture: **Modular Monolith**.

### Module Roster

All fifteen modules are implemented; none is an empty scaffold.

| Module | Responsibility |
|--------|----------------|
| `auth` | Login, register, Google OAuth2, JWT refresh, password reset, email verification |
| `mail` | Transactional email via Resend; auth mail and the separate moderation notice path |
| `users` | Public and private profiles, settings, role and status management |
| `social` | Follow graph with pending requests for private accounts, block list |
| `media` | Pre-signed Cloudflare R2 upload URLs, media asset lifecycle |
| `post` | Post CRUD, likes, saves, views, edit history, Elasticsearch sync |
| `comment` | Threaded comments, likes, moderation, live WebSocket fanout |
| `hashtag` | Normalisation, trending, Elasticsearch sync, active/banned/deleted lifecycle |
| `story` | 24-hour stories, views, likes, expiry and cleanup |
| `notification` | Notification persistence, retrieval and live delivery |
| `message` | Direct conversations and messages, live delivery |
| `report` | User-submitted content flags and their triage lifecycle |
| `admin` | Moderation audit log, discipline ladder, hashtag registry, statistics |
| `recommendation` | `user_events` and the Gorse-backed ranked feed |
| `support` | Support tickets, the appeal route an unauthenticated disciplined account uses, and verification requests |

See `backend/.claude/rules/struct.md` for each module's sub-packages and
`backend/docs/modules/{module}/DATA_RULES.md` for its data rules.

### Infrastructure Services

- **PostgreSQL** (docker-compose): canonical data store; 126 Flyway migrations, nineteen of which build or drop indexes `CONCURRENTLY` behind a `.sql.conf` sidecar
- **Redis** (docker-compose): token blacklist, one-time email and password-reset tokens, rate limiting.
  Refresh tokens are SHA-256 hashed in PostgreSQL, not Redis
- **RabbitMQ** (docker-compose): async event delivery. 6 exchanges and 20 durable queues declared in `RabbitMqTopologyConfig`, driving 14 `@RabbitListener` consumers. `social.events` is the topic bus and `social.events.dlx` the dead-letter exchange; `comment.live.events`, `message.live.events`, `notification.live.events` and `post.live.events` are fanout tiers fed by exchange-to-exchange bindings. The 14 consumer classes carry 21 `@RabbitListener` methods between them
- Swagger / OpenAPI at `/api-docs` (dev profile only)

### Flyway Migrations

V01 extensions/enums → V02 users/auth → V03 settings/push → V04 social → V05 media →
V06 posts → V07 comments → V08 hashtags → V09 stories → V10 notifications → V11 messages →
V12 reports → V13 admin → V14 recommendation → V15 indexes → V16 triggers/functions →
V17 views → V18 metadata config tables → V19-V126 incremental schema evolution

The full V01-V126 table is in `backend/.claude/rules/struct.md`; it is maintained there rather than
duplicated here, because a list in two places drifts in one of them.

### Redis Key Patterns

| Pattern | TTL | Purpose |
|---------|-----|---------|
| `auth:token:email-verification:{sha256}` | 24h | Email verification token |
| `auth:token:password-reset:{sha256}` | 15m | Password reset token |
| `auth:blacklist:{jti}` | remaining access token lifetime | Token blacklist |
| `auth:ws-ticket:{ticket}` | 30s | One-time WebSocket handshake ticket |
| `comment:watchers:{postId}` | 300s | Live comment presence set |
| `hashtag:trending:personalised:{userId}:{page}:{size}` | 10m | Personalised trending fusion result |
| `comment:slowmode:{postId}:{userId}` | the post's slow-mode interval | Per-user comment slow mode |
| `auth:ratelimit:support:public:daily:{email}` | 24h sliding | Daily cap on the anonymous public support form |
| `support:token:appeal:{sha256}` | 30d | Single-use appeal link from a moderation notice |
| `support:token:confirmation:{sha256}` | 24h | Confirms the address a public support submission named |
| `app:{domain}:{id}` | varies | Single entries (planned) |
| `app:{domain}:list` | varies | Collections (planned) |

---

## Section 3 — Frontend Overview

Full detail: `frontend/.claude/rules/struct.md`

### Technology Stack

| Component | Value |
|-----------|-------|
| Framework | React 19 |
| Build Tool | Vite 8 |
| Package Manager | npm |
| Styling | Tailwind CSS v4 (`@tailwindcss/vite`) |
| UI Components | shadcn/ui + Radix primitives |
| Server State | TanStack Query v5 |
| Global Client State | Zustand v5 (with `persist` middleware) |
| HTTP Client | Axios v1 (`src/api/axiosClient.js`) |
| Routing | React Router DOM v7 (centralized config router) |
| Forms | React Hook Form v7 + Zod v4 |
| Language | JavaScript (no TypeScript; jsconfig.json for IDE support) |

### Source Tree

```text
src/
├── api/            # Axios client instances and interceptors
├── assets/         # Static assets
├── components/
│   ├── common/     # Route guards, shared pages (ProtectedRoute, GuestRoute, etc.)
│   └── ui/         # shadcn/ui primitives (Button, Input, Card, Label)
├── config/         # App constants, route paths, STALE_TIME, HTTP_STATUS
├── context/        # Reserved for React context providers
├── features/       # Six slices; sizes measured, not estimated
│   ├── admin/      # Moderation panel: queue, discipline, hashtags, statistics (13795 lines)
│   ├── auth/       # Login, register, OAuth2 callback, password reset (1629 lines)
│   ├── luvax/      # Main app shell: Feed, Explore, Profile, Story (16796 lines)
│   ├── messages/   # Direct conversations and live messaging (4913 lines)
│   ├── search/     # Search surface (990 lines)
│   └── support/    # Help centre, tickets, appeals, verification requests (2838 lines)
├── hooks/          # Shared reusable hooks
├── pages/          # Route-level pages not yet in a feature module
├── routes/         # Central React Router config (createBrowserRouter)
├── services/       # Shared API infrastructure (re-exports axiosClient)
├── store/          # Global Zustand stores (useAuthStore)
└── utils/          # Generic helpers (cn, helpers)
```

### Key Dependencies with Versions

| Package | Version | Role |
|---------|---------|------|
| react | ^19.2.6 | UI framework |
| react-router-dom | ^7.15.1 | Client-side routing |
| @tanstack/react-query | ^5.100.11 | Server state / caching |
| zustand | ^5.0.13 | Global client state |
| axios | ^1.16.1 | HTTP client |
| tailwindcss | ^4.3.0 | Utility CSS |
| react-hook-form | ^7.76.0 | Form state management |
| zod | ^4.4.3 | Schema validation |
| vite | ^8.0.12 | Build tool |
| vitest | ^3.2.7 | Test runner |
| eslint | ^10.3.0 | Linting |

There is no icon-set dependency. The 38 declared packages contain no `lucide-react`, no
`react-icons` and no `@heroicons`; an earlier revision of this document listed `lucide-react` and
was wrong.

### Key Scripts

```bash
npm run dev        # Start Vite dev server (via scripts/dev-server.mjs)
npm run test       # Vitest unit suite (vitest.config.js); what CI runs
npm run test:live  # Vitest live suite (vitest.live.config.js); needs a running backend
npm run build      # Production build
npm run lint       # ESLint
npm run preview    # Preview production build
```

### Regenerating the figures in this document

Every count, list and version above is produced by a script rather than maintained by hand.

```bash
backend/scripts/regenerate_struct_figures.sh     # migrations, modules, tests, RabbitMQ, Redis, versions
frontend/scripts/regenerate_struct_figures.sh    # slices, tree, routes, dependencies, scripts, env
backend/scripts/regenerate_schema_sql.sh         # rebuilds and verifies backend/database/schema.sql
```

Run the relevant one and paste its output back. This does not make the document self-updating; it
makes the next correction cheap.

### Environment Variable Prefix

All FE environment variables use the `VITE_` prefix (Vite convention).
See `frontend/.env.example` for the full list.

---

## Section 4 — Integration Points

### How FE Calls BE

- API base URL: configured via `VITE_API_URL` env var (default: `http://localhost:8080/api/v1`)
- In dev mode, Vite proxies `/api/v1` to the BE (configured in `frontend/vite.config.js`)
- Auth header: `Authorization: Bearer <accessToken>` injected by `axiosClient` request interceptor
- Token refresh: automatic on 401 — `axiosClient` intercepts, calls `/auth/refresh`, replays original request
- Public (unauthenticated) calls use `publicClient`; authenticated calls use `axiosClient`

### Auth Token Handling

| Token | Storage | Notes |
|-------|---------|-------|
| Access token | In-memory (Zustand, not persisted) | Short-lived; cleared on tab close |
| Refresh token | HttpOnly cookie, never readable by JavaScript | `Secure`, `SameSite=Lax`, path-scoped to `/api/v1/auth` |
| User + isAuthenticated | `localStorage` via Zustand persist | Key: `luvax-auth-session` |

### Shared Contracts

- No shared TypeScript types (project uses plain JavaScript on FE side)
- BE OpenAPI spec at `http://localhost:8080/api-docs` (dev profile) is the authoritative contract
- All BE API responses follow `ApiResponse<T>` wrapper shape; FE consumers must handle this envelope

### OAuth2

- Google OAuth flow initiated via `VITE_GOOGLE_AUTH_URL` (points to BE)
- Callback handled at FE route `/oauth2/callback` (`OAuthCallbackPage.jsx`)
- BE success handler redirects browser back to FE with `?code=...` query param
