-- =====================================================================
-- Nutrio — reference & configuration data
-- Everything here is editable at runtime. The app reads it from the DB;
-- code only ever refers to rows by their stable `code`.
-- =====================================================================
BEGIN;

INSERT INTO meal_types (code, label, sort_order) VALUES
  ('breakfast',    'Breakfast',    10),
  ('lunch',        'Lunch',        20),
  ('dinner',       'Dinner',       30),
  ('snack',        'Snack',        40),
  ('pre_workout',  'Pre-workout',  50),
  ('post_workout', 'Post-workout', 60);

INSERT INTO units (code, label, kind, grams_per_unit, sort_order) VALUES
  ('g',       'g',        'mass',   1,        10),
  ('kg',      'kg',       'mass',   1000,     20),
  ('oz',      'oz',       'mass',   28.3495,  30),
  ('lb',      'lb',       'mass',   453.592,  40),
  ('ml',      'ml',       'volume', NULL,     50),
  ('l',       'l',        'volume', NULL,     60),
  ('cup',     'cup',      'volume', NULL,     70),
  ('tbsp',    'tbsp',     'volume', NULL,     80),
  ('tsp',     'tsp',      'volume', NULL,     90),
  ('piece',   'piece',    'count',  NULL,    100),
  ('slice',   'slice',    'count',  NULL,    110),
  ('serving', 'serving',  'count',  NULL,    120);

INSERT INTO activity_levels (code, label, description, multiplier, sort_order) VALUES
  ('sedentary',   'Sedentary',         'Little or no exercise, desk job',            1.200, 10),
  ('light',       'Lightly active',    'Light exercise 1–3 days/week',               1.375, 20),
  ('moderate',    'Moderately active', 'Moderate exercise 3–5 days/week',            1.550, 30),
  ('very_active', 'Very active',       'Hard exercise 6–7 days/week',                1.725, 40),
  ('athlete',     'Extremely active',  'Physical job plus hard training / 2x daily', 1.900, 50);

INSERT INTO goal_types (code, label, description, sort_order) VALUES
  ('lose_fat',     'Lose fat',        'Gentle calorie deficit while keeping muscle', 10),
  ('maintain',     'Maintain',        'Stay at the current weight',                  20),
  ('gain_muscle',  'Build muscle',    'Small calorie surplus with high protein',     30),
  ('recomposition','Recomposition',   'Lose fat and build muscle at maintenance',    40);

-- rule: expected change of the variant vs. the original, per serving.
INSERT INTO variant_types (code, label, description, rule, sort_order) VALUES
  ('high_protein', 'Higher protein',  'More protein per serving',
     '{"protein_g": {"min_delta_pct": 20}}', 10),
  ('low_calorie',  'Lighter',         'Fewer calories per serving',
     '{"kcal": {"max_delta_pct": -20}}', 20),
  ('low_carb',     'Lower carb',      'Fewer carbohydrates',
     '{"carbs_g": {"max_delta_pct": -30}}', 30),
  ('low_fat',      'Lower fat',       'Less fat per serving',
     '{"fat_g": {"max_delta_pct": -30}}', 40),
  ('balanced_swap','Smarter swap',     'Better protein-to-calorie ratio overall',
     '{"protein_g": {"min_delta_pct": 10}, "kcal": {"max_delta_pct": -10}}', 50),
  ('vegetarian',   'Vegetarian',      'No meat or fish',          '{}', 60),
  ('vegan',        'Vegan',           'No animal products',       '{}', 70),
  ('gluten_free',  'Gluten-free',     'No gluten ingredients',    '{}', 80),
  ('dairy_free',   'Dairy-free',      'No dairy ingredients',     '{}', 90);

INSERT INTO store_aisles (code, label, sort_order) VALUES
  ('produce',  'Produce',          10),
  ('meat_fish','Meat & fish',      20),
  ('dairy',    'Dairy & eggs',     30),
  ('bakery',   'Bakery',           40),
  ('pantry',   'Pantry',           50),
  ('frozen',   'Frozen',           60),
  ('drinks',   'Drinks',           70),
  ('snacks',   'Snacks',           80),
  ('other',    'Other',            90);

INSERT INTO muscle_groups (code, label, sort_order) VALUES
  ('chest','Chest',10), ('back','Back',20), ('shoulders','Shoulders',30),
  ('biceps','Biceps',40), ('triceps','Triceps',50), ('forearms','Forearms',60),
  ('quads','Quads',70), ('hamstrings','Hamstrings',80), ('glutes','Glutes',90),
  ('calves','Calves',100), ('core','Core',110), ('full_body','Full body',120);

INSERT INTO equipment (code, label, sort_order) VALUES
  ('barbell','Barbell',10), ('dumbbell','Dumbbell',20), ('machine','Machine',30),
  ('cable','Cable',40), ('kettlebell','Kettlebell',50), ('band','Resistance band',60),
  ('bodyweight','Bodyweight',70), ('none','No equipment',80);

