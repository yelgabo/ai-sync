# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

ai-sync is a git-backed sync tool for AI tool configurations across machines. Supported environments: Claude Code (`~/.claude`), Codex (`~/.codex` or `$CODEX_HOME`), OpenCode (`~/.config/opencode/`), Antigravity (`~/.antigravity`).

## Commands

```bash
npm run build              # Build with tsup → dist/
npm test                   # Run Vitest tests
npm run test:coverage      # Tests with coverage
npm run lint               # Biome lint
npm run format             # Biome format (writes)
npm run typecheck          # tsc --noEmit

# Single test file or test name filter
npx vitest run tests/core/sync-engine.test.ts
npx vitest run -t "rewrites paths"
```

### CLI surface

```bash
ai-sync init | push | pull [--auto-apply] | status [--verbose] [--summarize]
ai-sync bootstrap <repo-url> | update | install-skills | migrate
ai-sync env list | enable <id> | disable <id>
ai-sync link | unlink                 # symlink config dirs into the sync repo
ai-sync fragment ...                  # fragment-based config (Claude CLAUDE.md)
ai-sync resolve list | diff <path> | accept <path|--all> | reject <path|--all>
```

AI-assisted merge is configured via `tools/merge-config.json` in the sync repo (see `docs/merge-config.md`). Enabled by default; set `"enabled": false` to opt out.

## Architecture

- `src/cli/` — Commander.js entry (`index.ts`) + per-command modules under `commands/`
- `src/core/` — Sync engine, manifest (allowlist), scanner, path rewriter, backups, environments, env-config, migration, provisioner, drift, linker, fragmenter, skills installer
- `src/core/merge/` — AI-assisted 3-way merge: `config.ts` (Zod schema), `adapters/` (claude/codex/opencode CLI wrappers), `strategies.ts` (per-filetype dispatch), `staging.ts` (`.ai-sync/pending/`), `resolver.ts`, `summarize.ts`, orchestrator (`index.ts` `tryAiMerge`)
- `src/git/repo.ts` — simple-git wrapper
- `src/platform/paths.ts` — Cross-platform path resolution (incl. `$CODEX_HOME`, `$XDG_CONFIG_HOME`)
- `tests/` — Mirrors `src/` structure, Vitest + memfs
- `skills/` — Slash command definitions; naming `<name>.<envId>.md` targets a specific env, `<name>.md` is shared

### Key flows

- **Environment plugin pattern:** `src/core/environment.ts` defines the `Environment` interface; each tool (Claude/Codex/OpenCode/Antigravity) is a class with `getConfigDir`, `getSyncTargets`, `getPathRewriteTargets`, `getSkillsSubdir`. Add a new tool by implementing the interface and registering it in `ALL_ENVIRONMENTS`.
- **Push/pull:** `sync-engine.ts` orchestrates scan (filtered by manifest) → path rewrite → git commit/push, or fetch → backup → path expand → write → optional AI merge for conflicts.
- **Repo versioning:** `migration.ts` handles v1 (flat) → v2 (per-env subdirs) → v3 layouts; `detectRepoVersion` runs on sync ops.
- **Provisioner:** `provisioner.ts` (called from sync-engine) discovers external tools and writes `tools/manifest.json` so other machines can re-provision; schema in `tool-manifest.ts`.

## Conventions

- ESM only (`"type": "module"`), Node.js 22+, TypeScript strict mode
- Node built-ins use `node:` prefix: `import * as fs from "node:fs"`
- Biome for formatting/linting: tabs, 100 char line width
- Commands export `registerXCommand(program)` + `handleX(options)` pattern
- Async/await throughout; errors caught in handlers with `process.exitCode = 1`
- Terminal output via picocolors (green=success, red=error, yellow=warn, cyan=info)
- Tests use `describe`/`it`/`expect` with memfs for filesystem mocking
- Git operations use explicit file paths, never `git add .`
- Allowlist-based sync enforced in `manifest.ts` (`isPathAllowed`); each env provides its own targets/ignore patterns
- Path rewriting: absolute paths ↔ `{{HOME}}` tokens for cross-platform portability (`path-rewriter.ts`), handles Windows forward/backslash and JSON-escaped `\\`
