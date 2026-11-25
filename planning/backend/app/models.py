"""Nutrio — Pydantic v2 models.

One source of truth for: API request/response bodies, agent tool inputs/outputs,
and validation of external data (Open Food Facts). Mirrors db/schema.sql.

Rules
  * Domain values (meal types, units, activity levels, variant types ...) are
    referenced by their stable `code` and validated against the DATABASE by the
    service layer, not by hardcoded Python enums.
  * Only true state machines are enums here (they mirror Postgres enums).
  * Agent output models use extra="forbid" so malformed output fails validation
    and the agent retries.

Dependencies: pydantic>=2.7, email-validator
"""
from __future__ import annotations

import re
from datetime import date, datetime, timedelta, timezone
from enum import StrEnum
from typing import Annotated, Any
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import (
    BaseModel,
    ConfigDict,
    EmailStr,
    Field,
    HttpUrl,
    field_validator,
    model_validator,
)

# --------------------------------------------------------------------------
# Base classes & constrained types
# --------------------------------------------------------------------------
class Base(BaseModel):
    """Inputs: strict, strip whitespace, reject unknown fields."""
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")


class ORMBase(BaseModel):
    """Outputs read from SQLAlchemy rows."""
    model_config = ConfigDict(from_attributes=True, extra="ignore")


Grams = Annotated[float, Field(gt=0, le=20_000)]
Servings = Annotated[float, Field(gt=0, le=1_000)]
Macro = Annotated[float, Field(ge=0, le=5_000)]
Kcal = Annotated[float, Field(ge=0, le=20_000)]
Code = Annotated[str, Field(min_length=1, max_length=64, pattern=r"^[a-z0-9_.]+$")]
ShortText = Annotated[str, Field(min_length=1, max_length=200)]
LongText = Annotated[str, Field(min_length=1, max_length=4_000)]


# --------------------------------------------------------------------------
# State-machine enums (mirror Postgres enums)
# --------------------------------------------------------------------------
class Sex(StrEnum):
    female = "female"
    male = "male"
    other = "other"


class ContentStatus(StrEnum):
    draft = "draft"
    active = "active"
    archived = "archived"
    rejected = "rejected"


class CreatedBy(StrEnum):
    user = "user"
    agent = "agent"
    system = "system"


class FoodSource(StrEnum):
    open_food_facts = "open_food_facts"
    manual = "manual"


class LogSource(StrEnum):
    manual = "manual"
    search = "search"
    barcode = "barcode"
    template = "template"
    copy = "copy"
    agent = "agent"


class VariantMode(StrEnum):
    recreation = "recreation"      # same dish, improved
    alternative = "alternative"    # different food, same craving


class VariantStatus(StrEnum):
    draft = "draft"
    accepted = "accepted"
    rejected = "rejected"
    archived = "archived"


class FavoriteFrequency(StrEnum):
    daily = "daily"
    weekly = "weekly"
    monthly = "monthly"
    occasional = "occasional"


class Verbosity(StrEnum):
    concise = "concise"
    balanced = "balanced"
    detailed = "detailed"


class Proactivity(StrEnum):
    off = "off"
    low = "low"
    medium = "medium"


# --------------------------------------------------------------------------
# Reference data (read from DB)
# --------------------------------------------------------------------------
class RefItem(ORMBase):
    id: int
    code: str
    label: str


class Unit(RefItem):
    kind: str
    grams_per_unit: float | None = None


class ActivityLevel(RefItem):
    multiplier: float


class VariantType(RefItem):
    description: str | None = None
    rule: dict[str, Any] = {}


# --------------------------------------------------------------------------
# Users, auth, profile
# --------------------------------------------------------------------------
def _valid_tz(v: str) -> str:
    try:
        ZoneInfo(v)
    except (ZoneInfoNotFoundError, ValueError) as e:
        raise ValueError(f"unknown timezone: {v}") from e
    return v


