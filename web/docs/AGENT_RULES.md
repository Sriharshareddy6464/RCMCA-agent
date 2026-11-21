AGENT RULES - bind every agent. Paths are relative to 03_langgraph_mcp/web/
1. TERRITORY: write only inside your territory (table below). Everything else is read-only, including mobile/ and backend/. Flutter + backend are the source of truth, the brief is secondary; if they disagree follow Flutter/backend and say so in your report.
2. FROZEN after Phase 0: package.json, lockfile, vite/tailwind/ts configs, index.html, src/index.css, src/types/**, src/lib/**, src/theme/**, src/components/ui/**, docs/CONTRACT.md. Do not edit them. Never run `npm install <pkg>`. Need a change or dependency? Write it in docs/requests/<track>.md, tell the human, keep going with a workaround inside your territory.
3. NO MOCK DATA. Every list, marker, route, sheet, reply comes from the live API.
4. NO INVENTED STYLE. Colors/radii/spacing/type come from theme tokens. Missing token -> request it, never hardcode a hex.
5. NO CROSS-TERRITORY IMPORTS except the frozen layer (types, lib, theme, ui). chat never imports map; report never imports map; map never imports sheets.
6. Components are controlled via props in CONTRACT.md. Never change a prop signature or rename a file/export.
7. GIT: work only on your branch/worktree, commit often. IDE metadata folders (.kiro .agent .codex .opencode .kimi .gemini) are never committed. Before reporting, `git diff --name-only web/integration...HEAD` must list only files in your territory.
8. PROVE IT: "done" means you ran it - tsc --noEmit clean, npm run build passes, your harness page shows live API data at 1440x900 and 390x844. Paste evidence, do not just claim.
9. SCOPE: build what Flutter has, nothing more. No extra features, no refactors outside your files, no new libraries.
10. HANDOFF: finish with docs/reports/<track>.md - files created, exports/props, Flutter behaviors you could not replicate (why), requests, open questions. Then stop.
11. PRODUCTION API: GET freely. Do NOT submit POST /api/v1/issues/report or POST /api/v1/issues/refresh to production in Phase 1; inspect the outgoing request via devtools/Playwright request interception and abort it. Real submit is tested once in Phase 2 with the human's approval. Use chat sparingly.
HARNESS = throwaway dev page harness/<track>.html + src/harness/<track>.tsx that mounts only your component(s) against the live API. Never imported by the app. Removed in Phase 2.

TERRITORIES (write access)
foundation (Codex): all frozen files above
map (Antigravity): src/components/map/**, harness/map.html, src/harness/map.tsx
forms (Kiro): src/components/sheets/**, src/components/report/**, harness/forms.html, src/harness/forms.tsx
chat (Kimi): src/components/chat/**, harness/chat.html, src/harness/chat.tsx
shell (OpenCode): src/App.tsx, src/main.tsx, src/state/**, src/components/shell/**
Every track may also write its own docs/reports/<track>.md and docs/requests/<track>.md.
