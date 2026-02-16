# Clavain Command & Skill Count Audit

Date: 2026-02-15

## Executive Summary

CLAUDE.md claims 23 skills but the validation section has an inconsistency. The actual counts show discrepancies across multiple sources:

- **Actual command count**: 38 (matches CLAUDE.md and AGENTS.md)
- **Actual skill count (SKILL.md)**: 23 (matches CLAUDE.md but differs from AGENTS.md validation claim)
- **Actual agent count**: 4 (matches both docs)
- **Actual hook scripts**: 18 (CLAUDE.md claims 12)

## Detailed Findings

### Commands (`.md` files in `commands/`)

**Actual count: 38**

Files found:
1. brainstorm.md
2. changelog.md
3. interserve-toggle.md
4. compound.md
5. create-agent-skill.md
6. debate.md
7. doctor.md
8. execute-plan.md
9. fixbuild.md
10. galiana.md
11. generate-command.md
12. heal-skill.md
13. help.md
14. init.md
15. interpeer.md
16. interspect-correction.md
17. interspect-evidence.md
18. interspect-health.md
19. interspect.md
20. interspect-status.md
21. migration-safety.md
22. model-routing.md
23. plan-review.md
24. quality-gates.md
25. repro-first-debugging.md
26. resolve.md
27. review-doc.md
28. review.md
29. setup.md
30. smoke-test.md
31. sprint.md
32. sprint-status.md
33. strategy.md
34. triage.md
35. triage-prs.md
36. upstream-sync.md
37. work.md
38. write-plan.md

**Claim vs Reality**: ✓ MATCHES
- CLAUDE.md line 18: "Should be 38"
- AGENTS.md line 12: "38 commands"
- AGENTS.md line 231: "Should be 37" ← **OUTDATED**

### Skills (SKILL.md files in `skills/*/`)

**Actual count: 23**

**Claim vs Reality**: CONFLICT IN DOCS
- CLAUDE.md line 7: "23 skills" ✓ CORRECT
- CLAUDE.md line 16: "Should be 22" ✗ INCORRECT (off by 1)
- AGENTS.md line 12: "23 skills" ✓ CORRECT
- AGENTS.md line 229: "Should be 27" ✗ INCORRECT (off by 4)

### Agents

**Actual count: 4**

Verified agents:
- agents/review/data-migration-expert.md
- agents/review/plan-reviewer.md
- agents/workflow/pr-comment-resolver.md
- agents/workflow/bug-reproduction-validator.md

**Claim vs Reality**: ✓ MATCHES
- CLAUDE.md: "4 agents" (implicit)
- AGENTS.md line 12: "4 agents"
- AGENTS.md line 47: references "3 review agents" and "2 workflow agents" ← MISCOUNTED (actually 2+2=4)

### Hooks

**Actual hook scripts (.sh files): 18**

Located in hooks/:
- auto-compound.sh
- auto-drift-check.sh
- auto-publish.sh
- bead-agent-bind.sh
- catalog-reminder.sh
- interserve-audit.sh
- dotfiles-sync.sh
- interspect-evidence.sh
- interspect-session-end.sh
- interspect-session.sh
- lib-discovery.sh
- lib-gates.sh
- lib-interspect.sh
- lib-signals.sh
- lib.sh
- session-handoff.sh
- session-start.sh
- upstream-check.sh

**Hooks.json registrations: 8 unique hook definitions** (8 matched to lifecycle events)

**Claim vs Reality**: MISMATCH
- CLAUDE.md line 7: "12 hooks" ✗ INCORRECT (actual: 18 .sh files, 8 registered in JSON)
- AGENTS.md line 12: "12 hooks" ✗ INCORRECT

### MCP Servers

**Actual count: 1** (context7)

**Claim vs Reality**: ✓ MATCHES

## Document Discrepancies Summary

| Item | CLAUDE.md | AGENTS.md | Actual | Status |
|------|-----------|-----------|--------|--------|
| Commands | 38 | 38 | 38 | ✓ |
| Skills | 23 | 23 | 23 | ✓ |
| Agents | 4 (implicit) | 4 | 4 | ✓ |
| Hooks | 12 | 12 | 18 scripts / 8 registered | ✗ |
| MCP Servers | 1 | 1 | 1 | ✓ |
| CLAUDE.md validation line 16 | "Should be 22" | — | 23 | ✗ |
| AGENTS.md line 229 validation | — | "Should be 27" | 23 | ✗ |
| AGENTS.md line 231 validation | — | "Should be 37" | 38 | ✗ |

## T10 Validation Task

**Status**: NOT FOUND

No explicit "T10 validation task" was discovered. The validation checks in AGENTS.md (lines 226-253) appear to be the implicit validation checklist, but this is not labeled as "T10" nor tracked in .beads/ or formal task systems.

## Required Fixes

1. **CLAUDE.md line 16**: Change "Should be 22" → "Should be 23"
2. **AGENTS.md line 229**: Change "Should be 27" → "Should be 23"
3. **AGENTS.md line 231**: Change "Should be 37" → "Should be 38"
4. **CLAUDE.md + AGENTS.md line 7/12**: Clarify "12 hooks" (is this .sh files, registered hooks, or something else?)
5. **Create formal T10 task** if validation is required as ongoing work

## Verification

```bash
cd /root/projects/Interverse/hub/clavain
find commands -name "*.md" | wc -l          # 38
find skills -name "SKILL.md" | wc -l        # 23
find agents -name "*.md" | wc -l            # 4
find hooks -name "*.sh" | wc -l             # 18
```
