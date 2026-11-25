"""Nutrio — deterministic nutrition logic.

The LLM never does arithmetic. Everything numeric goes through these pure
functions (no I/O, trivially unit-testable). Thresholds and rules are passed in
from the database (app_settings / safety_rules / variant_types.rule), never
hardcoded here.
"""
from __future__ import annotations

import math
from collections import defaultdict
from collections.abc import Iterable, Mapping, Sequence
from datetime import date, datetime, timezone
from typing import Any
from uuid import UUID

from .models import (
    BARCODE_RE,
    FoodSource,
    FoodUpsert,
    MacroComparison,
    MacroSnapshot,
    Nutrients100g,
    Sex,
)

KJ_PER_KCAL = 4.184


class IncompleteFoodError(ValueError):
    """Open Food Facts product lacks the data we need (energy + macros)."""


# --------------------------------------------------------------------------
# Portions
# --------------------------------------------------------------------------
def scale_nutrients(n: Nutrients100g, grams: float) -> MacroSnapshot:
    f = grams / 100.0
    r = lambda v: None if v is None else round(v * f, 2)  # noqa: E731
    sodium = n.sodium_mg_100g
    if sodium is None and n.salt_g_100g is not None:
        sodium = n.salt_g_100g * 400  # salt (g) -> sodium (mg)
    return MacroSnapshot(
        kcal=round(n.kcal_100g * f, 2),
        protein_g=round(n.protein_100g * f, 2),
        carbs_g=round(n.carbs_100g * f, 2),
        fat_g=round(n.fat_100g * f, 2),
        fiber_g=r(n.fiber_100g),
        sugar_g=r(n.sugar_100g),
        sodium_mg=r(sodium),
    )


def sum_snapshots(items: Iterable[MacroSnapshot]) -> MacroSnapshot:
    kcal = protein = carbs = fat = 0.0
    fiber = sugar = sodium = 0.0
    for s in items:
        kcal += s.kcal; protein += s.protein_g; carbs += s.carbs_g; fat += s.fat_g
        fiber += s.fiber_g or 0; sugar += s.sugar_g or 0; sodium += s.sodium_mg or 0
    return MacroSnapshot(kcal=round(kcal, 2), protein_g=round(protein, 2), carbs_g=round(carbs, 2),
                         fat_g=round(fat, 2), fiber_g=round(fiber, 2), sugar_g=round(sugar, 2),
                         sodium_mg=round(sodium, 2))


def recipe_per_serving(ingredients: Sequence[tuple[Nutrients100g, float]], servings: float) -> MacroSnapshot:
    """ingredients = [(nutrients_per_100g, grams), ...]"""
    total = sum_snapshots(scale_nutrients(n, g) for n, g in ingredients)
    s = servings
    return MacroSnapshot(
        kcal=round(total.kcal / s, 2), protein_g=round(total.protein_g / s, 2),
        carbs_g=round(total.carbs_g / s, 2), fat_g=round(total.fat_g / s, 2),
        fiber_g=round((total.fiber_g or 0) / s, 2), sugar_g=round((total.sugar_g or 0) / s, 2),
        sodium_mg=round((total.sodium_mg or 0) / s, 2),
    )


# --------------------------------------------------------------------------
# Energy balance
# --------------------------------------------------------------------------
def age_on(dob: date, on: date) -> int:
    return on.year - dob.year - ((on.month, on.day) < (dob.month, dob.day))


def bmr_mifflin_st_jeor(sex: Sex, weight_kg: float, height_cm: float, age_years: int) -> float:
    base = 10 * weight_kg + 6.25 * height_cm - 5 * age_years
    if sex == Sex.male:
        return base + 5
    if sex == Sex.female:
        return base - 161
    return base - 78  # 'other': midpoint of the two constants


def tdee(bmr: float, activity_multiplier: float) -> float:
    return bmr * activity_multiplier


def energy_from_macros(protein_g: float, carbs_g: float, fat_g: float) -> float:
    return 4 * protein_g + 4 * carbs_g + 9 * fat_g


def pct_delta(orig: float, new: float) -> float:
    if orig == 0:
        return 0.0 if new == 0 else 100.0
    return round((new - orig) / orig * 100, 1)


# --------------------------------------------------------------------------
# Open Food Facts mapping + quality gate
# --------------------------------------------------------------------------
def _num(d: Mapping[str, Any], key: str) -> float | None:
    v = d.get(key)
    try:
        return None if v in (None, "") else float(v)
    except (TypeError, ValueError):
        return None