class UserCreate(Base):
    email: EmailStr
    password: str = Field(min_length=10, max_length=128)
    display_name: str = Field(min_length=1, max_length=80)
    language: str = Field(default="en", pattern=r"^[a-z]{2}(-[A-Z]{2})?$")
    timezone: str = "UTC"
    unit_system: str = Field(default="metric", pattern=r"^(metric|imperial)$")

    _tz = field_validator("timezone")(_valid_tz)


class UserLogin(Base):
    email: EmailStr
    password: str = Field(min_length=1, max_length=128)


class UserOut(ORMBase):
    id: UUID
    email: EmailStr
    display_name: str
    language: str
    timezone: str
    unit_system: str


class ProfileUpdate(Base):
    sex: Sex | None = None
    date_of_birth: date | None = None
    allergies: list[ShortText] | None = Field(default=None, max_length=50)
    dietary_preferences: list[ShortText] | None = Field(default=None, max_length=50)
    disliked_foods: list[ShortText] | None = Field(default=None, max_length=100)
    health_notes: str | None = Field(default=None, max_length=2_000)

    @field_validator("date_of_birth")
    @classmethod
    def _plausible_age(cls, v: date | None) -> date | None:
        if v is None:
            return v
        years = (date.today() - v).days / 365.25
        if not 13 <= years <= 120:
            raise ValueError("date_of_birth implies an age outside 13–120")
        return v


class ProfileOut(ORMBase):
    user_id: UUID
    sex: Sex | None
    date_of_birth: date | None
    allergies: list[str]
    dietary_preferences: list[str]
    disliked_foods: list[str]
    health_notes: str | None
    onboarding_done: bool


class AgentPreferences(Base):
    tone: str = Field(default="calm", max_length=40)
    verbosity: Verbosity = Verbosity.concise
    proactivity: Proactivity = Proactivity.low


# --------------------------------------------------------------------------
# Body measurements & goals
# --------------------------------------------------------------------------
class BodyMeasurementCreate(Base):
    measured_at: datetime | None = None            # default: now (server)
    weight_kg: float | None = Field(default=None, ge=20, le=500)
    height_cm: float | None = Field(default=None, ge=50, le=280)
    body_fat_pct: float | None = Field(default=None, ge=2, le=70)
    muscle_mass_kg: float | None = Field(default=None, ge=5, le=200)
    waist_cm: float | None = Field(default=None, ge=30, le=250)
    hip_cm: float | None = Field(default=None, ge=30, le=250)
    chest_cm: float | None = Field(default=None, ge=30, le=250)
    arm_cm: float | None = Field(default=None, ge=10, le=100)
    thigh_cm: float | None = Field(default=None, ge=20, le=150)
    neck_cm: float | None = Field(default=None, ge=20, le=80)
    resting_hr: int | None = Field(default=None, ge=25, le=220)
    notes: str | None = Field(default=None, max_length=500)

    @model_validator(mode="after")
    def _at_least_one_metric(self) -> "BodyMeasurementCreate":
        metrics = [self.weight_kg, self.height_cm, self.body_fat_pct, self.muscle_mass_kg,
                   self.waist_cm, self.hip_cm, self.chest_cm, self.arm_cm, self.thigh_cm,
                   self.neck_cm, self.resting_hr]
        if all(m is None for m in metrics):
            raise ValueError("provide at least one measurement")
        if self.measured_at is not None:
            ts = self.measured_at if self.measured_at.tzinfo else self.measured_at.replace(tzinfo=timezone.utc)
            if ts > datetime.now(timezone.utc) + timedelta(minutes=5):
                raise ValueError("measured_at cannot be in the future")
        return self


class BodyMeasurementOut(ORMBase):
    id: int
    measured_at: datetime
    weight_kg: float | None
    height_cm: float | None
    body_fat_pct: float | None
    muscle_mass_kg: float | None
    waist_cm: float | None
    hip_cm: float | None
    chest_cm: float | None
    arm_cm: float | None
    thigh_cm: float | None
    neck_cm: float | None
    resting_hr: int | None
    notes: str | None


