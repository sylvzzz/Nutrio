-- =====================================================================
-- Nutrio — PostgreSQL 16+ schema
-- Apply:  psql -v ON_ERROR_STOP=1 -f schema.sql && psql -f seed.sql
-- (In the real project, split this into Alembic migrations.)
--
-- Principles
--  * Everything lives in PostgreSQL. Reference data and config are TABLES
--    (see seed.sql), never constants in code.
--  * Logged food/macros are SNAPSHOTS: history never changes when a food's
--    source data changes.
--  * Body measurements and goals are append-only history.
--  * Agent-created content starts as 'draft' and needs user approval.
-- =====================================================================

BEGIN;

-- gen_random_uuid() is built into PostgreSQL 13+, no pgcrypto needed.
CREATE EXTENSION IF NOT EXISTS citext;      -- case-insensitive email
CREATE EXTENSION IF NOT EXISTS pg_trgm;     -- fuzzy food search
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- non-overlapping goal periods

-- ---------------------------------------------------------------------
-- Enums (state machines only; domain data lives in reference tables)
-- ---------------------------------------------------------------------
CREATE TYPE sex_t              AS ENUM ('female', 'male', 'other');
CREATE TYPE content_status_t   AS ENUM ('draft', 'active', 'archived', 'rejected');
CREATE TYPE created_by_t       AS ENUM ('user', 'agent', 'system');
CREATE TYPE food_source_t      AS ENUM ('open_food_facts', 'manual');
CREATE TYPE log_source_t       AS ENUM ('manual', 'search', 'barcode', 'template', 'copy', 'agent');
CREATE TYPE variant_mode_t     AS ENUM ('recreation', 'alternative');
CREATE TYPE variant_status_t   AS ENUM ('draft', 'accepted', 'rejected', 'archived');
CREATE TYPE favorite_freq_t    AS ENUM ('daily', 'weekly', 'monthly', 'occasional');
CREATE TYPE message_role_t     AS ENUM ('user', 'assistant', 'tool', 'system');
CREATE TYPE run_status_t       AS ENUM ('running', 'succeeded', 'failed', 'cancelled');
CREATE TYPE verbosity_t        AS ENUM ('concise', 'balanced', 'detailed');
CREATE TYPE proactivity_t      AS ENUM ('off', 'low', 'medium');

