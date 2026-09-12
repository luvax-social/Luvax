# Global Rules — Workspace Scope

Cross-cutting conventions that apply to all modules in both sub-projects.
Sub-project-specific rule files may refine or extend these rules; they never contradict them.

---

## 1. Data Tier Classification

| Tier | Technology | Role | Rebuild-able? |
|------|------------|------|---------------|
| Source of Truth | PostgreSQL | Canonical, durable data | No — this IS the source |
| Cache | Redis | Fast reads, session tokens, rate-limit state | Yes — rebuild from PostgreSQL |
| Search Index | (future: Elasticsearch) | Full-text search | Yes — rebuild from PostgreSQL |
| Event Stream | RabbitMQ | Async event delivery | No persistence guarantee |
| FE Server Cache | TanStack Query | In-memory server state cache | Yes — rebuilt from BE API responses |
| FE Local State | Zustand (in-memory) | Global client state (auth session, UI state) | Yes — rebuilt on next request or page load |

**Conflict resolution rule**: If a data conflict exists between tiers, PostgreSQL is always correct.
FE cache (TanStack Query) is always a derivative of BE API responses — never a source of truth.

---

## 2. Denormalized Counter Policy

All counters are maintained exclusively by PostgreSQL triggers. V16 defined the original set; a counter added later carries its own trigger in its own migration, and `stories.like_count` (V49) is the example.
Application code (Service, Repository) **and** frontend code must never directly increment or
decrement these counters. Display counter values from API responses only; do not compute or
patch them client-side.

| Counter | Table | Trigger | Source Table |
|---------|-------|---------|--------------|
| `follower_count` | `users` | `trg_follow_counts` | `follows` |
| `following_count` | `users` | `trg_follow_counts` | `follows` |
| `post_count` | `users` | `trg_post_count` | `posts` |
| `like_count` | `posts` | `trg_post_like_count` | `post_likes` |
| `comment_count` | `posts` | `trg_post_comment_count` | `comments` |
| `save_count` | `posts` | `trg_post_save_count` | `post_saves` |
| `like_count` | `comments` | `trg_comment_like_count` | `comment_likes` |
| `reply_count` | `comments` | `trg_comment_reply_count` | `comments` (self-referential) |
| `post_count` | `hashtags` | `trg_hashtag_post_count` | `post_hashtags` |
| `view_count` | `stories` | `trg_story_view_count` | `story_views` |
| `like_count` | `stories` | `trg_story_like_count` | `story_likes` (V49) |

If a counter appears stale, the correct action is to recalculate from the source join table — not
to patch the counter directly.

All counter columns have `CHECK (column >= 0)` enforced at the database level.

**Exception — `posts.view_count`**: Not maintained by a trigger. Updated by a background job
due to high-volume write concerns. `view_count` may lag behind real-time activity. Neither
application code nor frontend code must attempt to increment it directly.

---

## 3. Soft Delete Policy

Tables that use soft delete via a `deleted_at TIMESTAMPTZ` column:

| Table | Module |
|-------|--------|
| `users` | auth / users |
| `posts` | post |
| `comments` | comment |
| `stories` | story |
| `messages` | message (uses `is_deleted BOOLEAN` + `deleted_at`) |

`posts`, `comments`, `stories` and `messages` additionally carry an independent moderation
tombstone, which is not the same column as the owner's soft delete and must not be conflated with
it: `posts.status_before_moderation` (V59), `messages.admin_removed_at` (V77), and
`comments.admin_removed_at` / `stories.admin_removed_at` (V95). A row is hidden when either
tombstone is set; an administrative restore clears only the moderation tombstone and never undoes
an owner deletion.

Rules:
- All BE queries against soft-deleted tables must include `WHERE deleted_at IS NULL` unless
  explicitly retrieving deleted records.
- Hard deletes are reserved for administrative actions only.

### Username and Email Retention on Soft Delete

Soft delete does NOT release a user's `username` or `email`. The `UNIQUE` constraints remain
enforced regardless of `deleted_at`. A soft-deleted account holds its identifiers until a
hard delete (permanent row removal via a scheduled purge job — not yet implemented).

---

## 4. Transactional Boundaries

**Backend:**
- `@Transactional` is placed on Service **impl** methods only — never on interfaces or Controllers.
- Cross-module writes that must be atomic must be coordinated within a single Service method's
  transaction boundary.
- Never call multiple Service methods from a Controller and expect atomicity across them.

**Frontend:**
- The FE has no transaction concept. All state mutations are applied immediately (optimistic UI)
  or after the API response.
- Optimistic UI updates that assume success **must** be rolled back on API failure. If the FE
  pre-increments a counter or marks an item, it must restore the prior state when the request
  rejects. Never leave UI state ahead of confirmed server state without a rollback path.

---

## 5. ID Strategy

- All primary keys are `UUID` generated by `gen_random_uuid()` (PostgreSQL `pgcrypto` extension).
- Do not generate UUIDs in application code unless there is a documented reason.
- Join/relationship tables use composite primary keys (e.g., `post_likes(user_id, post_id)`).
- FE must treat all IDs as opaque strings — no numeric assumptions, no sequential ordering by ID.