class GoalCreate(Base):
    goal_type_code: Code
    activity_level_code: Code
    target_weight_kg: float | None = Field(default=None, ge=20, le=500)
    target_date: date | None = None
    daily_kcal: float = Field(ge=500, le=10_000)
    protein_g: float = Field(ge=0, le=1_000)
    carbs_g: float = Field(ge=0, le=2_000)
    fat_g: float = Field(ge=0, le=1_000)
    fiber_g: float | None = Field(default=None, ge=0, le=300)
    start_date: date
    notes: str | None = Field(default=None, max_length=500)

    @model_validator(mode="after")
    def _macros_match_calories(self) -> "GoalCreate":
        implied = 4 * self.protein_g + 4 * self.carbs_g + 9 * self.fat_g
        if abs(implied - self.daily_kcal) / self.daily_kcal > 0.10:
            raise ValueError(
                f"macros imply {implied:.0f} kcal but daily_kcal is {self.daily_kcal:.0f} (>10% apart)"
            )
        return self
    # NOTE: minimum-calorie / deficit limits come from the safety_rules table and
    # are enforced in the service layer (they need a DB read), for users AND agent.


class GoalOut(ORMBase):
    id: UUID
    goal_type_id: int
    activity_level_id: int
    target_weight_kg: float | None
    target_date: date | None
    daily_kcal: float
    protein_g: float
    carbs_g: float
    fat_g: float
    fiber_g: float | None
    start_date: date
    end_date: date | None
    source: str


# --------------------------------------------------------------------------
# Nutrition primitives
# --------------------------------------------------------------------------
class MacroSnapshot(Base):
    """Absolute amounts for a portion (what gets stored in food_logs)."""
    kcal: Kcal
    protein_g: Macro
    carbs_g: Macro
    fat_g: Macro
    fiber_g: Macro | None = None
    sugar_g: Macro | None = None
    sodium_mg: float | None = Field(default=None, ge=0)


class Nutrients100g(Base):
    kcal_100g: float = Field(ge=0, le=950)
    protein_100g: float = Field(ge=0, le=100)
    carbs_100g: float = Field(ge=0, le=100)
    fat_100g: float = Field(ge=0, le=100)
    fiber_100g: float | None = Field(default=None, ge=0, le=100)
    sugar_100g: float | None = Field(default=None, ge=0, le=100)
    saturated_fat_100g: float | None = Field(default=None, ge=0, le=100)
    salt_g_100g: float | None = Field(default=None, ge=0, le=100)
    sodium_mg_100g: float | None = Field(default=None, ge=0)

    @model_validator(mode="after")
    def _physical_sanity(self) -> "Nutrients100g":
        if self.protein_100g + self.carbs_100g + self.fat_100g > 100.5:
            raise ValueError("protein + carbs + fat exceeds 100 g per 100 g")
        if (self.sugar_100g or 0) > self.carbs_100g + 0.5:
            raise ValueError("sugars cannot exceed carbohydrates")
        if (self.saturated_fat_100g or 0) > self.fat_100g + 0.5:
            raise ValueError("saturated fat cannot exceed total fat")
        return self


# --------------------------------------------------------------------------
# Foods (Open Food Facts cache + manual)
# --------------------------------------------------------------------------
BARCODE_RE = re.compile(r"^\d{8,14}$")


class FoodUpsert(Nutrients100g):
    source: FoodSource
    external_id: str | None = None
    name: ShortText
    names: dict[str, str] = {}
    brand: str | None = Field(default=None, max_length=200)
    categories: list[str] = []
    image_url: HttpUrl | None = None
    serving_g: float | None = Field(default=None, gt=0, le=5_000)
    serving_label: str | None = Field(default=None, max_length=100)
    nutriscore_grade: str | None = Field(default=None, pattern=r"^[a-e]$")
    nova_group: int | None = Field(default=None, ge=1, le=4)
    off_last_modified: datetime | None = None
    micronutrients: dict[str, float] = {}

    @model_validator(mode="after")
    def _source_rules(self) -> "FoodUpsert":
        if self.source == FoodSource.open_food_facts:
            if not self.external_id or not BARCODE_RE.match(self.external_id):
                raise ValueError("Open Food Facts items need a numeric barcode (8–14 digits)")
        elif self.external_id is not None:
            raise ValueError("manual foods must not have an external_id")
        return self