-- Tunable behaviour (read at runtime, never hardcoded)
INSERT INTO app_settings (key, value, description) VALUES
  ('food.energy_tolerance_pct',        '25',   'Max % gap between listed kcal and 4P+4C+9F before a food is flagged suspect'),
  ('food.macro_sum_max_per_100g',      '100.5','Max grams of protein+carbs+fat per 100 g'),
  ('food.cache_refresh_days',          '30',   'Re-fetch cached Open Food Facts items older than this'),
  ('agent.max_tool_calls_per_run',     '14',   'Safety cap on tool calls in one agent run'),
  ('agent.max_variants_per_favorite',  '3',    'Variants proposed per favorite per request'),
  ('agent.max_web_searches_per_run',   '5',    'Cap on Tavily searches per run'),
  ('adaptive_goal.min_weight_entries', '5',    'Weigh-ins required before suggesting a calorie change'),
  ('adaptive_goal.window_days',        '21',   'Trend window for adaptive goals'),
  ('adaptive_goal.step_kcal',          '100',  'Calorie adjustment step for adaptive goals'),
  ('adaptive_goal.kcal_per_kg',        '7700', 'Approximate kcal per kg of body weight change'),
  ('adaptive_goal.lose_stall_pct',     '0.1',  'Fat loss: below this weekly % loss counts as stalled'),
  ('adaptive_goal.gain_stall_pct',     '0.05', 'Muscle gain: below this weekly % gain counts as stalled'),
  ('adaptive_goal.gain_fast_pct',      '0.5',  'Muscle gain: above this weekly % gain counts as too fast'),
  ('adaptive_goal.maintain_drift_pct', '0.25', 'Maintenance: weekly % drift that triggers a nudge'),
  ('ui.default_meal_type_by_hour',
     '{"5":"breakfast","11":"lunch","15":"snack","18":"dinner","22":"snack"}',
     'Which meal is preselected by local hour (hour the range starts → meal code)');

-- Safety guardrails. These are conservative placeholders: review them.
INSERT INTO safety_rules (key, value, description) VALUES
  ('min_daily_kcal.female',  '1200', 'Never propose or save a daily target below this (kcal)'),
  ('min_daily_kcal.male',    '1500', 'Never propose or save a daily target below this (kcal)'),
  ('min_daily_kcal.other',   '1350', 'Never propose or save a daily target below this (kcal)'),
  ('max_weekly_loss_pct',    '1.0',  'Max suggested weight loss per week, % of body weight'),
  ('min_protein_g_per_kg',   '0.8',  'Lower bound for protein targets'),
  ('max_deficit_pct',        '25',   'Max calorie deficit vs. estimated maintenance'),
  ('min_age_years',          '18',   'Plans are only generated for adults'),
  ('refer_out_topics',
     '["eating disorder","pregnan","breastfeeding","diabetes","kidney","heart condition","medication","under 18"]',
     'Topics where Nutrio stays gentle and suggests a qualified professional');

-- Nutrio persona (versioned; edit by inserting a new version and flipping is_active)
INSERT INTO agent_prompts (name, version, is_active, notes, content) VALUES
('nutrio', 1, true, 'Initial calm persona', $prompt$
You are Nutrio, a calm, gentle nutrition and fitness companion inside the user's personal app. You are an agent, not just a chat bot: you can read the user's data and, with their approval, create meal plans, recipes, workout plans and shopping lists directly in their app.

# Personality
- Relaxed, warm, unhurried. A quiet friend who knows nutrition, never a drill sergeant.
- Short replies by default (2–5 sentences). Go deeper only when asked.
- Never shame, guilt or pressure. A skipped log, a high-calorie day or a missed workout is just data.
- Offer ONE suggestion at a time, phrased as an option ("Want me to…?"), never as an order.
- Celebrate small wins quietly. No exclamation-mark overload, no emoji spam.
- Be honest: if you lack data, or a food's numbers look off, say so plainly.

# How you work
1. Ground every answer in the user's real data: use the read tools (profile, goals, today's totals, favorites, logs) before advising.
2. NEVER do nutrition arithmetic yourself. Calories, macros, recipe totals and variant comparisons come from tools. You choose ingredients and quantities; the system computes the numbers.
3. Everything you create is saved as a DRAFT. Tell the user it is ready to review, and let them approve, edit or discard it in the app. Only log food directly when the user explicitly asks you to log it.
4. Find foods with the food search tool (Open Food Facts) and use the returned food ids. Never invent a food id or a nutrition value.
5. Use web search for recipe and plan ideas. Adapt what you find instead of copying it, and keep the source link so the user can see where it came from.
6. Respect allergies, dietary preferences and disliked foods from the profile. Always.

# Favorites (your signature move)
The user keeps a list of favorite foods. When they mention a craving, or ask for ideas, look at that list first.
- Recreation: rebuild the same dish in a lighter or higher-protein form that still feels like the original.
- Alternative: a different food that satisfies the same craving.
Propose at most a few variants, each with a short reason it works, then let the system show the side-by-side macro comparison. Learn from the user's feedback on past variants (what they liked or rejected) and don't repeat rejected ideas.

# Safety
- Never suggest extreme restriction, fasting for weight loss, purging, or calorie targets below the limits provided by the system.
- If the user mentions an eating disorder, pregnancy, a medical condition, medication, or being under 18, respond with care, keep suggestions general, and encourage them to talk to a qualified professional.
- You are not a doctor. Do not diagnose or give medical advice.

# Style
Plain language. Metric units unless the user prefers otherwise. Use the user's name sparingly.
$prompt$);

COMMIT;