-- ---------------------------------------------------------------------
-- Reference & configuration tables (seeded by seed.sql, editable at runtime)
-- ---------------------------------------------------------------------
CREATE TABLE app_settings (
  key         text PRIMARY KEY,
  value       jsonb NOT NULL,
  description text,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE safety_rules (
  key         text PRIMARY KEY,
  value       jsonb NOT NULL,
  description text,
  is_active   boolean NOT NULL DEFAULT true,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE agent_prompts (
  id         smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name       text NOT NULL,
  version    int  NOT NULL,
  content    text NOT NULL,
  notes      text,
  is_active  boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (name, version)
);
CREATE UNIQUE INDEX ux_agent_prompts_one_active ON agent_prompts (name) WHERE is_active;

CREATE TABLE meal_types (
  id smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code text NOT NULL UNIQUE, label text NOT NULL, sort_order smallint NOT NULL DEFAULT 0
);

CREATE TABLE units (
  id smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code text NOT NULL UNIQUE, label text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('mass', 'volume', 'count')),
  grams_per_unit numeric(10,4) CHECK (grams_per_unit > 0),  -- only for mass units
  sort_order smallint NOT NULL DEFAULT 0
);

CREATE TABLE activity_levels (
  id smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code text NOT NULL UNIQUE, label text NOT NULL, description text,
  multiplier numeric(4,3) NOT NULL CHECK (multiplier BETWEEN 1.0 AND 2.5),
  sort_order smallint NOT NULL DEFAULT 0
);

CREATE TABLE goal_types (
  id smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code text NOT NULL UNIQUE, label text NOT NULL, description text,
  sort_order smallint NOT NULL DEFAULT 0
);

-- 'rule' = machine-checkable macro expectations, e.g.
--   {"protein_g": {"min_delta_pct": 20}, "kcal": {"max_delta_pct": 0}}
CREATE TABLE variant_types (
  id smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code text NOT NULL UNIQUE, label text NOT NULL, description text,
  rule jsonb NOT NULL DEFAULT '{}'::jsonb,
  sort_order smallint NOT NULL DEFAULT 0
);

CREATE TABLE store_aisles (
  id smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code text NOT NULL UNIQUE, label text NOT NULL, sort_order smallint NOT NULL DEFAULT 0
);

CREATE TABLE muscle_groups (
  id smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code text NOT NULL UNIQUE, label text NOT NULL, sort_order smallint NOT NULL DEFAULT 0
);

CREATE TABLE equipment (
  id smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code text NOT NULL UNIQUE, label text NOT NULL, sort_order smallint NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------------
-- Users, sessions, profile, preferences
-- ---------------------------------------------------------------------
CREATE TABLE users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email         citext NOT NULL UNIQUE,
  password_hash text NOT NULL,
  display_name  text NOT NULL,
  language      text NOT NULL DEFAULT 'en',
  timezone      text NOT NULL DEFAULT 'UTC',
  unit_system   text NOT NULL DEFAULT 'metric' CHECK (unit_system IN ('metric', 'imperial')),
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- Server-side sessions. The browser only holds an httpOnly cookie with the
-- random token; we store its hash. No localStorage / sessionStorage anywhere.
CREATE TABLE sessions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash   bytea NOT NULL UNIQUE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  revoked_at   timestamptz,
  user_agent   text,
  ip           inet
);
CREATE INDEX ix_sessions_user ON sessions (user_id);

CREATE TABLE profiles (
  user_id             uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  sex                 sex_t,
  date_of_birth       date CHECK (date_of_birth > DATE '1900-01-01'),
  allergies           text[] NOT NULL DEFAULT '{}',
  dietary_preferences text[] NOT NULL DEFAULT '{}',   -- e.g. vegetarian, halal
  disliked_foods      text[] NOT NULL DEFAULT '{}',
  health_notes        text,                           -- injuries, conditions (user-provided)
  onboarding_done     boolean NOT NULL DEFAULT false,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE user_agent_preferences (
  user_id      uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  tone         text NOT NULL DEFAULT 'calm',
  verbosity    verbosity_t NOT NULL DEFAULT 'concise',
  proactivity  proactivity_t NOT NULL DEFAULT 'low',
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Body measurements (append-only history; never UPDATE, void instead)
-- ---------------------------------------------------------------------
CREATE TABLE body_measurements (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  measured_at    timestamptz NOT NULL DEFAULT now(),
  weight_kg      numeric(5,2) CHECK (weight_kg      BETWEEN 20 AND 500),
  height_cm      numeric(5,1) CHECK (height_cm      BETWEEN 50 AND 280),
  body_fat_pct   numeric(4,1) CHECK (body_fat_pct   BETWEEN 2 AND 70),
  muscle_mass_kg numeric(5,2) CHECK (muscle_mass_kg BETWEEN 5 AND 200),
  waist_cm       numeric(5,1) CHECK (waist_cm       BETWEEN 30 AND 250),
  hip_cm         numeric(5,1) CHECK (hip_cm         BETWEEN 30 AND 250),
  chest_cm       numeric(5,1) CHECK (chest_cm       BETWEEN 30 AND 250),
  arm_cm         numeric(5,1) CHECK (arm_cm         BETWEEN 10 AND 100),
  thigh_cm       numeric(5,1) CHECK (thigh_cm       BETWEEN 20 AND 150),
  neck_cm        numeric(5,1) CHECK (neck_cm        BETWEEN 20 AND 80),
  resting_hr     smallint     CHECK (resting_hr     BETWEEN 25 AND 220),
  notes          text,
  source         text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'agent', 'import')),
  voided_at      timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(weight_kg, height_cm, body_fat_pct, muscle_mass_kg, waist_cm,
                      hip_cm, chest_cm, arm_cm, thigh_cm, neck_cm, resting_hr) > 0)
);
CREATE INDEX ix_body_user_time ON body_measurements (user_id, measured_at DESC);

