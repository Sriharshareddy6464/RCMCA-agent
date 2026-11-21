AGENT RULES v2 - SEQUENTIAL MODE. Paths relative to web/ (workspace root = 03_langgraph_mcp, also the git repo root).
0. ONE AGENT AT A TIME. The human runs exactly one agent per step on this single working tree: 0b foundation -> 1 shell -> 2 map -> 3 chat -> 4 forms -> Phase 2. Hand off with a clean tree (git status --short prints nothing).
1. FILE OWNERSHIP. Every file has exactly one owner (table below). Edit/create/delete only files you own; everything else is read-only (other tracks' files, mobile/, backend/, docs/samples, docs/reference, docs/MISSION.md). Being the only active agent is NOT permission to touch another track's files.
2. FROZEN FILES belong to foundation: package.json, package-lock.json, vite/tailwind/ts configs, index.html, src/index.css, src/types/**, src/lib/**, src/theme/**, src/components/ui/**, docs/CONTRACT.md, docs/AGENT_RULES.md, and any file not owned by a track. Never run npm install <pkg>. Need a change? Write docs/requests/<track>.md (what, why, exact proposed change), finish everything else, tell the human.
3. NO MOCK DATA. Lists, markers, routes, sheets, replies come from the live API.
4. NO INVENTED STYLE. Colors/radii/spacing/type from theme tokens. Missing token -> request it, never a hardcoded hex.
5. NO CROSS-TRACK IMPORTS except the frozen layer (types, lib, theme, ui). Only the shell imports track components. chat/report/sheets/map never import each other.
6. CONTRACTS ARE LAW. Never change a prop signature, file name or export. Replace skeleton bodies only. A Flutter behavior with no prop = a request.
7. GIT. Stay on the current branch; small commits; never switch/create/delete branches or tags; never rebase, reset or force. Never commit IDE folders (.kiro .agent .codex .opencode .kimi .gemini), .env or dist/.
8. PROVE IT. Run tsc --noEmit, npm run build, npm run dev and paste real output. If you can view the page, check 1440x900 and 390x844; if you cannot, write "not visually verified". Never claim what you did not see.
9. SCOPE. Build what Flutter has - nothing more. No extra features, refactors or libraries.
10. HANDOFF. Write docs/reports/<track>.md: files, exports/props, Flutter behaviors not replicated (why), requests, open questions. Then stop.
11. PRODUCTION API. GET freely. POST only /api/v1/chat and /api/v1/routes/plan, sparingly. Every other POST (issues/report, issues/refresh, issues/{id}/verify, issues/verify, issues/assess, uploads/local, uploads/presign, issues/{id}/vision) is BANNED until Phase 2: verify the request code by review against CONTRACT.md; if you have a browser, block the request in DevTools before it leaves.
12. ENV. Windows PowerShell: use curl.exe, not curl; use ';' not '&&' on PowerShell 5.1.

OWNERS
foundation (Codex): frozen files above
shell (OpenCode): src/App.tsx, src/main.tsx, src/state/**, src/components/shell/**
map (Antigravity): src/components/map/**
chat (Kimi): src/components/chat/**
forms (Kiro): src/components/sheets/**, src/components/report/**
Each track also owns docs/reports/<track>.md and docs/requests/<track>.md.