class FoodOut(Nutrients100g, ORMBase):
    id: UUID
    source: FoodSource
    external_id: str | None
    name: str
    brand: str | None
    image_url: str | None
    serving_g: float | None
    serving_label: str | None
    data_quality: str
    quality_notes: str | None
    owner_user_id: UUID | None


class FoodSearchResult(Base):
    foods: list[FoodOut]
    from_cache: bool
    note: str | None = None


# --------------------------------------------------------------------------
# Food diary & templates
# --------------------------------------------------------------------------
class _FoodOrRecipeLine(Base):
    """A line is EITHER a food (grams) OR a recipe (servings)."""
    food_id: UUID | None = None
    recipe_id: UUID | None = None
    quantity_g: Grams | None = None
    servings: Servings | None = None

    @model_validator(mode="after")
    def _xor(self):
        if (self.food_id is None) == (self.recipe_id is None):
            raise ValueError("provide exactly one of food_id or recipe_id")
        if self.food_id is not None and (self.quantity_g is None or self.servings is not None):
            raise ValueError("a food line needs quantity_g (and no servings)")
        if self.recipe_id is not None and (self.servings is None or self.quantity_g is not None):
            raise ValueError("a recipe line needs servings (and no quantity_g)")
        return self


class FoodLogCreate(_FoodOrRecipeLine):
    meal_type_code: Code
    logged_at: datetime | None = None   # log_date is derived server-side from the user's timezone
    source: LogSource = LogSource.manual
    notes: str | None = Field(default=None, max_length=500)


class FoodLogOut(ORMBase, MacroSnapshot):
    id: UUID
    logged_at: datetime
    log_date: date
    meal_type_id: int
    food_id: UUID | None
    recipe_id: UUID | None
    quantity_g: float | None
    servings: float | None
    name_snapshot: str
    source: LogSource


class DailyTotals(ORMBase):
    log_date: date
    kcal: float
    protein_g: float
    carbs_g: float
    fat_g: float
    fiber_g: float
    entries: int


class MealTemplateCreate(Base):
    name: ShortText
    meal_type_code: Code | None = None
    items: list[_FoodOrRecipeLine] = Field(min_length=1, max_length=40)


# --------------------------------------------------------------------------
# Recipes (also the shape the agent must produce)
# --------------------------------------------------------------------------
class IngredientIn(Base):
    food_id: UUID                      # resolved via the food-search tool; never invented
    quantity_g: Grams
    display_quantity: float | None = Field(default=None, gt=0)
    display_unit_code: Code | None = None
    note: str | None = Field(default=None, max_length=200)


class SourceRef(Base):
    url: HttpUrl
    title: str | None = Field(default=None, max_length=300)


class RecipeDraft(Base):
    title: ShortText
    description: str | None = Field(default=None, max_length=1_000)
    servings: Servings = 1
    prep_minutes: int | None = Field(default=None, ge=0, le=1_440)
    cook_minutes: int | None = Field(default=None, ge=0, le=1_440)
    tags: list[Code] = Field(default=[], max_length=12)
    cuisine: str | None = Field(default=None, max_length=60)
    ingredients: list[IngredientIn] = Field(min_length=1, max_length=40)
    steps: list[Annotated[str, Field(min_length=3, max_length=1_000)]] = Field(min_length=1, max_length=30)
    source: SourceRef | None = None

    @model_validator(mode="after")
    def _no_duplicate_ingredients(self) -> "RecipeDraft":
        ids = [i.food_id for i in self.ingredients]
        if len(ids) != len(set(ids)):
            raise ValueError("duplicate ingredient: merge quantities into one line")
        return self