-- ---------------------------------------------------------------------
-- Chat threads & agent runs (audit trail of everything the agent does)
-- ---------------------------------------------------------------------
CREATE TABLE chat_threads (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title       text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  archived_at timestamptz
);
CREATE INDEX ix_threads_user ON chat_threads (user_id, updated_at DESC);

CREATE TABLE agent_runs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  thread_id     uuid REFERENCES chat_threads(id) ON DELETE SET NULL,
  prompt_id     smallint REFERENCES agent_prompts(id),
  model         text NOT NULL,
  trigger_kind  text NOT NULL DEFAULT 'chat'
                CHECK (trigger_kind IN ('chat', 'favorite_variants', 'weekly_review', 'scheduled')),
  status        run_status_t NOT NULL DEFAULT 'running',
  started_at    timestamptz NOT NULL DEFAULT now(),
  finished_at   timestamptz,
  error         text,
  input_tokens  int,
  output_tokens int
);
CREATE INDEX ix_runs_user ON agent_runs (user_id, started_at DESC);

CREATE TABLE chat_messages (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  thread_id    uuid NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
  run_id       uuid REFERENCES agent_runs(id) ON DELETE SET NULL,
  role         message_role_t NOT NULL,
  content      text,
  content_json jsonb,           -- structured parts: tool calls, draft cards, etc.
  created_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (content IS NOT NULL OR content_json IS NOT NULL)
);
CREATE INDEX ix_messages_thread ON chat_messages (thread_id, id);

