# Coding Standards

> **Purpose**: Defines code style, conventions, and quality expectations for every contributor. Consistent code is easier to review, debug, and maintain.
> **Update when**: A new language or framework is adopted, or a team-wide style decision is made.

---

## General Principles

- **Readability over cleverness.** Code is read 10× more than written.
- **Explicit over implicit.** Make intent clear; avoid hidden side effects.
- **Consistent naming.** Use the conventions here everywhere.
- **Small functions.** Each does one thing well.
- **No dead code.** Remove unused code (git recovers it). Paax already carries dead code (`deezer_api_client`, `media_session_web`, orphaned resolver) — do **not** add more; prefer deleting it. See [AI_NOTES.md](AI_NOTES.md), [TECH_DEBT.md](TECH_DEBT.md).
- **Be honest in comments.** Several stale comments in this repo lie (e.g. `just_audio`, "Manrope") — keep comments truthful and update them when code changes.

---

## Languages in use

| Language | Where | Formatter | Linter |
|----------|-------|-----------|--------|
| Dart | `frontend/` | `dart format` | `flutter analyze` (`flutter_lints` ^6, `analysis_options.yaml`) |
| Python 3.11 | `paax-api/`, `paax-stream/`, `backend/` | (none enforced — recommend `black`) | (none enforced — recommend `ruff`) |
| JavaScript | `cloudflare-worker/` | (none) | (none) |

---

## Naming Conventions

| Construct | Convention | Example |
|-----------|-----------|---------|
| Dart variables/methods | `camelCase` | `currentTrack`, `playQueue()` |
| Python variables/functions | `snake_case` | `match_track`, `cache_get` |
| Classes | `PascalCase` | `PlaybackController`, `DeezerClient` |
| Constants | `UPPER_SNAKE_CASE` (Py) / `lowerCamel` const (Dart) | `_TTL_ALBUM`, `kPlayerHorizontalPadding` |
| Files | `snake_case` | `music_repository_impl.dart`, `youtube_matcher.py` |
| Private members | leading `_` | `_dataSource`, `_score_candidate` |
| Hive fields | never renumber `@HiveField(n)` | see [database.md](database.md) |

---

## File Organization

**Frontend (layer-first, the actual layout):**
```
frontend/lib/
  core/          # config, constants, image, network, playback, theme, utils
  data/          # api, local (Hive), repositories
  domain/        # entities, repositories (interface), services
  presentation/  # screens, widgets, state (Provider controllers)
```
> Note: this is **layer-first**, not the feature-first layout `.claude/rules/flutter.md` prescribes. Match the existing structure; do not introduce a parallel `lib/features/` tree. See [architecture.md](architecture.md).

**Backend (paax-api):**
```
paax-api/
  main.py                # FastAPI app + routes (v1 + v2)
  cache.py               # Redis + memory cache
  services/deezer|hybrid|youtube/
```
See [backend/services.md](backend/services.md).

---

## Documentation Standards

- Every public class/method/module gets a doc comment (`///` Dart, `"""..."""` Python).
- Document **why**, not what. The best example in this repo: `_mapTrackV2`'s comment explaining `Track.id = playback.videoId` — carry that habit.
- Keep the docs in `docs/` in sync in the **same change** per the Documentation Contract in [`PROJECT_RULES.md`](../PROJECT_RULES.md) / [`AGENTS.md`](../AGENTS.md).

---

## Error Handling

- Never swallow exceptions silently. The repo's mappers deliberately try/catch-and-skip malformed items *with a `debugPrint`* — that pattern is fine because it logs and degrades gracefully; silent empty-catch is not.
- Surface user-facing errors through `ErrorStateWidget` (client) with a retry, not raw exceptions.
- Backend: **do not** return `str(e)` to clients (current 500s leak internals — fix, don't copy). Map to stable error codes ([ERROR_CODES.md](ERROR_CODES.md)).

```dart
// ✅ Good — logs and degrades
try { return _mapTrackV2(e); } catch (err) { debugPrint('[Repo] skip: $err'); return null; }
```
```python
# ❌ Avoid — leaks internals
raise HTTPException(500, detail=str(e))
```

---

## State & UI conventions (Flutter)

- **No business logic in widgets** — widgets read controllers and dispatch; logic lives in `presentation/state/*` controllers, `domain`, or `data`.
- Prefer `context.select`/`Selector` over `context.watch` on hot paths to minimize rebuilds; use `ValueNotifier` for high-frequency values (position/duration).
- Never use `BuildContext` across an async gap without a `mounted` check.
- Use `const` constructors wherever possible.
- No hardcoded colors — use `AppColors`/`Theme` tokens. (The repo has some `#121212`/`#080808` drift — do not add more; see [design/colors.md](design/colors.md).)

---

## Imports & Dependencies

- Order: stdlib → third-party → internal.
- Remove unused imports before committing.
- No circular dependencies (the `Artist` entity uses `List<dynamic>` specifically to avoid a Hive-gen cycle — respect such workarounds).
- Do not add a dependency without updating [tech-stack.md](tech-stack.md) + [DEPENDENCIES.md](DEPENDENCIES.md) and (for anything significant) an [ADR](decisions.md).

---

## Code Formatting

- **Dart**: `dart format` (run before every commit). Config: `analysis_options.yaml`.
- **Python**: no formatter enforced today — **recommend adopting `black` + `ruff`** ([IDEAS.md](IDEAS.md)).
- Formatting/lint must pass before merge (`flutter analyze` is the current gate — see [testing.md](testing.md)).

---

## Anti-Patterns to Avoid

| Anti-Pattern | Why | Alternative |
|-------------|-----|-------------|
| God classes | Hard to test/maintain | Smaller focused classes |
| Magic numbers | Fragile, unreadable | Named constants (`kPlayerHorizontalPadding`) |
| Ad-hoc spacing literals | Inconsistent UI (already a problem here) | Adopt a spacing scale ([design/spacing.md](design/spacing.md)) |
| Deep nesting | Hard to read | Early returns / helpers |
| Raw `Image.network` on hot paths | 429 bans | Use `AppImage` (throttled) |
| Returning `str(e)` to clients | Leaks internals | Stable error codes |

---

## Linting

- **Tool**: `flutter analyze` (Dart), backed by `flutter_lints` ^6 via `analysis_options.yaml`.
- Must pass with zero errors before a PR merges.
- Python/JS linting is not yet configured — a backlog item.

See [`.claude/rules/flutter.md`](../.claude/rules/flutter.md), [`.claude/rules/backend.md`](../.claude/rules/backend.md), and [PROJECT_RULES.md](../PROJECT_RULES.md).

---

*Last updated: 2026-07-16*