class RecipeNutrition(ORMBase):
    recipe_id: UUID
    servings: float
    kcal_per_serving: float
    protein_g_per_serving: float
    carbs_g_per_serving: float
    fat_g_per_serving: float
    fiber_g_per_serving: float


# --------------------------------------------------------------------------
# Favorites & variants  (Nutrio's signature feature)
# --------------------------------------------------------------------------
class FavoriteCreate(Base):
    food_id: UUID | None = None
    recipe_id: UUID | None = None
    custom_name: str | None = Field(default=None, max_length=120)
    category: str | None = Field(default=None, max_length=60)
    why_i_like_it: str | None = Field(default=None, max_length=500)
    frequency: FavoriteFrequency | None = None
    tags: list[Code] = Field(default=[], max_length=12)
    notes: str | None = Field(default=None, max_length=500)

    @model_validator(mode="after")
    def _something_to_favorite(self) -> "FavoriteCreate":
        if not (self.food_id or self.recipe_id or self.custom_name):
            raise ValueError("provide food_id, recipe_id or custom_name")
        return self


class VariantProposal(Base):
    """What the agent returns for ONE variant of a favorite."""
    mode: VariantMode
    variant_type_code: Code
    title: ShortText
    rationale: str = Field(min_length=10, max_length=500)
    recipe: RecipeDraft | None = None          # recreation (or a new alternative recipe)
    alternative_food_id: UUID | None = None    # alternative = an existing food
    sources: list[SourceRef] = Field(default=[], max_length=5)

    @model_validator(mode="after")
    def _one_payload(self) -> "VariantProposal":
        if (self.recipe is None) == (self.alternative_food_id is None):
            raise ValueError("provide exactly one of recipe or alternative_food_id")
        if self.mode == VariantMode.recreation and self.recipe is None:
            raise ValueError("a recreation must come with a full recipe")
        return self


class VariantBatch(Base):
    favorite_id: UUID
    variants: list[VariantProposal] = Field(min_length=1, max_length=5)


class MacroComparison(Base):
    orig: MacroSnapshot
    variant: MacroSnapshot
    kcal_delta_pct: float
    protein_delta_pct: float
    carbs_delta_pct: float
    fat_delta_pct: float


class VariantOut(ORMBase):
    id: UUID
    favorite_id: UUID
    mode: VariantMode
    variant_type_id: int
    title: str
    rationale: str
    variant_recipe_id: UUID | None
    variant_food_id: UUID | None
    comparison: MacroComparison | None = None
    sources: list[SourceRef] = []
    status: VariantStatus


class VariantDecision(Base):
    status: VariantStatus
    rating: int | None = Field(default=None, ge=1, le=5)
    reason: str | None = Field(default=None, max_length=500)
    feedback_tags: list[Code] = Field(default=[], max_length=8)

    @model_validator(mode="after")
    def _only_decisions(self) -> "VariantDecision":
        if self.status not in (VariantStatus.accepted, VariantStatus.rejected, VariantStatus.archived):
            raise ValueError("status must be accepted, rejected or archived")
        return self


# --------------------------------------------------------------------------
# Meal plans & workouts (agent-creatable, always as drafts)
# --------------------------------------------------------------------------
class MealPlanItemIn(_FoodOrRecipeLine):
    plan_date: date
    meal_type_code: Code
    notes: str | None = Field(default=None, max_length=300)


class MealPlanDraft(Base):
    title: ShortText
    start_date: date
    end_date: date
    items: list[MealPlanItemIn] = Field(min_length=1, max_length=400)
    notes: str | None = Field(default=None, max_length=1_000)
    source: SourceRef | None = None

    @model_validator(mode="after")
    def _dates(self) -> "MealPlanDraft":
        if self.end_date < self.start_date:
            raise ValueError("end_date before start_date")
        if (self.end_date - self.start_date).days > 31:
            raise ValueError("plans are limited to 32 days")
        for it in self.items:
            if not self.start_date <= it.plan_date <= self.end_date:
                raise ValueError(f"item date {it.plan_date} is outside the plan range")
        return self


