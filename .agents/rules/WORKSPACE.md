# Workspace Overview

## Structure

This is a monorepo workspace containing three independent sub-projects managed as Git Submodules.

| Sub-project | Path | Tech Stack | Own Rules |
|-------------|------|------------|-----------|
| Backend     | backend/ | Spring Boot 4, Java 21, PostgreSQL | backend/.claude/rules/ |
| Frontend    | frontend/ | React 19, Vite 8, Tailwind CSS v4 | frontend/.claude/rules/ |
| Observability | observability/ | OTel Collector, ClickHouse, Prometheus, Grafana | none - see root STRUCT.md |

## Git Model

- This root repo is an **aggregator only**. It contains no source code.
- All business logic commits go to the sub-project repos via their submodule directories.
- The root repo tracks: agent configuration, STRUCT.md, and submodule commit pointers only.
- Never commit source code changes to the root repo.
- Never create, use or keep a git worktree in this repository or any submodule. All work
  happens in the main checkout. `.worktrees/` is git-ignored at every level for this reason;
  a directory found there is leftover state, not a place to work from.

## Agent Working Instructions

1. Read AGENT_ROUTER.md to determine which sub-project rules to load for your task.
2. For BE tasks: navigate to backend/ and read its .claude/rules/ before acting.
3. For FE tasks: navigate to frontend/ and read its .claude/rules/ before acting.
4. For observability tasks: read the root STRUCT.md Observability subsection and observability/README.md before acting.
5. For cross-cutting tasks: read every sub-project's rule set that applies.
6. For any DB migration or data layer change: re-read GLOBAL_RULES.md in this directory.
