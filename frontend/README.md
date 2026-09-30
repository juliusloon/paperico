# Paperico Web Client

The browser client: React 19 + TypeScript, Vite, Tailwind 4, Zustand, pdf.js.
Talks to the FastAPI backend over REST + SSE.

## Run

```bash
npm ci
npm run dev        # http://127.0.0.1:5173 (expects the backend on :8000)
```

From the repository root, `./start.sh` starts backend and web client together.

## Scripts

| Command | What it does |
|---|---|
| `npm run dev` | Vite dev server with HMR |
| `npm run build` | Type-check (`tsc -b`) + production build to `dist/` |
| `npm run lint` | Oxlint |
| `npm run preview` | Serve the production build locally |
| `npm run test:browser` | Playwright-based workspace smoke check (`scripts/verify-workspace.mjs`) |

## Structure

```text
src/
├── api/          typed API client + DTOs
├── components/
│   ├── chat/     evidence-grounded chat panel
│   ├── layout/   top bar, workspace navigation
│   ├── projects/ home, library, methods index
│   ├── reader/   three-pane reader, outline, pdf area, panels
│   └── settings/ LLM / MinerU / appearance settings
├── hooks/        shared hooks (e.g. useMediaQuery)
├── stores/       Zustand stores
└── App.tsx       routes
```

## Notes

- The dev server proxies API calls to the backend; make sure `backend/` is running.
- Math rendering uses remark-math + rehype-katex; PDF viewing uses pdf.js with a
  bundled worker.
- Set your AI/MinerU credentials in the in-app Settings page (stored encrypted on the
  backend) or in `backend/.env` — see [`backend/.env.example`](../backend/.env.example).