---

## 6. Timestamp Policy

| Column | Set By | Notes |
|--------|--------|-------|
| `created_at` | Database `DEFAULT NOW()` | Do not set in application code |
| `updated_at` | Trigger `fn_update_updated_at` | Do not set in application code for tables that have this trigger |
| `deleted_at` | Application code | Set to `NOW()` on soft delete; `NULL` to restore |

All timestamps use `TIMESTAMPTZ` (timezone-aware). Store and compare in UTC.
FE must display timestamps in the user's local timezone — never assume UTC display.

---

## 7. Media Upload Flow

**Rule**: The server does not receive media file bytes directly. All media uploads use pre-signed URLs.

Flow:
1. Client requests a pre-signed upload URL from the backend, providing `content-type` and `file-size`.
2. Backend validates the request, generates a Cloudflare R2 pre-signed URL, and returns it to the client.
3. Client performs a `PUT` request directly to R2 using the pre-signed URL.
4. After upload completes, client sends an "upload complete" notification to the backend, including:
   `storage_key`, `cdn_url`, `media_type`, `mime_type`, `file_size`, `width`, `height`,
   `duration` (video only), `blurhash`.
5. Backend creates the `media_assets` record using the provided metadata.

**Rule**: All media metadata (`width`, `height`, `duration`, `mime_type`, `file_size`, `blurhash`)
is collected client-side and submitted by the client. The server does not perform server-side
media inspection at upload time.

---

## 8. Scope Simplifications (Deliberate Tradeoffs)

| Area | Simplification | Accepted Degradation |
|------|---------------|----------------------|
| Notifications | No real-time WebSocket delivery in v1 | Clients must poll for new notifications |
| Feed / Explore ranking | `post_interaction_scores` updated by a background scheduler, not in real-time | Feed ranking may lag behind actual activity by minutes |
| Hashtag trending | `hashtag_trending` populated by a scheduled background job | Trending data is a periodic snapshot, not live |
| Email verification / password reset tokens | Stored in Redis, not PostgreSQL | Tokens are lost on full Redis flush; user must re-request |
| Full-text search | No Elasticsearch in v1; username/hashtag search uses PostgreSQL `pg_trgm` GIN index | Search ranking is less sophisticated than a dedicated search engine |
| Recommendation | `user_similarity` and `post_interaction_scores` populated by external ML jobs | Recommendations may lag behind recent user behavior |
| Story expiry | Expired stories remain in the database until a cleanup job removes them | `expires_at` must always be checked; do not rely on row absence alone |

---

## Cross-Project Rules

### API Contract

- The BE is the single source of truth for all data shapes.
- FE must not hardcode data that should come from the BE API.
- Any DTO or response shape change on BE requires a corresponding update on FE.
- OpenAPI spec (Swagger) at `http://localhost:8080/api-docs` (dev profile) is the authoritative
  contract document.
- All BE responses are wrapped in `ApiResponse<T>`. FE consumers must unwrap this envelope.

### Environment Configuration

- BE environment variables: defined in `backend/.env.example`
- FE environment variables: defined in `frontend/.env.example`; all variables use the `VITE_` prefix
- Never commit `.env` files. Never commit secrets.
- Root-level `.env` files are prohibited.

### Rule Hierarchy

1. Root `GLOBAL_RULES.md` (this file): workspace-wide constraints — lowest override priority
2. `backend/.claude/rules/` files: BE-specific rules, extend root where they add specificity
3. `backend/docs/modules/GLOBAL_RULES.md`: BE data layer rules, take precedence for BE data decisions
4. `frontend/.claude/rules/global_rules.md`: FE-specific rules, extend root where they add specificity
5. `backend/docs/modules/{module}/DATA_RULES.md`: highest specificity, always win for their module

### Enum vs. Config Table Relationship

Several domain tables use PostgreSQL enum types as the column type for classification fields.
Alongside these, config tables store display metadata and behavioral policy for each enum value.

**Rule: Enums are the constraint layer. Config tables are the metadata layer.**

- The enum enforces valid, schema-defined values at the database level.
- The config table stores supplementary metadata: `display_name`, `template_key`, `is_enabled`, etc.
- Adding a new notification type, report reason, or admin action type requires a schema migration
  (adding the value to the enum). These are domain primitives, not user-configurable data.

### Metadata Configuration Tables

| Table | Purpose |
|-------|---------|
| `system_settings` | System-wide configurable limits and TTL values |
| `notification_type_configs` | Notification type registry with display and toggle settings |
| `moderation_action_configs` | Admin moderation action registry |
| `feature_flags` | Feature enable/disable control per environment |

**Rule**: These tables must never store secrets, private keys, OAuth credentials, database URLs,
or any sensitive environment-specific values. Those remain in environment variables.

---

## 9. Git Commit Conventions

**Rule**: Commit messages must never include AI co-author attribution in any form —
no `Co-Authored-By:` trailers, no "Generated with" footers, no agent names or signatures
of any kind. This applies to every sub-project and the root aggregator repository, and to
every agent (Claude Code, Codex, or any other Agents SDK client) working in this workspace.

Commit authorship reflects the human developer only.
