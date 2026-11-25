# Nutrio — Master Build Prompt

> Paste this whole document into your coding agent (Claude Code or similar) together with
> `db/schema.sql`, `db/seed.sql`, `backend/app/models.py` and `backend/app/nutrition.py`.
> Those four files are the **contract**: build on them, don't redesign them without asking.

---

## 0. How to work

You are building **Nutrio**, a personal fitness & nutrition SaaS with a calm AI agent. Work in the milestones from section 14, **one at a time**. After each milestone: run the tests, show how to verify it manually, then stop and wait for my go-ahead.

- If something here is ambiguous or conflicts with the contract files, **ask before assuming**.
- Prefer small, boring, well-tested code over clever code.
- Never invent API fields. When integrating Open Food Facts or Tavily, read their current official docs first and verify field names and limits.
- Keep a running `DECISIONS.md` for any deviation or open question.

---

## 1. Product in one paragraph

Nutrio is "MyFitnessPal with an agent that actually does things." I log food (by search, barcode, templates, or by telling the agent), track body measurements and workouts, and see progress in charts. The agent, also called **Nutrio**, is calm and gentle: it reads my real data, searches the web (Tavily), and **creates drafts** (recipes, meal plans, workout plans, shopping lists) that appear in the app for me to approve. Its signature feature: I keep a list of **favorite foods**, and Nutrio proposes **healthier, higher-protein or lower-calorie versions** of them, or smart **alternatives** for the same craving.

Single user today, but everything is `user_id`-scoped so it can become a multi-user SaaS later.

---

## 2. Non-negotiable rules

1. **PostgreSQL is the only source of truth.** All user data, reference data (meal types, units, activity levels, variant types...), tunable settings, safety limits and the agent's system prompt live in the database (see `seed.sql`). **No hardcoded domain data in code.** Code refers to rows by stable `code`.
2. **No `localStorage`, `sessionStorage`, IndexedDB or any browser persistence.** UI state is in-memory only (React state / TanStack Query cache). Auth is a server-side session referenced by an **httpOnly, Secure, SameSite=Lax cookie**. Anything that must survive a reload goes to the API/DB (e.g. selected date can live in the URL).
3. **Pydantic v2 everywhere** for API bodies, agent tool I/O, and external data (Open Food Facts). Invalid data fails loudly at the boundary.
4. **The LLM never does arithmetic.** Calories, macros, recipe totals, daily totals, trends, TDEE, shopping quantities and variant comparisons come from deterministic code (`nutrition.py` and SQL views). The agent chooses *what* and *how much*; code computes *the numbers*.
5. **Agent-created content is always a draft** (`status='draft'`) until I approve it in the UI. The only exception is logging a meal when I explicitly ask the agent to log it.
6. **Logged data is a snapshot.** `food_logs` stores macros at log time; later changes to a food never rewrite history.
7. **UI language is English.** Store the user's `language`; prefer English food names from Open Food Facts with fallback to the original name.
8. **Secrets only in environment variables.** Never in code, DB or logs.
9. Nutrio is **not medical advice**. Safety limits come from `safety_rules` and are enforced in the service layer for both users and the agent.

---

## 3. Tech stack

**Backend:** Python 3.12, FastAPI, Pydantic v2, SQLAlchemy 2.x (async) + asyncpg, Alembic, httpx, `argon2-cffi` for passwords, `uv` for dependencies, Ruff + mypy, pytest + pytest-asyncio + testcontainers (real Postgres in tests).
**Agent:** Pydantic AI (typed tools, structured outputs, retries). Model is configurable through env (`AGENT_MODEL`), no model name in code. Tavily Python SDK for web search.
**Frontend:** Next.js (App Router) + TypeScript (strict), Tailwind CSS, Radix UI primitives (shadcn-style, restyled), Framer Motion, TanStack Query, Recharts (or visx), Lucide icons. **API types generated from FastAPI's OpenAPI** with `openapi-typescript` so Pydantic is the single source of truth.
**Infra:** Docker Compose (postgres 16, api, web), `.env.example`, Makefile (`make dev`, `make test`, `make migrate`, `make seed`).
**Mobile-first PWA:** installable manifest and responsive layout, **no offline data cache in the browser** (rule 2). Show a calm "You're offline" state instead.

---

## 4. Repository layout