def food_from_off_product(payload: Mapping[str, Any], preferred_lang: str = "en") -> FoodUpsert:
    """Map an Open Food Facts API v2 `product` object to a FoodUpsert.

    Raises IncompleteFoodError when energy or macros are missing, and lets
    Pydantic raise on physically impossible values. Verify field names against
    the current OFF API docs when upgrading.
    """
    code = str(payload.get("code") or payload.get("_id") or "")
    if not BARCODE_RE.match(code):
        raise IncompleteFoodError("missing or malformed barcode")
    nut = payload.get("nutriments") or {}

    kcal = _num(nut, "energy-kcal_100g")
    if kcal is None:
        kj = _num(nut, "energy-kj_100g") or _num(nut, "energy_100g")
        kcal = None if kj is None else kj / KJ_PER_KCAL
    protein, carbs, fat = (_num(nut, k) for k in ("proteins_100g", "carbohydrates_100g", "fat_100g"))
    if kcal is None or None in (protein, carbs, fat):
        raise IncompleteFoodError("missing energy or macronutrients")

    names = {k.removeprefix("product_name_"): v for k, v in payload.items()
             if k.startswith("product_name_") and isinstance(v, str) and v.strip()}
    name = (names.get(preferred_lang) or payload.get("product_name") or payload.get("generic_name")
            or next(iter(names.values()), None))
    if not name:
        raise IncompleteFoodError("product has no name")

    sodium_g = _num(nut, "sodium_100g")
    salt_g = _num(nut, "salt_100g")
    modified = payload.get("last_modified_t")
    cats = [c.strip() for c in (payload.get("categories") or "").split(",") if c.strip()][:10]
    grade = (payload.get("nutriscore_grade") or "").lower() or None

    return FoodUpsert(
        source=FoodSource.open_food_facts, external_id=code, name=name.strip()[:200], names=names,
        brand=(payload.get("brands") or "").split(",")[0].strip() or None, categories=cats,
        image_url=payload.get("image_front_url") or None,
        serving_g=_num(payload, "serving_quantity"), serving_label=payload.get("serving_size"),
        kcal_100g=kcal, protein_100g=protein, carbs_100g=carbs, fat_100g=fat,
        fiber_100g=_num(nut, "fiber_100g"), sugar_100g=_num(nut, "sugars_100g"),
        saturated_fat_100g=_num(nut, "saturated-fat_100g"),
        salt_g_100g=salt_g, sodium_mg_100g=None if sodium_g is None else sodium_g * 1000,
        nutriscore_grade=grade if grade in set("abcde") else None,
        nova_group=int(payload["nova_group"]) if str(payload.get("nova_group", "")).isdigit()
                   and 1 <= int(payload["nova_group"]) <= 4 else None,
        off_last_modified=datetime.fromtimestamp(modified, tz=timezone.utc) if isinstance(modified, (int, float)) else None,
    )


def assess_food_quality(n: Nutrients100g, tolerance_pct: float) -> tuple[str, str | None]:
    """('ok' | 'suspect', note). Flags foods whose listed kcal disagree with 4P+4C+9F.

    tolerance_pct comes from app_settings['food.energy_tolerance_pct'].
    Alcohol and fibre/polyols make small gaps normal, hence a generous default.
    """
    expected = energy_from_macros(n.protein_100g, n.carbs_100g, n.fat_100g)
    if expected < 20 and n.kcal_100g < 20:
        return "ok", None
    gap = abs(n.kcal_100g - expected) / max(expected, n.kcal_100g, 1) * 100
    if gap > tolerance_pct:
        return "suspect", (f"Listed {n.kcal_100g:.0f} kcal but macros add up to about {expected:.0f} kcal "
                           f"({gap:.0f}% apart). Please double-check the label.")
    return "ok", None


# --------------------------------------------------------------------------
# Favorites: does a variant actually deliver what it promises?
# --------------------------------------------------------------------------
def compare_macros(orig: MacroSnapshot, var: MacroSnapshot) -> MacroComparison:
    return MacroComparison(
        orig=orig, variant=var,
        kcal_delta_pct=pct_delta(orig.kcal, var.kcal),
        protein_delta_pct=pct_delta(orig.protein_g, var.protein_g),
        carbs_delta_pct=pct_delta(orig.carbs_g, var.carbs_g),
        fat_delta_pct=pct_delta(orig.fat_g, var.fat_g),
    )