CREATE TABLE agent_tool_calls (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id      uuid NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
  tool_name   text NOT NULL,
  arguments   jsonb NOT NULL DEFAULT '{}'::jsonb,
  result      jsonb,
  is_error    boolean NOT NULL DEFAULT false,
  duration_ms int,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_toolcalls_run ON agent_tool_calls (run_id);

-- ---------------------------------------------------------------------
-- Goals (history of targets; periods never overlap per user)
-- ---------------------------------------------------------------------
CREATE TABLE goals (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  goal_type_id       smallint NOT NULL REFERENCES goal_types(id),
  activity_level_id  smallint NOT NULL REFERENCES activity_levels(id),
  target_weight_kg   numeric(5,2) CHECK (target_weight_kg BETWEEN 20 AND 500),
  target_date        date,
  daily_kcal         numeric(7,2) NOT NULL CHECK (daily_kcal BETWEEN 500 AND 10000),
  protein_g          numeric(6,1) NOT NULL CHECK (protein_g >= 0),
  carbs_g            numeric(6,1) NOT NULL CHECK (carbs_g   >= 0),
  fat_g              numeric(6,1) NOT NULL CHECK (fat_g     >= 0),
  fiber_g            numeric(6,1) CHECK (fiber_g >= 0),
  start_date         date NOT NULL,
  end_date           date,                      -- NULL = current goal
  source             text NOT NULL DEFAULT 'user' CHECK (source IN ('user', 'agent', 'adaptive')),
  agent_run_id       uuid REFERENCES agent_runs(id) ON DELETE SET NULL,
  notes              text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (end_date IS NULL OR end_date > start_date),
  EXCLUDE USING gist (user_id WITH =, daterange(start_date, end_date, '[)') WITH &&)
);

-- ---------------------------------------------------------------------
-- Foods (local cache of Open Food Facts + user-created/corrected foods)
-- ---------------------------------------------------------------------
CREATE TABLE foods (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source               food_source_t NOT NULL,
  external_id          text,                                   -- OFF barcode
  owner_user_id        uuid REFERENCES users(id) ON DELETE CASCADE,  -- NULL = global OFF cache
  derived_from_food_id uuid REFERENCES foods(id) ON DELETE SET NULL, -- user's corrected copy
  name                 text NOT NULL,
  names                jsonb NOT NULL DEFAULT '{}'::jsonb,     -- {"en": "...", "pt": "..."}
  brand                text,
  categories           text[] NOT NULL DEFAULT '{}',
  image_url            text,
  serving_g            numeric(8,2) CHECK (serving_g > 0),
  serving_label        text,
  kcal_100g            numeric(7,2) NOT NULL CHECK (kcal_100g BETWEEN 0 AND 950),
  protein_100g         numeric(6,2) NOT NULL CHECK (protein_100g BETWEEN 0 AND 100),
  carbs_100g           numeric(6,2) NOT NULL CHECK (carbs_100g   BETWEEN 0 AND 100),
  fat_100g             numeric(6,2) NOT NULL CHECK (fat_100g     BETWEEN 0 AND 100),
  fiber_100g           numeric(6,2) CHECK (fiber_100g         BETWEEN 0 AND 100),
  sugar_100g           numeric(6,2) CHECK (sugar_100g         BETWEEN 0 AND 100),
  saturated_fat_100g   numeric(6,2) CHECK (saturated_fat_100g BETWEEN 0 AND 100),
  salt_g_100g          numeric(6,2) CHECK (salt_g_100g        BETWEEN 0 AND 100),
  sodium_mg_100g       numeric(8,2) CHECK (sodium_mg_100g     >= 0),
  micronutrients       jsonb NOT NULL DEFAULT '{}'::jsonb,
  nutriscore_grade     char(1) CHECK (nutriscore_grade IN ('a','b','c','d','e')),
  nova_group           smallint CHECK (nova_group BETWEEN 1 AND 4),
  data_quality         text NOT NULL DEFAULT 'unchecked'
                       CHECK (data_quality IN ('unchecked', 'ok', 'suspect', 'user_verified')),
  quality_notes        text,
  off_last_modified    timestamptz,
  fetched_at           timestamptz,
  source_payload       jsonb,                                  -- raw OFF product, for debugging
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CHECK (protein_100g + carbs_100g + fat_100g <= 100.5),
  CHECK ((source = 'open_food_facts') = (external_id IS NOT NULL)),
  CHECK (source <> 'manual' OR owner_user_id IS NOT NULL)
);
CREATE UNIQUE INDEX ux_foods_off_global
  ON foods (external_id) WHERE source = 'open_food_facts' AND owner_user_id IS NULL;
CREATE INDEX ix_foods_owner       ON foods (owner_user_id);
CREATE INDEX ix_foods_name_trgm   ON foods USING gin (name gin_trgm_ops);
CREATE INDEX ix_foods_brand_trgm  ON foods USING gin (brand gin_trgm_ops);

-- Household measures per food: "1 banana = 118 g", "1 slice = 30 g"
CREATE TABLE food_units (
  food_id uuid NOT NULL REFERENCES foods(id) ON DELETE CASCADE,
  unit_id smallint NOT NULL REFERENCES units(id),
  grams   numeric(8,2) NOT NULL CHECK (grams > 0),
  PRIMARY KEY (food_id, unit_id)
);

-- Shared rule: a line is EITHER a food (grams) OR a recipe (servings).
CREATE FUNCTION chk_food_or_recipe(food uuid, recipe uuid, grams numeric, servings numeric)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT num_nonnulls(food, recipe) = 1
     AND (food   IS NULL OR (grams    IS NOT NULL AND grams    > 0 AND servings IS NULL))
     AND (recipe IS NULL OR (servings IS NOT NULL AND servings > 0 AND grams    IS NULL))
$$;

-- ---------------------------------------------------------------------
-- Recipes
-- ---------------------------------------------------------------------
CREATE TABLE recipes (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title                 text NOT NULL,
  description           text,
  servings              numeric(6,2) NOT NULL DEFAULT 1 CHECK (servings > 0),
  prep_minutes          smallint CHECK (prep_minutes >= 0),
  cook_minutes          smallint CHECK (cook_minutes >= 0),
  tags                  text[] NOT NULL DEFAULT '{}',
  cuisine               text,
  image_url             text,
  source_url            text,
  source_title          text,
  status                content_status_t NOT NULL DEFAULT 'active',
  created_by            created_by_t NOT NULL DEFAULT 'user',
  agent_run_id          uuid REFERENCES agent_runs(id) ON DELETE SET NULL,
  derived_from_recipe_id uuid REFERENCES recipes(id) ON DELETE SET NULL,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_recipes_user ON recipes (user_id, status);

CREATE TABLE recipe_ingredients (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipe_id        uuid NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  position         smallint NOT NULL,
  food_id          uuid NOT NULL REFERENCES foods(id) ON DELETE RESTRICT,
  quantity_g       numeric(8,2) NOT NULL CHECK (quantity_g > 0),
  display_quantity numeric(8,2),
  display_unit_id  smallint REFERENCES units(id),
  note             text,
  UNIQUE (recipe_id, position)
);

CREATE TABLE recipe_steps (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipe_id   uuid NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  position    smallint NOT NULL,
  instruction text NOT NULL,
  UNIQUE (recipe_id, position)
);

-- Recipe macros are DERIVED from ingredients (never typed by hand / by the LLM).
CREATE VIEW recipe_nutrition AS
SELECT r.id AS recipe_id, r.servings,
       SUM(ri.quantity_g / 100 * f.kcal_100g)                    AS total_kcal,
       SUM(ri.quantity_g / 100 * f.protein_100g)                 AS total_protein_g,
       SUM(ri.quantity_g / 100 * f.carbs_100g)                   AS total_carbs_g,
       SUM(ri.quantity_g / 100 * f.fat_100g)                     AS total_fat_g,
       SUM(ri.quantity_g / 100 * COALESCE(f.fiber_100g, 0))      AS total_fiber_g,
       SUM(ri.quantity_g / 100 * f.kcal_100g)    / r.servings    AS kcal_per_serving,
       SUM(ri.quantity_g / 100 * f.protein_100g) / r.servings    AS protein_g_per_serving,
       SUM(ri.quantity_g / 100 * f.carbs_100g)   / r.servings    AS carbs_g_per_serving,
       SUM(ri.quantity_g / 100 * f.fat_100g)     / r.servings    AS fat_g_per_serving,
       SUM(ri.quantity_g / 100 * COALESCE(f.fiber_100g, 0)) / r.servings AS fiber_g_per_serving
FROM recipes r
JOIN recipe_ingredients ri ON ri.recipe_id = r.id
JOIN foods f ON f.id = ri.food_id
GROUP BY r.id, r.servings;

-- ---------------------------------------------------------------------
-- Meal templates ("My usual breakfast" — log in one tap)
-- ---------------------------------------------------------------------
CREATE TABLE meal_templates (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name         text NOT NULL,
  meal_type_id smallint REFERENCES meal_types(id),
  created_by   created_by_t NOT NULL DEFAULT 'user',
  agent_run_id uuid REFERENCES agent_runs(id) ON DELETE SET NULL,
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE meal_template_items (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id uuid NOT NULL REFERENCES meal_templates(id) ON DELETE CASCADE,
  position    smallint NOT NULL,
  food_id     uuid REFERENCES foods(id)   ON DELETE RESTRICT,
  recipe_id   uuid REFERENCES recipes(id) ON DELETE RESTRICT,
  quantity_g  numeric(8,2),
  servings    numeric(6,2),
  UNIQUE (template_id, position),
  CHECK (chk_food_or_recipe(food_id, recipe_id, quantity_g, servings))
);

-- ---------------------------------------------------------------------
-- Food diary (snapshots: macros frozen at log time)
-- ---------------------------------------------------------------------
CREATE TABLE food_logs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  logged_at     timestamptz NOT NULL DEFAULT now(),
  log_date      date NOT NULL,                      -- the user's LOCAL calendar day
  meal_type_id  smallint NOT NULL REFERENCES meal_types(id),
  food_id       uuid REFERENCES foods(id)   ON DELETE RESTRICT,
  recipe_id     uuid REFERENCES recipes(id) ON DELETE RESTRICT,
  quantity_g    numeric(8,2),
  servings      numeric(6,2),
  name_snapshot text NOT NULL,
  kcal          numeric(8,2) NOT NULL CHECK (kcal >= 0),
  protein_g     numeric(7,2) NOT NULL CHECK (protein_g >= 0),
  carbs_g       numeric(7,2) NOT NULL CHECK (carbs_g   >= 0),
  fat_g         numeric(7,2) NOT NULL CHECK (fat_g     >= 0),
  fiber_g       numeric(7,2) CHECK (fiber_g >= 0),
  sugar_g       numeric(7,2) CHECK (sugar_g >= 0),
  sodium_mg     numeric(9,2) CHECK (sodium_mg >= 0),
  source        log_source_t NOT NULL DEFAULT 'manual',
  template_id   uuid REFERENCES meal_templates(id) ON DELETE SET NULL,
  agent_run_id  uuid REFERENCES agent_runs(id) ON DELETE SET NULL,
  notes         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (chk_food_or_recipe(food_id, recipe_id, quantity_g, servings))
);
CREATE INDEX ix_logs_user_date ON food_logs (user_id, log_date);
CREATE INDEX ix_logs_user_food ON food_logs (user_id, food_id);

-- ---------------------------------------------------------------------
-- Favorites + agent-generated variants  (core Nutrio feature)
-- ---------------------------------------------------------------------
CREATE TABLE favorite_foods (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  food_id       uuid REFERENCES foods(id)   ON DELETE RESTRICT,
  recipe_id     uuid REFERENCES recipes(id) ON DELETE RESTRICT,
  custom_name   text,                       -- e.g. "Mum's lasagna" (no food/recipe yet)
  category      text,                       -- comfort food, snack, dessert, ...
  why_i_like_it text,
  frequency     favorite_freq_t,
  tags          text[] NOT NULL DEFAULT '{}',
  notes         text,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(food_id, recipe_id, custom_name) >= 1)
);
CREATE UNIQUE INDEX ux_fav_user_food   ON favorite_foods (user_id, food_id)   WHERE food_id   IS NOT NULL AND is_active;
CREATE UNIQUE INDEX ux_fav_user_recipe ON favorite_foods (user_id, recipe_id) WHERE recipe_id IS NOT NULL AND is_active;

CREATE TABLE favorite_variants (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  favorite_id       uuid NOT NULL REFERENCES favorite_foods(id) ON DELETE CASCADE,
  user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  mode              variant_mode_t NOT NULL,        -- recreation = same dish improved; alternative = different food, same craving
  variant_type_id   smallint NOT NULL REFERENCES variant_types(id),
  title             text NOT NULL,
  rationale         text NOT NULL,
  variant_recipe_id uuid REFERENCES recipes(id) ON DELETE RESTRICT,
  variant_food_id   uuid REFERENCES foods(id)   ON DELETE RESTRICT,
  -- per-serving comparison, computed by code (never by the LLM)
  orig_kcal         numeric(7,2) NOT NULL, orig_protein_g numeric(6,1) NOT NULL,
  orig_carbs_g      numeric(6,1) NOT NULL, orig_fat_g     numeric(6,1) NOT NULL,
  var_kcal          numeric(7,2) NOT NULL, var_protein_g  numeric(6,1) NOT NULL,
  var_carbs_g       numeric(6,1) NOT NULL, var_fat_g      numeric(6,1) NOT NULL,
  sources           jsonb NOT NULL DEFAULT '[]'::jsonb,  -- [{"url": "...", "title": "..."}]
  status            variant_status_t NOT NULL DEFAULT 'draft',
  agent_run_id      uuid REFERENCES agent_runs(id) ON DELETE SET NULL,
  decided_at        timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(variant_recipe_id, variant_food_id) = 1)
);
CREATE INDEX ix_variants_fav ON favorite_variants (favorite_id, status);