```
nutrio/
  docker-compose.yml  .env.example  Makefile  DECISIONS.md
  db/            schema.sql  seed.sql        # contract; Alembic migrations generated from these
  backend/
    app/
      main.py  config.py  deps.py  errors.py
      models.py            # Pydantic (contract)
      nutrition.py         # pure functions (contract)
      db/                  # SQLAlchemy models, session, migrations
      repositories/        # SQL only
      services/            # business rules (safety, drafts, snapshots)
      routers/             # auth, profile, measurements, goals, foods, logs, templates,
                           # recipes, favorites, plans, workouts, shopping, chat, settings
      integrations/        # openfoodfacts.py, tavily.py
      agent/               # nutrio.py (agent), tools/*.py, context.py, runner.py
    tests/
  web/
    app/ (routes)  components/ui/  components/features/  lib/api/ (generated client)  styles/
```

Layering: routers → services → repositories. Tools used by the agent call the **same services** as the HTTP API (one code path, one set of rules).

---

## 5. Data layer

- Apply `schema.sql`/`seed.sql` as the baseline Alembic migration; later changes are new migrations.
- All writes go through services that enforce rules the DB can't (safety limits, ownership, date ranges).
- **Row ownership:** every query is scoped by `user_id`. Add a test that proves user A can't read or modify user B's rows on every router.
- Body measurements and goals are **append-only**: corrections void the old row (`voided_at`) or close the goal period (`end_date`) and insert a new one.
- When a new goal is created, close the previous open goal (`end_date = new.start_date`) in the same transaction.
- `log_date` is the user's **local calendar day** computed from `users.timezone`, so a snack at 00:30 local time lands on the right day.
- Use the views `v_daily_totals`, `v_weight_series`, `v_current_body`, `recipe_nutrition` for dashboards; don't recompute in Python.

---

## 6. API (REST, JSON, versioned `/api/v1`)

All responses are Pydantic models. Errors use one consistent envelope `{ "error": { "code", "message", "details" } }`. Auth endpoints rate-limited. Cursor pagination on lists.

- **Auth:** `POST /auth/register`, `/auth/login`, `/auth/logout`, `GET /auth/me` (session cookie; rotate on login; store only token hash).
- **Profile & settings:** `GET/PATCH /profile`, `GET/PATCH /agent-preferences`, `GET /reference/{meal-types|units|activity-levels|goal-types|variant-types|aisles|muscle-groups|equipment}`.
- **Body:** `POST/GET /measurements` (+ `/measurements/series` using `v_weight_series`), `POST /measurements/{id}/void`.
- **Goals:** `GET /goals/current`, `GET /goals/history`, `POST /goals`, `POST /goals/suggest` (BMR/TDEE-based using `nutrition.py`, enforces `safety_rules`), `GET /goals/adaptive-suggestion`.
- **Foods:** `GET /foods/search?q=` (local cache first, then Open Food Facts), `GET /foods/barcode/{code}`, `POST /foods` (manual), `POST /foods/{id}/correct` (creates my own corrected copy with `derived_from_food_id`), `GET /foods/recent`.
- **Diary:** `GET /logs?date=`, `POST /logs`, `PATCH/DELETE /logs/{id}`, `POST /logs/copy-day {from, to, meal_types?}`, `GET /logs/totals?from=&to=`.
- **Templates:** CRUD `/meal-templates`, `POST /meal-templates/{id}/log {date, meal_type_code}`.
- **Recipes:** CRUD `/recipes` (+ nutrition from `recipe_nutrition`), `POST /recipes/{id}/approve|reject`.
- **Favorites:** CRUD `/favorites`, `POST /favorites/{id}/variants/generate` (runs the agent), `GET /favorites/{id}/variants`, `POST /variants/{id}/decision` (accept/reject + feedback), `POST /variants/{id}/log` (log the accepted variant).
- **Plans:** `/meal-plans` and `/workout-plans` CRUD + `approve|reject`; `POST /meal-plans/{id}/apply-to-diary` optional.
- **Workouts:** `POST /workout-logs`, `GET /workout-logs`, `GET /exercises/{id}/progress` (volume, best set, estimated 1RM over time).
- **Shopping & pantry:** `POST /shopping-lists/generate` (from plan or date range, subtracts pantry), item check/uncheck, `/pantry` CRUD.
- **Chat:** `POST /chat` (SSE stream), `GET /chat/threads`, `GET /chat/threads/{id}`.

---

## 7. Open Food Facts integration