def check_variant_rule(rule: Mapping[str, Mapping[str, float]], cmp: MacroComparison) -> list[str]:
    """Evaluate variant_types.rule against the computed comparison.

    rule example: {"protein_g": {"min_delta_pct": 20}, "kcal": {"max_delta_pct": -10}}
    Returns human-readable failures (empty list = variant passes).
    """
    deltas = {"kcal": cmp.kcal_delta_pct, "protein_g": cmp.protein_delta_pct,
              "carbs_g": cmp.carbs_delta_pct, "fat_g": cmp.fat_delta_pct}
    failures: list[str] = []
    for metric, bounds in rule.items():
        if metric not in deltas:
            continue
        d = deltas[metric]
        if "min_delta_pct" in bounds and d < bounds["min_delta_pct"]:
            failures.append(f"{metric} changed {d:+.0f}% (needs at least {bounds['min_delta_pct']:+.0f}%)")
        if "max_delta_pct" in bounds and d > bounds["max_delta_pct"]:
            failures.append(f"{metric} changed {d:+.0f}% (needs at most {bounds['max_delta_pct']:+.0f}%)")
    return failures


# --------------------------------------------------------------------------
# Adaptive goals — a gentle, explainable nudge, never an automatic change
# --------------------------------------------------------------------------
def weekly_trend_kg(points: Sequence[tuple[date, float]]) -> float | None:
    """Least-squares slope of weight over time, in kg per week."""
    if len(points) < 2:
        return None
    xs = [(d - points[0][0]).days for d, _ in points]
    ys = [w for _, w in points]
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    den = sum((x - mx) ** 2 for x in xs)
    if den == 0:
        return None
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den * 7


def suggest_calorie_adjustment(
    *, goal_code: str, current_kcal: float, weight_kg: float,
    trend_kg_per_week: float | None, n_entries: int,
    min_entries: int, step_kcal: float, min_daily_kcal: float, max_weekly_loss_pct: float,
    thresholds: Mapping[str, float],
) -> tuple[float, str] | None:
    """Return (new_kcal, plain-language reason) or None when no change is warranted.

    Every number comes from the database: `thresholds` is read from app_settings
    keys 'adaptive_goal.lose_stall_pct', '.gain_stall_pct', '.gain_fast_pct' and
    '.maintain_drift_pct' (all % of body weight per week); the rest from
    app_settings / safety_rules. The result is only ever a *suggestion* the
    user must accept.
    """
    if trend_kg_per_week is None or n_entries < min_entries:
        return None
    pct = trend_kg_per_week / weight_kg * 100
    if goal_code == "lose_fat":
        if pct > -thresholds["lose_stall_pct"]:          # barely moving down
            new = max(current_kcal - step_kcal, min_daily_kcal)
            if new < current_kcal:
                return new, "Your weight has been steady lately, so a small trim could help."
        elif pct < -max_weekly_loss_pct:                 # dropping too fast
            return current_kcal + step_kcal, "Weight is dropping faster than is comfortable; a little more food may help."
    elif goal_code == "gain_muscle":
        if pct < thresholds["gain_stall_pct"]:
            return current_kcal + step_kcal, "Weight isn't trending up yet, so a small increase could help."
        if pct > thresholds["gain_fast_pct"]:
            return max(current_kcal - step_kcal, min_daily_kcal), "Weight is rising quickly; a small reduction may keep gains leaner."
    elif goal_code == "maintain":
        if abs(pct) > thresholds["maintain_drift_pct"]:
            delta = -step_kcal if pct > 0 else step_kcal
            return max(current_kcal + delta, min_daily_kcal), "Weight is drifting from where you want it."
    return None


# --------------------------------------------------------------------------
# Shopping list
# --------------------------------------------------------------------------
def aggregate_shopping(
    needs: Iterable[tuple[UUID, float]],
    pantry_g: Mapping[UUID, float] | None = None,
) -> dict[UUID, tuple[float, float]]:
    """Sum grams per food, subtract what's in the pantry.

    Returns {food_id: (grams_to_buy, grams_deducted_from_pantry)}; foods fully
    covered by the pantry are omitted.
    """
    totals: dict[UUID, float] = defaultdict(float)
    for food_id, grams in needs:
        totals[food_id] += grams
    pantry = pantry_g or {}
    out: dict[UUID, tuple[float, float]] = {}
    for food_id, need in totals.items():
        have = min(pantry.get(food_id, 0.0), need)
        to_buy = need - have
        if to_buy > 0.5:
            out[food_id] = (round(to_buy, 1), round(have, 1))
    return out


def round_to_pack(grams: float, step_g: float = 50.0) -> float:
    """Round up to a sensible purchasable amount."""
    return math.ceil(grams / step_g) * step_g