CREATE TABLE variant_feedback (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  variant_id uuid NOT NULL REFERENCES favorite_variants(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  rating     smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
  reason     text,
  tags       text[] NOT NULL DEFAULT '{}',     -- too_sweet, hard_to_make, tastes_odd...
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Meal plans
-- ---------------------------------------------------------------------
CREATE TABLE meal_plans (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title        text NOT NULL,
  start_date   date NOT NULL,
  end_date     date NOT NULL,
  status       content_status_t NOT NULL DEFAULT 'draft',
  created_by   created_by_t NOT NULL DEFAULT 'user',
  agent_run_id uuid REFERENCES agent_runs(id) ON DELETE SET NULL,
  source_url   text,
  notes        text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (end_date >= start_date)
);

CREATE TABLE meal_plan_items (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id      uuid NOT NULL REFERENCES meal_plans(id) ON DELETE CASCADE,
  plan_date    date NOT NULL,
  meal_type_id smallint NOT NULL REFERENCES meal_types(id),
  position     smallint NOT NULL DEFAULT 0,
  food_id      uuid REFERENCES foods(id)   ON DELETE RESTRICT,
  recipe_id    uuid REFERENCES recipes(id) ON DELETE RESTRICT,
  quantity_g   numeric(8,2),
  servings     numeric(6,2),
  notes        text,
  CHECK (chk_food_or_recipe(food_id, recipe_id, quantity_g, servings))
);
CREATE INDEX ix_plan_items ON meal_plan_items (plan_id, plan_date);

-- ---------------------------------------------------------------------
-- Pantry & shopping lists
-- ---------------------------------------------------------------------
CREATE TABLE pantry_items (
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  food_id    uuid NOT NULL REFERENCES foods(id) ON DELETE CASCADE,
  quantity_g numeric(9,2) NOT NULL CHECK (quantity_g >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, food_id)
);

CREATE TABLE shopping_lists (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title        text NOT NULL,
  meal_plan_id uuid REFERENCES meal_plans(id) ON DELETE SET NULL,
  date_from    date,
  date_to      date,
  status       text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done')),
  created_by   created_by_t NOT NULL DEFAULT 'user',
  agent_run_id uuid REFERENCES agent_runs(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE shopping_list_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  list_id           uuid NOT NULL REFERENCES shopping_lists(id) ON DELETE CASCADE,
  food_id           uuid REFERENCES foods(id) ON DELETE SET NULL,
  name              text NOT NULL,
  quantity_g        numeric(9,2) NOT NULL CHECK (quantity_g > 0),
  pantry_deducted_g numeric(9,2) NOT NULL DEFAULT 0 CHECK (pantry_deducted_g >= 0),
  aisle_id          smallint REFERENCES store_aisles(id),
  is_checked        boolean NOT NULL DEFAULT false
);
CREATE INDEX ix_shop_items ON shopping_list_items (list_id);

-- ---------------------------------------------------------------------
-- Workouts: library, plans (what to do), logs (what you did)
-- ---------------------------------------------------------------------
CREATE TABLE exercises (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id         uuid REFERENCES users(id) ON DELETE CASCADE,   -- NULL = global library
  name                  text NOT NULL,
  description           text,
  instructions          text,
  video_url             text,
  primary_muscle_id     smallint REFERENCES muscle_groups(id),
  equipment_id          smallint REFERENCES equipment(id),
  is_compound           boolean NOT NULL DEFAULT false,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_exercises_name ON exercises (COALESCE(owner_user_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(name));

CREATE TABLE exercise_muscles (
  exercise_id uuid NOT NULL REFERENCES exercises(id) ON DELETE CASCADE,
  muscle_id   smallint NOT NULL REFERENCES muscle_groups(id),
  is_primary  boolean NOT NULL DEFAULT false,
  PRIMARY KEY (exercise_id, muscle_id)
);

CREATE TABLE workout_plans (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title          text NOT NULL,
  description    text,
  goal_type_id   smallint REFERENCES goal_types(id),
  weeks          smallint CHECK (weeks BETWEEN 1 AND 52),
  days_per_week  smallint CHECK (days_per_week BETWEEN 1 AND 7),
  status         content_status_t NOT NULL DEFAULT 'draft',
  created_by     created_by_t NOT NULL DEFAULT 'user',
  agent_run_id   uuid REFERENCES agent_runs(id) ON DELETE SET NULL,
  source_url     text,
  notes          text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE workout_plan_days (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id   uuid NOT NULL REFERENCES workout_plans(id) ON DELETE CASCADE,
  day_index smallint NOT NULL CHECK (day_index >= 1),
  name      text NOT NULL,                    -- "Push", "Legs", ...
  notes     text,
  UNIQUE (plan_id, day_index)
);

CREATE TABLE workout_plan_exercises (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  day_id           uuid NOT NULL REFERENCES workout_plan_days(id) ON DELETE CASCADE,
  position         smallint NOT NULL,
  exercise_id      uuid NOT NULL REFERENCES exercises(id) ON DELETE RESTRICT,
  sets             smallint NOT NULL CHECK (sets BETWEEN 1 AND 20),
  reps_min         smallint CHECK (reps_min >= 1),
  reps_max         smallint CHECK (reps_max >= 1),
  rest_seconds     smallint CHECK (rest_seconds >= 0),
  target_rpe       numeric(3,1) CHECK (target_rpe BETWEEN 1 AND 10),
  target_weight_kg numeric(6,2) CHECK (target_weight_kg >= 0),
  notes            text,
  UNIQUE (day_id, position),
  CHECK (reps_max IS NULL OR reps_min IS NULL OR reps_max >= reps_min)
);

CREATE TABLE workout_logs (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  plan_day_id      uuid REFERENCES workout_plan_days(id) ON DELETE SET NULL,
  name             text NOT NULL,
  performed_at     timestamptz NOT NULL DEFAULT now(),
  duration_minutes smallint CHECK (duration_minutes > 0),
  perceived_effort numeric(3,1) CHECK (perceived_effort BETWEEN 1 AND 10),
  notes            text,
  agent_run_id     uuid REFERENCES agent_runs(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_wlogs_user_time ON workout_logs (user_id, performed_at DESC);

CREATE TABLE workout_log_sets (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  log_id      uuid NOT NULL REFERENCES workout_logs(id) ON DELETE CASCADE,
  exercise_id uuid NOT NULL REFERENCES exercises(id) ON DELETE RESTRICT,
  set_number  smallint NOT NULL CHECK (set_number >= 1),
  reps        smallint CHECK (reps >= 0),
  weight_kg   numeric(6,2) CHECK (weight_kg >= 0),
  rpe         numeric(3,1) CHECK (rpe BETWEEN 1 AND 10),
  is_warmup   boolean NOT NULL DEFAULT false,
  notes       text
);
CREATE INDEX ix_wsets_exercise ON workout_log_sets (exercise_id, log_id);

-- ---------------------------------------------------------------------
-- Views for charts & dashboards
-- ---------------------------------------------------------------------
CREATE VIEW v_daily_totals AS
SELECT user_id, log_date,
       SUM(kcal)                    AS kcal,
       SUM(protein_g)               AS protein_g,
       SUM(carbs_g)                 AS carbs_g,
       SUM(fat_g)                   AS fat_g,
       SUM(COALESCE(fiber_g, 0))    AS fiber_g,
       COUNT(*)                     AS entries
FROM food_logs
GROUP BY user_id, log_date;

CREATE VIEW v_weight_series AS
SELECT user_id, measured_at, weight_kg,
       AVG(weight_kg) OVER (
         PARTITION BY user_id ORDER BY measured_at
         RANGE BETWEEN INTERVAL '6 days' PRECEDING AND CURRENT ROW
       ) AS weight_7d_avg
FROM body_measurements
WHERE weight_kg IS NOT NULL AND voided_at IS NULL;

CREATE VIEW v_current_body AS
SELECT u.id AS user_id,
  (SELECT m.weight_kg    FROM body_measurements m WHERE m.user_id = u.id AND m.weight_kg    IS NOT NULL AND m.voided_at IS NULL ORDER BY m.measured_at DESC LIMIT 1) AS weight_kg,
  (SELECT m.height_cm    FROM body_measurements m WHERE m.user_id = u.id AND m.height_cm    IS NOT NULL AND m.voided_at IS NULL ORDER BY m.measured_at DESC LIMIT 1) AS height_cm,
  (SELECT m.body_fat_pct FROM body_measurements m WHERE m.user_id = u.id AND m.body_fat_pct IS NOT NULL AND m.voided_at IS NULL ORDER BY m.measured_at DESC LIMIT 1) AS body_fat_pct
FROM users u;

-- ---------------------------------------------------------------------
-- updated_at triggers (every base table that has an updated_at column)
-- ---------------------------------------------------------------------
CREATE FUNCTION set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$;

DO $$
DECLARE t text;
BEGIN
  FOR t IN
    SELECT c.table_name
    FROM information_schema.columns c
    JOIN information_schema.tables tb
      ON tb.table_schema = c.table_schema AND tb.table_name = c.table_name
    WHERE c.table_schema = 'public' AND c.column_name = 'updated_at'
      AND tb.table_type = 'BASE TABLE'
  LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_%1$s_updated BEFORE UPDATE ON %1$I FOR EACH ROW EXECUTE FUNCTION set_updated_at()', t);
  END LOOP;
END $$;

COMMIT;