- Use OFF **API v2**: product by barcode, and search. Read the current docs for the exact endpoints, field names, rate limits and the **required custom User-Agent** (put it in `OFF_USER_AGENT`). Respect their usage rules, be a good citizen, cache aggressively.
- Flow: search/barcode → check local `foods` (global rows where `owner_user_id IS NULL`) → else fetch from OFF → `food_from_off_product()` → `assess_food_quality()` (tolerance from `app_settings`) → upsert into `foods`. Refresh items older than `food.cache_refresh_days`.
- Missing energy or macros → don't store; tell the UI the product is incomplete and offer manual entry.
- `data_quality='suspect'` items show a small, calm notice ("These numbers look a bit off, want to check the label?") and an easy **Correct** action that creates my own copy (`POST /foods/{id}/correct`).
- Show attribution to Open Food Facts (ODbL) in the app (Settings → About) and wherever required by their terms.
- Wrap in a small client with timeouts, retries with backoff, and a circuit breaker; if OFF is down, search still works on the local cache.
- Barcode scanning: use the browser `BarcodeDetector` API where available, with a lightweight JS fallback library; a manual "type the barcode" input always exists.

---

## 8. The agent: Nutrio

### 8.1 Behavior
- System prompt is loaded from `agent_prompts` (active row for `name='nutrio'`); per-user `user_agent_preferences` (verbosity, proactivity) are appended as instructions. **Never hardcode the persona in code.**
- Calm, gentle, short. No guilt, no pressure, one suggestion at a time.
- On every run, inject an `AgentContext` (see `models.py`): profile, current body stats, active goal, today's totals, allergies/preferences/dislikes, favorite names, min calorie floor, `refer_out_topics`.
- Persist every run in `agent_runs`, every tool call in `agent_tool_calls`, every message in `chat_messages`. Enforce `agent.max_tool_calls_per_run` and `agent.max_web_searches_per_run` from `app_settings`.
- Stream tokens and tool progress over SSE; show gentle progress text in the UI ("Looking at your favorites…").
- Output validation: structured outputs are Pydantic models (e.g. `VariantBatch`, `RecipeDraft`); on validation failure the agent retries (bounded).

### 8.2 Tools (all thin wrappers over services; all user-scoped; all logged)

**Read:** `get_profile`, `get_current_goal`, `get_body_trend(days)`, `get_day_log(date)`, `get_daily_totals(from,to)`, `list_favorites`, `get_favorite_variant_history(favorite_id)` (including rejected ones and feedback), `list_recipes`, `get_active_meal_plan`, `get_active_workout_plan`, `get_recent_workouts`, `get_pantry`.
**Food data:** `search_foods(query)` and `get_food_by_barcode(code)` (Open Food Facts via the cache; return food ids and per-100 g nutrients), `get_recipe_nutrition(recipe_id)`.
**Web:** `web_search(query)` (Tavily; return titles, urls, short snippets; the agent must keep source URLs).
**Create (always draft):** `propose_recipe(RecipeDraft)`, `propose_favorite_variants(VariantBatch)`, `propose_meal_plan(MealPlanDraft)`, `propose_workout_plan(WorkoutPlanDraft)`, `propose_meal_template`, `propose_shopping_list(ShoppingListRequest)`.
**Act (only when explicitly asked):** `log_food(FoodLogCreate)`, `log_measurement(BodyMeasurementCreate)`.

Every `propose_*` tool: validates with Pydantic → resolves `food_id`s and rejects unknown ones → **computes macros in code** → enforces safety rules and allergies/dislikes → saves as draft → returns a `DraftRef` the UI renders as an approve / edit / discard card.

### 8.3 Safety (service layer, not just prompt)
- Reject any goal or plan whose daily calories fall below `safety_rules.min_daily_kcal.*`, or exceed `max_deficit_pct` / `max_weekly_loss_pct`.
- Reject recipes/plans containing foods that match my `allergies` (match on food name, categories and ingredient text; err on the side of caution) and de-prioritize `disliked_foods`.
- If my message mentions a `refer_out_topics` item, the agent stays general and kindly suggests a qualified professional; log a flag on the run.
- Plans are only generated if the user is an adult (`min_age_years`).

### 8.4 Evals
Add a small eval suite (pytest, mocked model + a few recorded scenarios) checking: never invents food ids, never outputs macros it didn't get from tools, always creates drafts, respects allergies, tone has no shaming language, stays under tool-call caps.

---

## 9. Favorites → healthier variants (the signature feature, build it carefully)

**Favorites list** (`favorite_foods`): add from a food, a recipe, or free text ("Mum's lasagna"), with category, why I like it, frequency, tags, notes. It is a first-class screen, not a buried setting.