class PlanExerciseIn(Base):
    exercise_id: UUID | None = None
    exercise_name: str | None = Field(default=None, max_length=120)  # service resolves or creates
    sets: int = Field(ge=1, le=20)
    reps_min: int | None = Field(default=None, ge=1, le=100)
    reps_max: int | None = Field(default=None, ge=1, le=100)
    rest_seconds: int | None = Field(default=None, ge=0, le=900)
    target_rpe: float | None = Field(default=None, ge=1, le=10)
    target_weight_kg: float | None = Field(default=None, ge=0, le=1_000)
    notes: str | None = Field(default=None, max_length=300)

    @model_validator(mode="after")
    def _check(self) -> "PlanExerciseIn":
        if not (self.exercise_id or self.exercise_name):
            raise ValueError("provide exercise_id or exercise_name")
        if self.reps_min and self.reps_max and self.reps_max < self.reps_min:
            raise ValueError("reps_max < reps_min")
        return self


class PlanDayIn(Base):
    name: ShortText
    notes: str | None = Field(default=None, max_length=300)
    exercises: list[PlanExerciseIn] = Field(min_length=1, max_length=20)


class WorkoutPlanDraft(Base):
    title: ShortText
    description: str | None = Field(default=None, max_length=1_000)
    goal_type_code: Code | None = None
    weeks: int | None = Field(default=None, ge=1, le=52)
    days: list[PlanDayIn] = Field(min_length=1, max_length=7)
    source: SourceRef | None = None


class WorkoutSetIn(Base):
    exercise_id: UUID
    set_number: int = Field(ge=1, le=50)
    reps: int | None = Field(default=None, ge=0, le=500)
    weight_kg: float | None = Field(default=None, ge=0, le=1_000)
    rpe: float | None = Field(default=None, ge=1, le=10)
    is_warmup: bool = False


class WorkoutLogCreate(Base):
    name: ShortText
    plan_day_id: UUID | None = None
    performed_at: datetime | None = None
    duration_minutes: int | None = Field(default=None, gt=0, le=600)
    perceived_effort: float | None = Field(default=None, ge=1, le=10)
    notes: str | None = Field(default=None, max_length=1_000)
    sets: list[WorkoutSetIn] = Field(min_length=1, max_length=300)


# --------------------------------------------------------------------------
# Shopping
# --------------------------------------------------------------------------
class ShoppingListRequest(Base):
    meal_plan_id: UUID | None = None
    date_from: date | None = None
    date_to: date | None = None
    subtract_pantry: bool = True

    @model_validator(mode="after")
    def _source(self) -> "ShoppingListRequest":
        if self.meal_plan_id is None and not (self.date_from and self.date_to):
            raise ValueError("provide meal_plan_id or a date range")
        return self


# --------------------------------------------------------------------------
# Chat & agent plumbing
# --------------------------------------------------------------------------
class ChatRequest(Base):
    thread_id: UUID | None = None
    message: str = Field(min_length=1, max_length=4_000)


class DraftRef(Base):
    """A pointer the UI renders as an approve / edit / discard card."""
    kind: str = Field(pattern=r"^(recipe|meal_plan|workout_plan|favorite_variants|shopping_list|meal_template)$")
    id: UUID
    title: str


class AgentContext(Base):
    """Compact, DB-derived snapshot injected into every agent run."""
    display_name: str
    language: str
    today: date
    timezone: str
    sex: Sex | None
    age_years: int | None
    weight_kg: float | None
    height_cm: float | None
    goal_summary: str | None
    todays_totals: MacroSnapshot | None
    allergies: list[str]
    dietary_preferences: list[str]
    disliked_foods: list[str]
    favorites: list[str]
    min_daily_kcal: float
    verbosity: Verbosity
    proactivity: Proactivity
    refer_out_topics: list[str]
