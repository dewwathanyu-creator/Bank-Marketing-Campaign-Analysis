"""Shared analysis helpers for the Bank Marketing project.

The notebooks (02_eda, 03_model) import from here, so a definition
(small-group rule, band order, fatigue split) lives in exactly one place.

Conventions:
  - pure functions that take and return DataFrames, no printing inside them
  - thresholds are named constants or parameters, never magic numbers in the middle of a function
  - vectorised pandas (groupby / clip / cumsum) instead of row loops
  - input is validated on load, so a damaged CSV fails loudly instead of silently dropping rows

Usage from a notebook in Exploration/:
    import sys; sys.path.append(".")
    from bm_analysis import load_clean, yes_rate_by
"""
from __future__ import annotations

import math
from pathlib import Path

import numpy as np
import pandas as pd

# ---- Project constants -------------------------------------------------------------------------
CLEAN_FILE = Path(__file__).resolve().parent.parent / "Data" / "bank_clean.csv"
EXPECTED_ROWS = 41_176          # 41,188 raw rows minus 12 exact duplicates
EXPECTED_SUBSCRIBERS = 4_639
SMALL_N = 500                   # groups below this are flagged as small
MIN_CELL_N = 100                # groups below this are not interpreted at all
Z_95 = 1.96

AGE_ORDER = ["<25", "25-29", "30-39", "40-49", "50-59", "60+"]
CAMP_ORDER = ["1", "2", "3", "4", "5", "6-7", "8-10", "11+"]
MONTH_ORDER = ["mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
FATIGUE_CUTOFF = 3              # "calls 1-3" vs "call 4 and later"


# ---- Loading and validation --------------------------------------------------------------------
def load_clean(path: Path | str = CLEAN_FILE, validate: bool = True) -> pd.DataFrame:
    """Read bank_clean.csv with ordered categorical bands and check it is the file notebook 01 wrote.

    Raises ValueError when a band label is unexpected. The usual cause is the CSV having been opened
    and saved in Excel, which turns the label "6-7" into a date. Rebuild the file by re-running
    Exploration/01_data_check.ipynb instead of fixing it by hand.
    """
    df = pd.read_csv(path, dtype={"age_band": str, "campaign_band": str})
    if validate:
        _validate_clean(df)
    df["age_band"] = pd.Categorical(df["age_band"], categories=AGE_ORDER, ordered=True)
    df["campaign_band"] = pd.Categorical(df["campaign_band"], categories=CAMP_ORDER, ordered=True)
    return df


def _validate_clean(df: pd.DataFrame) -> None:
    problems = []
    if len(df) != EXPECTED_ROWS:
        problems.append(f"row count {len(df):,} (expected {EXPECTED_ROWS:,})")
    if int(df["y_flag"].sum()) != EXPECTED_SUBSCRIBERS:
        problems.append(f"subscribers {int(df['y_flag'].sum()):,} (expected {EXPECTED_SUBSCRIBERS:,})")
    for col, allowed in (("age_band", AGE_ORDER), ("campaign_band", CAMP_ORDER)):
        bad = sorted(set(df[col].dropna().unique()) - set(allowed))
        if bad:
            problems.append(f"{col} has unexpected labels {bad}")
    if set(df["year"].unique()) != {2008, 2009, 2010}:
        problems.append(f"year values {sorted(df['year'].unique())} (expected 2008, 2009, 2010)")
    if problems:
        raise ValueError(
            "bank_clean.csv failed validation: " + "; ".join(problems)
            + ". If a band label looks like a date, the file was saved by Excel: "
              "re-run Exploration/01_data_check.ipynb to rebuild it."
        )


# ---- Core summaries ----------------------------------------------------------------------------
def yes_rate_by(df: pd.DataFrame, cols: str | list[str], overall_rate_pct: float | None = None,
                small_n: int = SMALL_N) -> pd.DataFrame:
    """One table shape for every question: customers, subscribers, yes rate, lift, small-group flag."""
    if overall_rate_pct is None:
        overall_rate_pct = df["y_flag"].mean() * 100
    out = df.groupby(cols, observed=True)["y_flag"].agg(customers="size", subscribers="sum")
    out["yes_rate_pct"] = (out["subscribers"] / out["customers"] * 100).round(1)
    out["lift_vs_overall"] = (out["yes_rate_pct"] / overall_rate_pct).round(2)
    out["small_group"] = out["customers"] < small_n
    return out


def per_call_yield(df: pd.DataFrame, max_call: int = 10) -> pd.DataFrame:
    """Subscriptions per call at call number k (1..max_call, then "max_call+1 and later").

    Assumption (not in the data): a client who subscribes is not called again, so the "yes" happened
    on the client's last contact (campaign == k). A client with campaign = c received calls 1..c.
    """
    campaign = df["campaign"].to_numpy()
    yes = df["y_flag"].to_numpy()
    ks = np.arange(1, max_call + 1)

    calls_made = np.array([(campaign >= k).sum() for k in ks] + [np.clip(campaign - max_call, 0, None).sum()])
    subs = np.append(
        pd.Series(yes).groupby(campaign).sum().reindex(ks, fill_value=0).to_numpy(),
        yes[campaign > max_call].sum(),
    )
    labels = [str(k) for k in ks] + [f"{max_call + 1}+"]
    out = pd.DataFrame({"calls_made": calls_made, "subscriptions": subs}, index=pd.Index(labels, name="call_number"))
    out["yes_rate_pct"] = (out["subscriptions"] / out["calls_made"].replace(0, np.nan) * 100).round(1)
    return out


def fatigue_summary(df: pd.DataFrame, by: str | None = None, cutoff: int = FATIGUE_CUTOFF) -> pd.DataFrame:
    """Calls and subscriptions split into "calls 1..cutoff" vs "call cutoff+1 and later" (per year when by='year')."""
    work = df.assign(
        _group="all" if by is None else df[by],
        calls_1_to_3=df["campaign"].clip(upper=cutoff),
        calls_4_plus=(df["campaign"] - cutoff).clip(lower=0),
        subs_4_plus=df["y_flag"].where(df["campaign"] > cutoff, 0),
    )
    out = work.groupby("_group").agg(
        total_calls=("campaign", "sum"), calls_1_to_3=("calls_1_to_3", "sum"), calls_4_plus=("calls_4_plus", "sum"),
        subs_4_plus=("subs_4_plus", "sum"), subs_all=("y_flag", "sum"),
    )
    out.index.name = by
    out["subs_1_to_3"] = out["subs_all"] - out["subs_4_plus"]
    out["yield_1_to_3_pct"] = (out["subs_1_to_3"] / out["calls_1_to_3"].replace(0, np.nan) * 100).round(1)
    out["yield_4_plus_pct"] = (out["subs_4_plus"] / out["calls_4_plus"].replace(0, np.nan) * 100).round(1)
    out["share_of_calls_4_plus_pct"] = (out["calls_4_plus"] / out["total_calls"] * 100).round(1)
    out["ratio_4plus_vs_1to3"] = (out["yield_4_plus_pct"] / out["yield_1_to_3_pct"]).round(2)
    return out


def compare_in_year(df: pd.DataFrame, name: str, group_mask: pd.Series, ref_mask: pd.Series,
                    min_n: int = MIN_CELL_N) -> pd.DataFrame:
    """Yes rate of a group vs a reference group inside each year; `usable` needs min_n customers in both."""
    work = df.assign(_g=group_mask, _r=ref_mask)
    out = pd.DataFrame({
        "group_n": work.groupby("year")["_g"].sum(),
        "group_yes_pct": work[work["_g"]].groupby("year")["y_flag"].mean() * 100,
        "ref_n": work.groupby("year")["_r"].sum(),
        "ref_yes_pct": work[work["_r"]].groupby("year")["y_flag"].mean() * 100,
    })
    out[["group_yes_pct", "ref_yes_pct"]] = out[["group_yes_pct", "ref_yes_pct"]].round(1)
    out["ratio"] = (out["group_yes_pct"] / out["ref_yes_pct"]).round(2)
    out["usable"] = (out["group_n"] >= min_n) & (out["ref_n"] >= min_n)
    out.insert(0, "factor", name)
    return out.reset_index()


# ---- Uncertainty -------------------------------------------------------------------------------
def wilson_ci(successes: int, n: int, z: float = Z_95) -> tuple[float, float]:
    """95% Wilson interval for a proportion, in percent. Better than the normal interval for small n or rates near 0/1."""
    if n == 0:
        return (math.nan, math.nan)
    p = successes / n
    denom = 1 + z**2 / n
    centre = (p + z**2 / (2 * n)) / denom
    half = z * math.sqrt(p * (1 - p) / n + z**2 / (4 * n**2)) / denom
    return 100 * (centre - half), 100 * (centre + half)


def rate_ratio_ci(k1: int, n1: int, k2: int, n2: int, z: float = Z_95) -> tuple[float, float, float]:
    """Rate ratio (group 1 / group 2) with an approximate 95% CI from the log-ratio normal approximation.

    Treats each call/customer as independent, so intervals are a little optimistic; read a CI that
    only just excludes 1 as weak evidence.
    """
    if min(k1, k2) == 0:
        return (math.nan, math.nan, math.nan)
    ratio = (k1 / n1) / (k2 / n2)
    se = math.sqrt((1 - k1 / n1) / k1 + (1 - k2 / n2) / k2)
    return ratio, ratio * math.exp(-z * se), ratio * math.exp(z * se)


# ---- Model evaluation --------------------------------------------------------------------------
def gains_table(y_true, score, steps: tuple[float, ...] = (0.05, 0.10, 0.20, 0.30, 0.50)) -> pd.DataFrame:
    """Cumulative gains: calling the top `step` share of customers by score reaches what share of all subscribers."""
    order = np.argsort(-np.asarray(score))
    y_sorted = np.asarray(y_true)[order]
    total_yes = y_sorted.sum()
    n_called = (len(y_sorted) * np.asarray(steps)).astype(int)
    reached = np.array([y_sorted[:n].sum() for n in n_called])
    return pd.DataFrame({
        "customers_called": n_called,
        "share_of_list": steps,
        "subscribers_reached": reached.astype(int),
        "share_of_all_subscribers": reached / total_yes,
        "lift_vs_random": (reached / total_yes) / np.asarray(steps),
    })