**Generating variants** (`POST /favorites/{id}/variants/generate`, or from chat):
1. Resolve the favorite's **baseline macros per serving** (food → scaled serving; recipe → `recipe_nutrition`; free text → the agent first builds a baseline recipe draft, which I confirm).
2. Gather context: my goals, allergies/dislikes, past variants **and their feedback** (don't repeat rejected ideas), requested `variant_type` codes (default from my goal).
3. Agent searches the web (Tavily) for healthier takes, adapts them (not copy-paste), and returns a `VariantBatch` with up to `agent.max_variants_per_favorite` items:
   - **recreation**: the same dish, rebuilt (e.g. higher-protein lasagna with different ingredients and quantities);
   - **alternative**: a different food that scratches the same itch.
4. **Code verifies the promise**: compute the per-serving macros of each variant, build a `MacroComparison`, and run `check_variant_rule(variant_types.rule, comparison)`. Variants that fail are sent back to the agent once with the reasons; if they still fail they are discarded. Never show a "high-protein" variant that isn't.
5. Save as `favorite_variants` drafts with the comparison snapshot and source links.

**UI:** a side-by-side comparison card (original vs. variant: calories, protein, carbs, fat with animated deltas such as "+14 g protein, −180 kcal"), source links, "Why this works" text, and three actions: **Accept** (saves the recipe, optionally adds to my recipes and plan), **Not for me** (asks one optional quick reason chip: too sweet, too complicated, tastes odd, other), **Try another**. Feedback is stored in `variant_feedback` and fed to future generations.

**Proactive moments** (respect `proactivity`; never more than one at a time): when I log a favorite and I'm near my calorie target, or at my usual meal time, Nutrio may gently offer the accepted lighter version.

---

## 10. Other features to implement

- **Meal templates:** save a set of foods as "My usual breakfast", log in one tap; the agent can propose templates.
- **Copy previous day / repeat meal:** `copy-day` endpoint + UI sheet.
- **Barcode scan** (section 7).
- **Shopping list** (`aggregate_shopping`): from a meal plan or date range, grouped by `store_aisles`, minus pantry; check items off; optionally "move bought items to pantry".
- **Adaptive calorie target:** `weekly_trend_kg` + `suggest_calorie_adjustment` with thresholds from `app_settings`; always a **suggestion card** I accept or dismiss, never an automatic change; every accepted change creates a new goal period.
- **Progress:** weight with 7-day average and goal line, body measurements, calorie/protein adherence, workout volume and per-exercise progression, all computed from the DB.
- **Workout logging:** log sets quickly (reps, weight, RPE), see the previous session's numbers inline, suggest progressive overload.
- **Export:** my data as JSON/CSV (Settings).

---

## 11. UI/UX — an Apple-inspired design system

**Feeling:** calm, spacious, quiet, precise. Things glide; nothing shouts. The app should feel like it belongs on an iPhone, but it's our own design. **Do not use Apple logos, SF Symbols assets or other Apple-owned artwork**, and don't claim to be Apple. Take the *principles*: clarity, deference, depth.

### 11.1 Design tokens (CSS variables; light and dark; follow `prefers-color-scheme`, with an in-app override stored in the DB profile, not in the browser)

```css
:root {
  --bg: #F2F2F7;           --bg-elevated: #FFFFFF;     --bg-grouped: #FFFFFF;
  --label: #000000;        --label-2: rgba(60,60,67,.60); --label-3: rgba(60,60,67,.30);
  --separator: rgba(60,60,67,.18);  --fill: rgba(120,120,128,.12);
  --accent: #2FA38A;       /* Nutrio calm green-teal */
  --protein: #3B82F6;  --carbs: #F59E0B;  --fat: #A855F7;  --kcal: var(--accent);
  --danger: #FF453A;  --success: #30D158;
  --radius-card: 20px; --radius-control: 12px; --radius-sheet: 28px;
  --shadow-card: 0 1px 2px rgba(0,0,0,.04), 0 8px 24px rgba(0,0,0,.06);
  --blur: saturate(180%) blur(20px);
}
@media (prefers-color-scheme: dark) {
  :root { --bg:#000; --bg-elevated:#1C1C1E; --bg-grouped:#1C1C1E; --label:#fff;
          --label-2: rgba(235,235,245,.60); --label-3: rgba(235,235,245,.30);
          --separator: rgba(84,84,88,.55); --fill: rgba(120,120,128,.24);
          --shadow-card: none; }
}
```

**Typography:** `font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", system-ui, sans-serif;` (Inter loaded as the non-Apple fallback). Scale: Large Title 34/41 bold · Title 28/34 · Title 2 22/28 semibold · Headline 17/22 semibold · Body 17/22 · Callout 16 · Subhead 15 · Footnote 13 · Caption 12. Use tabular numerals (`font-variant-numeric: tabular-nums`) for all macros and weights. Generous line height, sentence case everywhere.

**Spacing:** 4-pt grid; page padding 16–20 px; cards 16–20 px inner padding; 44 × 44 px minimum touch targets; respect `env(safe-area-inset-*)`.

**Surfaces & depth:** grouped inset lists (like iOS Settings) on `--bg`; cards on `--bg-elevated` with soft shadows (light) or tonal elevation (dark); translucent **frosted nav/tab bars** using `backdrop-filter: var(--blur)` with a hairline separator; bottom sheets with a grabber, 28 px top radius and a dimmed, blurred backdrop.

**Motion:** spring physics (Framer Motion, ~`stiffness 320, damping 30`), 200–350 ms, interruptible. Rings and bars animate on load and on value change; numbers count smoothly; list items slide and fade on insert/remove; sheets follow the finger when dragged. Honor `prefers-reduced-motion` (swap springs for fades). No bouncy gimmicks, no confetti. Success feedback is a subtle check animation.

**Iconography:** Lucide at 1.5 px stroke, consistent 20–24 px sizes. **Charts:** minimal, thin lines, no gridline clutter, soft area gradients, interactive scrubbing with a floating value label, consistent macro colors.

**Accessibility:** WCAG AA contrast, visible focus rings, full keyboard navigation, ARIA on sheets/menus, Dynamic-Type-like scaling with `rem`, labels for charts (data table fallback), never rely on color alone for macros (add letter/label).

**Microcopy (calm):** "Nothing logged yet. Whenever you're ready." · "That's a little over today, no worries." · "Want me to find a lighter version?" · Never: "You failed", "Cheat meal", "Burn it off".

### 11.2 Navigation
- **Mobile:** bottom **tab bar** (frosted): **Today · Diary · Nutrio · Favorites · Plans**. Nutrio is the center tab with a soft glowing orb icon. Large collapsing titles at the top of each screen; swipe-back gesture; sheets for add/edit flows.
- **Desktop/tablet:** collapsible sidebar with the same five items, content column max ~1100 px, chat as a right-hand panel on wide screens.
- **Progress** lives inside Today as a segmented control (**Today | Progress**), and Settings/Profile opens from the avatar in the top corner.

### 11.3 Screens

1. **Onboarding (4 gentle steps, one question per screen):** welcome → about you (sex, birth date, height, weight) → activity & goal → review the suggested targets (calories and macros from `/goals/suggest`, editable) → allergies/preferences → optional "meet Nutrio". Progress dots, large type, big primary button.
2. **Today:** greeting by time of day; **Activity-ring-style macro rings** (calories large; protein/carbs/fat smaller) with remaining numbers; "Today's meals" grouped list with quick add; one soft **Nutrio suggestion card** (e.g. lighter version of a favorite, or a calorie-target nudge); water/steps are out of scope for v1. *Progress segment:* weight chart (with 7-day average and goal), measurements, adherence, workout volume.
3. **Diary:** horizontal week strip, date picker sheet; sections per meal with totals; swipe actions (copy, delete); sticky summary; **Add food sheet** with tabs *Search · Scan · Recent · Favorites · Templates*, instant results, brand/Nutri-Score chips, data-quality notice, quantity step with unit picker and live macro preview.
4. **Food detail sheet:** big serving stepper, unit selector, macro ring preview, "Add to Favorites", "Correct values", source attribution.
5. **Nutrio (chat):** iMessage-like but calmer: soft bubbles, streaming text, subtle tool-progress chips, **draft cards** inline (recipe, plan, variants, shopping list) with Approve / Edit / Discard; suggestion chips above the keyboard; thread list in a sheet.
6. **Favorites:** card grid or list toggle; each favorite shows its best accepted variant badge; detail screen with **variants carousel** and the **side-by-side comparison** (section 9); "Find lighter versions" button with variant-type chips (Higher protein, Lighter, Lower carb ...).
7. **Plans:** segmented **Meals · Workouts · Recipes · Shopping**. Meal plan = week view with day cards; workout plan = day cards with exercises (sets × reps); recipes with macro summary; shopping list grouped by aisle with check animation. Drafts shown with a clear "Draft from Nutrio" ribbon and Approve/Discard.
8. **Workout logger:** full-screen sheet, large numeric steppers, previous-session ghost values, rest timer.
9. **Settings (grouped inset list):** profile, goals & history, units, appearance (system/light/dark), agent preferences (verbosity, proactivity), pantry, data export, about & attributions (Open Food Facts), sign out.

**States everywhere:** skeleton loaders (no spinners on first paint), friendly empty states with one clear action, inline error banners with retry, optimistic updates with rollback.

---

## 12. Security & privacy

Argon2id password hashing, session tokens 256-bit random (hash stored), cookie `httpOnly; Secure; SameSite=Lax`, CSRF protection for state-changing requests, strict CORS, rate limits on auth and chat, input size limits, parameterized queries only, per-user row scoping with tests, secrets via env, structured logs without PII or food-diary contents, prompt-injection hygiene: **treat web content and OFF text as untrusted data, never as instructions** (strip/mark it in tool results; tools can't be triggered by text found on pages). Provide account deletion (cascade) and data export.

---

## 13. Testing & quality bar

- **Unit:** every function in `nutrition.py`; Pydantic validators (valid and invalid cases).
- **Integration (real Postgres via testcontainers):** each router happy path + auth/ownership + constraint failures; goal period overlap; snapshot immutability; timezone `log_date` edge cases.
- **Agent:** mocked-model tests for tool wiring, caps, draft-only behavior, allergy rejection, variant verification loop.
- **E2E (Playwright):** onboarding → log food by search → barcode manual entry → ask Nutrio for a plan → approve draft → see it in Plans → favorites variant flow → shopping list.
- **Frontend:** type-check strict, ESLint, axe accessibility checks on key screens, a test that fails if `localStorage`/`sessionStorage`/`indexedDB` is referenced in `web/`.
- CI: lint, type-check, tests, migration check.

---

## 14. Milestones (stop after each and wait for my go-ahead)

1. **Foundation:** repo, Docker Compose, Postgres + migrations from the contract files, seed, FastAPI skeleton, config/env, auth (sessions), `/auth/*`, `/reference/*`, row-scoping test harness. *Done when:* I can register, log in, and fetch reference data from the DB.
2. **Profile, body & goals:** profile, onboarding API, measurements + series, goals (safety rules enforced), `/goals/suggest`. Frontend shell with design tokens, tab bar, onboarding and Today (rings, empty states) + Progress weight chart. *Done when:* I can onboard, log weight, and see targets and a chart.
3. **Foods & diary:** OFF client + cache + quality gate, search/barcode, manual foods and corrections, diary CRUD, templates, copy-day, daily totals. Add-food sheet, Diary and Food detail screens. *Done when:* I can log a day of food in under a minute and see accurate rings.
4. **Recipes, favorites (manual) & plans (manual):** CRUD and approval flow, `recipe_nutrition`, favorites list UI. *Done when:* everything the agent will later create can already be created by hand.
5. **Agent v1 (read-only + web):** chat SSE, runs/tool-call logging, context injection, read tools, Tavily, persona from `agent_prompts`, guardrails. *Done when:* Nutrio answers using my real data and cites sources.
6. **Agent v2 (drafts):** `propose_*` tools, draft cards with approve/edit/discard, safety enforcement, evals. **Favorites → variants flow** (section 9) end to end with verification and feedback loop.
7. **Workouts:** library, plans, logger, progression charts, agent workout plans.
8. **Shopping, pantry, adaptive targets, proactive suggestions, export, polish:** performance, accessibility pass, PWA manifest, final E2E suite.

---

## 15. Environment variables (`.env.example`)

`DATABASE_URL`, `SESSION_SECRET`, `COOKIE_DOMAIN`, `ALLOWED_ORIGINS`, `AGENT_MODEL`, `AGENT_API_KEY`, `TAVILY_API_KEY`, `OFF_USER_AGENT`, `OFF_BASE_URL`, `LOG_LEVEL`.

---

## 16. Definition of done (every milestone)

Tests green · types strict · migrations apply cleanly on an empty DB · no hardcoded domain data · no browser storage · every new table/column reflected in Pydantic and the OpenAPI client · short note in `DECISIONS.md` · a 5-line "how to verify manually" for me.

**Start with Milestone 1. Before writing code, reply with a short plan, your assumptions, and any questions.**
