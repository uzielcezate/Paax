# Meeting Notes

> **Purpose**: Stores notes from team meetings, planning sessions, design reviews, and retrospectives. Provides historical context and decision traceability.
> **Update when**: A meeting is held — add a dated note file using the template below and a row to the Index.

---

## Status

**This folder is currently a seed — it holds only this README; no meeting notes have been recorded yet.** Paax has been built as a small/solo effort where decisions landed directly in code and in [decisions.md](../decisions.md) rather than in minuted meetings. This folder exists so that once planning sessions, design reviews, or retrospectives do happen, there is a consistent home and format for them. When you hold the first meeting, drop a file here following the naming convention and template below, and add a row to the Index.

Related: architectural decisions live in [decisions.md](../decisions.md); the live task list is [TASKS.md](../TASKS.md); forward-looking ideas are in [IDEAS.md](../IDEAS.md).

---

## How to Use This Directory

1. Create one file per meeting, named: `YYYY-MM-DD-meeting-type.md`
   - Examples: `2025-01-15-sprint-planning.md`, `2025-01-20-design-review.md`
2. Use the template below for each new file.
3. Add a link to important decisions made in the meeting to `docs/decisions.md`.
4. Tag action items and assign owners clearly.

---

## File Naming Convention

```
YYYY-MM-DD-<meeting-type>.md

Meeting types:
  sprint-planning
  sprint-review
  retrospective
  design-review
  architecture-review
  stakeholder-review
  incident-review
  team-sync
  one-on-one
```

---

## Meeting Note Template

Copy this template when creating a new meeting note:

```markdown
# Meeting: <Title>

**Date**: YYYY-MM-DD
**Time**: HH:MM – HH:MM (Timezone)
**Attendees**: Name1, Name2, ...
**Facilitator**: Name
**Note-taker**: Name (or Agent)

---

## Agenda

1. 
2. 
3. 

---

## Discussion Notes

### Topic 1
<!-- Notes from discussion -->

### Topic 2
<!-- Notes from discussion -->

---

## Decisions Made

| Decision | Rationale | Owner |
|----------|-----------|-------|
| <!-- TODO: e.g., Adopt Supabase for auth --> | <!-- TODO: Faster iteration --> | <!-- TODO: @engineer --> |

> Add significant decisions to `docs/decisions.md`.

---

## Action Items

| # | Action | Owner | Due Date | Status |
|---|--------|-------|----------|--------|
| 1 | <!-- TODO --> | <!-- TODO --> | <!-- TODO --> | Open |

---

## Next Meeting

**Date**: <!-- TODO -->
**Agenda Items**: <!-- TODO -->
```

---

## Index

As meetings accumulate, add a row here (newest first) linking to each note.

| Date | Title | Key Decisions |
|------|-------|---------------|
| — | *(no meetings recorded yet — this folder is a seed)* | — |

---

*Last updated: 2026-07-16*
