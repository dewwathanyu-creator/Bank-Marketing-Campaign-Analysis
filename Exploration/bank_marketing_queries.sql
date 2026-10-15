-- Bank Marketing: SQL analysis (SQLite)
--
-- Source table: Data/bank_clean.csv, written by Exploration/01_data_check.ipynb.
-- How to run (sqlite3 shell, from the repository root):
--   1. sqlite3 bank_marketing.db
--   2. run section 0 below (creates the empty table)
--   3. .import --csv --skip 1 Data/bank_clean.csv bank_clean
--   4. run sections 1-13 (each one is a single SELECT)
--
-- Caveat for every query: the year is inferred from file order (the source has no year column).

-- =====================================================================
-- 0. create table
-- =====================================================================
-- Table that holds Data/bank_clean.csv.
-- Column names are snake_case: dots removed, and "default" renamed to credit_default
-- because DEFAULT is a reserved word in SQL.
-- Note: duration is stored for description only. Do not use it for prediction.

DROP TABLE IF EXISTS bank_clean;

CREATE TABLE bank_clean (
    source_row            INTEGER PRIMARY KEY,   -- position in the original file = time order
    age                   INTEGER,
    job                   TEXT,
    marital               TEXT,
    education             TEXT,
    credit_default        TEXT,
    housing               TEXT,
    loan                  TEXT,
    contact               TEXT,                  -- cellular / telephone
    month                 TEXT,
    day_of_week           TEXT,
    duration              INTEGER,               -- seconds; known only after the call ends
    campaign              INTEGER,               -- contacts in this campaign, including the last one
    pdays                 INTEGER,               -- 999 = not contacted before
    previous              INTEGER,
    poutcome              TEXT,                  -- failure / nonexistent / success
    emp_var_rate          REAL,
    cons_price_idx        REAL,
    cons_conf_idx         REAL,
    euribor3m             REAL,
    nr_employed           REAL,
    y                     TEXT,
    year                  INTEGER,               -- inferred from file order, not an original field
    campaign_period       TEXT,                  -- YYYY-MM
    y_flag                INTEGER,               -- 1 = subscribed
    previously_contacted  INTEGER,               -- 1 if previous > 0
    age_band              TEXT,
    campaign_band         TEXT
);


-- =====================================================================
-- 1. kpi by year
-- =====================================================================
-- Business question: what is the overall result of the campaign, and how different are the three years?
-- Why it matters: the year changes the yes rate so much that every later query is read next to this one.
-- Caveat: the year is inferred from file order (no year column in the source).

SELECT
    year,
    COUNT(*)                                   AS customers,
    SUM(y_flag)                                AS subscribers,
    ROUND(100.0 * SUM(y_flag) / COUNT(*), 1)   AS yes_rate_pct,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS share_of_all_customers_pct
FROM bank_clean
GROUP BY year
UNION ALL
SELECT
    NULL, COUNT(*), SUM(y_flag),
    ROUND(100.0 * SUM(y_flag) / COUNT(*), 1),
    100.0
FROM bank_clean
ORDER BY year;        -- the NULL row (all years) sorts first


-- =====================================================================
-- 2. yield per call
-- =====================================================================
-- Business question: how many subscriptions does the k-th call produce, and how fast does it fall?
-- Definition: calls made at number k = clients with campaign >= k.
--             subscriptions at k   = clients with campaign = k who said yes.
-- Assumption: a client who subscribes stops being called, so the yes happened on their last contact.
-- Rows with year NULL are all years pooled; read the per-year rows first.
-- Call numbers 11 and above are grouped into one row (call_no = 11).

WITH RECURSIVE call_number(k) AS (
    SELECT 1
    UNION ALL
    SELECT k + 1 FROM call_number WHERE k < 11
),
years(year) AS (
    SELECT DISTINCT year FROM bank_clean
    UNION ALL
    SELECT NULL
),
per_call AS (
    SELECT
        y.year,
        c.k AS call_no,
        -- for k = 11, count every call from the 11th onwards
        (SELECT COALESCE(SUM(CASE WHEN c.k < 11 THEN (b.campaign >= c.k)
                                  ELSE MAX(b.campaign - 10, 0) END), 0)
           FROM bank_clean b
          WHERE y.year IS NULL OR b.year = y.year)                          AS calls_made,
        (SELECT COALESCE(SUM(b.y_flag), 0)
           FROM bank_clean b
          WHERE (y.year IS NULL OR b.year = y.year)
            AND ((c.k < 11 AND b.campaign = c.k) OR (c.k = 11 AND b.campaign > 10))) AS subscriptions
    FROM years y CROSS JOIN call_number c
)
SELECT
    year,
    call_no,
    calls_made,
    subscriptions,
    ROUND(100.0 * subscriptions / NULLIF(calls_made, 0), 1) AS yield_pct,
    -- running share of all subscriptions reached by this call number
    ROUND(100.0 * SUM(subscriptions) OVER (PARTITION BY year ORDER BY call_no)
          / NULLIF(SUM(subscriptions) OVER (PARTITION BY year), 0), 1)                 AS cum_share_of_subscriptions_pct
FROM per_call
ORDER BY year, call_no;


-- =====================================================================
-- 3. calls 1to3 vs 4plus
-- =====================================================================
-- Business question: what share of call volume goes to the 4th call and later, and what does it return?
-- Why it matters: this is the "campaign fatigue" number for an operations manager.
-- Read the per-year rows first; the all-years row (year NULL) is pooled.
-- Caveat: subscription is assumed to happen on a client's last contact (see 02).

WITH by_year AS (
    SELECT
        year,
        SUM(campaign)                                   AS total_calls,
        SUM(MIN(campaign, 3))                           AS calls_1to3,
        SUM(MAX(campaign - 3, 0))                       AS calls_4plus,
        SUM(CASE WHEN campaign >= 4 THEN y_flag ELSE 0 END) AS subs_4plus,
        SUM(y_flag)                                     AS subs_all
    FROM bank_clean
    GROUP BY year
),
combined AS (
    SELECT year, total_calls, calls_1to3, calls_4plus, subs_4plus, subs_all FROM by_year
    UNION ALL
    SELECT NULL, SUM(total_calls), SUM(calls_1to3), SUM(calls_4plus), SUM(subs_4plus), SUM(subs_all) FROM by_year
)
SELECT
    year,
    total_calls,
    ROUND(100.0 * calls_4plus / NULLIF(total_calls, 0), 1)                       AS share_of_calls_4plus_pct,
    ROUND(100.0 * subs_4plus / NULLIF(subs_all, 0), 1)                           AS share_of_subs_from_4plus_pct,
    ROUND(100.0 * (subs_all - subs_4plus) / NULLIF(calls_1to3, 0), 1)            AS yield_calls_1to3_pct,
    ROUND(100.0 * subs_4plus / NULLIF(calls_4plus, 0), 1)                        AS yield_calls_4plus_pct,
    ROUND((1.0 * subs_4plus / NULLIF(calls_4plus, 0)) / NULLIF((subs_all - subs_4plus) * 1.0 / NULLIF(calls_1to3, 0), 0), 2) AS ratio_4plus_vs_1to3
FROM combined
ORDER BY year;


-- =====================================================================
-- 4. channel by year
-- =====================================================================
-- Business question: does cellular outperform landline, and does that hold in every year?
-- Why inside each year: the channel mix changed over time (landline dominated 2008), so a pooled
-- comparison could just reflect which year the calls were made in.

WITH seg AS (
    SELECT
        year,
        SUM(contact = 'cellular')                                   AS cellular_customers,
        SUM(CASE WHEN contact = 'cellular'  THEN y_flag ELSE 0 END) AS cellular_subs,
        SUM(contact = 'telephone')                                  AS telephone_customers,
        SUM(CASE WHEN contact = 'telephone' THEN y_flag ELSE 0 END) AS telephone_subs
    FROM bank_clean
    GROUP BY year
)
SELECT
    year,
    cellular_customers,
    ROUND(100.0 * cellular_subs  / NULLIF(cellular_customers, 0),  1) AS cellular_yes_pct,
    telephone_customers,
    ROUND(100.0 * telephone_subs / NULLIF(telephone_customers, 0), 1) AS telephone_yes_pct,
    ROUND((1.0 * cellular_subs / NULLIF(cellular_customers, 0)) / NULLIF(1.0 * telephone_subs / NULLIF(telephone_customers, 0), 0), 2) AS ratio_cellular_vs_telephone
FROM seg
ORDER BY year;


-- =====================================================================
-- 5. job rank by year
-- =====================================================================
-- Business question: which job groups respond best, and is the ranking stable across years?
-- Window function: RANK() within each year.
-- Rule: groups with fewer than 100 customers in a year are left out (their rates are too noisy).
-- lift_vs_year = the group's yes rate divided by that year's overall yes rate.

WITH seg AS (
    SELECT year, job, COUNT(*) AS customers, SUM(y_flag) AS subs
    FROM bank_clean
    GROUP BY year, job
),
yr AS (
    SELECT year, 1.0 * SUM(subs) / SUM(customers) AS year_rate
    FROM seg
    GROUP BY year
)
SELECT
    s.year,
    s.job,
    s.customers,
    s.subs,
    ROUND(100.0 * s.subs / s.customers, 1)                       AS yes_rate_pct,
    ROUND((1.0 * s.subs / s.customers) / y.year_rate, 2)         AS lift_vs_year,
    RANK() OVER (PARTITION BY s.year ORDER BY 1.0 * s.subs / s.customers DESC) AS rank_in_year
FROM seg s
JOIN yr y ON y.year = s.year
WHERE s.customers >= 100
ORDER BY s.year, rank_in_year;


-- =====================================================================
-- 6. previous outcome vs baseline
-- =====================================================================
-- Business question: are clients who said yes to an earlier campaign worth calling first?
-- Compared with clients never contacted before ('nonexistent'), inside each year.
-- Caveat: in 2008 only a few dozen clients had a previous success, so that year is flagged small.

WITH seg AS (
    SELECT year, poutcome, COUNT(*) AS customers, SUM(y_flag) AS subs
    FROM bank_clean
    GROUP BY year, poutcome
),
baseline AS (
    SELECT year, 1.0 * subs / customers AS base_rate
    FROM seg
    WHERE poutcome = 'nonexistent'
)
SELECT
    s.year,
    s.poutcome,
    s.customers,
    ROUND(100.0 * s.subs / s.customers, 1)                  AS yes_rate_pct,
    ROUND((1.0 * s.subs / s.customers) / b.base_rate, 2)    AS ratio_vs_never_contacted,
    CASE WHEN s.customers < 100 THEN 'small group' ELSE '' END AS note
FROM seg s
JOIN baseline b ON b.year = s.year
ORDER BY s.year, s.poutcome;


-- =====================================================================
-- 7. period trend lag
-- =====================================================================
-- Business question: how does the yes rate move from one campaign period (month) to the next?
-- Window function: LAG() gives the previous period's rate.
-- Caveats: (1) LAG compares with the previous period that exists in the data, which is not always
-- the previous calendar month (some months have no calls). (2) Periods under 500 customers are flagged;
-- their swings are mostly noise.

WITH p AS (
    SELECT campaign_period, COUNT(*) AS customers, SUM(y_flag) AS subs
    FROM bank_clean
    GROUP BY campaign_period
),
r AS (
    SELECT campaign_period, customers, 100.0 * subs / customers AS yes_rate
    FROM p
)
SELECT
    campaign_period,
    customers,
    ROUND(yes_rate, 1)                                                           AS yes_rate_pct,
    ROUND(yes_rate - LAG(yes_rate) OVER (ORDER BY campaign_period), 1)           AS change_vs_prev_period_pts,
    CASE WHEN customers < 500 THEN 'small group' ELSE '' END                     AS note
FROM r
ORDER BY campaign_period;


-- =====================================================================
-- 8. cumulative gains segments
-- =====================================================================
-- Business question: if the team could only call some customer segments, which order captures the most
-- subscribers per call made?
-- Segment = previous outcome x contact channel. Within each year, segments are sorted by yes rate and
-- running totals show: "calling the first N% of customers captures M% of subscribers".
-- Window function: running SUM() over the sorted segments.
-- Caveat: segment rates come from past data; this is a ranking of groups, not a guarantee for new customers.

WITH seg AS (
    SELECT year, poutcome, contact, COUNT(*) AS customers, SUM(y_flag) AS subs
    FROM bank_clean
    GROUP BY year, poutcome, contact
),
ranked AS (
    SELECT year, poutcome, contact, customers, subs, 1.0 * subs / customers AS rate FROM seg
)
SELECT
    year,
    poutcome,
    contact,
    customers,
    ROUND(100.0 * rate, 1) AS yes_rate_pct,
    ROUND(100.0 * SUM(customers) OVER (PARTITION BY year ORDER BY rate DESC, customers DESC
                                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
          / SUM(customers) OVER (PARTITION BY year), 1) AS cum_customers_pct,
    ROUND(100.0 * SUM(subs) OVER (PARTITION BY year ORDER BY rate DESC, customers DESC
                                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
          / SUM(subs) OVER (PARTITION BY year), 1)      AS cum_subscribers_pct
FROM ranked
ORDER BY year, rate DESC, customers DESC;


-- =====================================================================
-- 9. channel within month
-- =====================================================================
-- Business question: is cellular really better than landline, or does the pooled gap just reflect WHEN each channel was used?
-- Why: in 2008 the first two months had no cellular calls at all, so a by-year comparison still mixes different months.
-- Rule: compare channels inside the same campaign_period, and only where BOTH channels have at least 100 customers.

WITH by_month AS (
    SELECT
        campaign_period,
        SUM(contact = 'cellular')                                   AS cellular_customers,
        SUM(CASE WHEN contact = 'cellular'  THEN y_flag ELSE 0 END) AS cellular_subs,
        SUM(contact = 'telephone')                                  AS telephone_customers,
        SUM(CASE WHEN contact = 'telephone' THEN y_flag ELSE 0 END) AS telephone_subs
    FROM bank_clean
    GROUP BY campaign_period
)
SELECT
    campaign_period,
    cellular_customers,
    ROUND(100.0 * cellular_subs  / cellular_customers,  1) AS cellular_yes_pct,
    telephone_customers,
    ROUND(100.0 * telephone_subs / telephone_customers, 1) AS telephone_yes_pct,
    ROUND(100.0 * cellular_subs / cellular_customers - 100.0 * telephone_subs / telephone_customers, 1) AS gap_pts,
    CASE WHEN 1.0 * cellular_subs / cellular_customers > 1.0 * telephone_subs / telephone_customers
         THEN 'cellular higher' ELSE 'telephone higher' END AS direction
FROM by_month
WHERE cellular_customers >= 100 AND telephone_customers >= 100
ORDER BY campaign_period;


-- =====================================================================
-- 10. euribor band by year
-- =====================================================================
-- Business question: how does the yes rate move with the 3-month Euribor rate (the deposit-rate environment)?
-- Caution: Euribor falls with the calendar (2008 -> 2010), so bands overlap with years. Read the bands INSIDE each year;
-- 2008 has only the highest band, 2010 has almost only the lowest.

SELECT
    year,
    CASE WHEN euribor3m < 1 THEN '<1' WHEN euribor3m < 2 THEN '1-2' ELSE '2+' END AS euribor_band,
    COUNT(*)                                   AS customers,
    SUM(y_flag)                                AS subscribers,
    ROUND(100.0 * SUM(y_flag) / COUNT(*), 1)   AS yes_rate_pct,
    CASE WHEN COUNT(*) < 500 THEN 'small group' ELSE '' END AS note
FROM bank_clean
GROUP BY year, euribor_band
ORDER BY year, CASE euribor_band WHEN '<1' THEN 1 WHEN '1-2' THEN 2 ELSE 3 END;


-- =====================================================================
-- 11. calls per subscriber
-- =====================================================================
-- Business question: how many phone calls does the bank spend to win one term deposit?
-- Definition: calls = SUM(campaign) (contacts in this campaign); subscribers = clients with y = yes.
-- Rows with year NULL are all years pooled; read the per-year rows first (the pooled figure hides a huge change).

WITH yearly AS (
    SELECT year, SUM(campaign) AS calls, SUM(y_flag) AS subscribers, COUNT(*) AS customers
    FROM bank_clean
    GROUP BY year
),
all_years AS (
    SELECT NULL AS year, SUM(calls) AS calls, SUM(subscribers) AS subscribers, SUM(customers) AS customers FROM yearly
)
SELECT year, customers, calls, subscribers,
       ROUND(1.0 * calls / NULLIF(subscribers, 0), 1) AS calls_per_subscriber,
       ROUND(1.0 * calls / NULLIF(customers, 0), 2)   AS contacts_per_client
FROM (SELECT year, customers, calls, subscribers FROM all_years
      UNION ALL
      SELECT year, customers, calls, subscribers FROM yearly)
ORDER BY year;


-- =====================================================================
-- 12. age band by year
-- =====================================================================
-- Business question: do age bands really differ in yes rate, or is it a year effect?
-- Why: the oldest and youngest bands are concentrated in 2009-2010, when every group converted far more often.
-- Compare the bands INSIDE each year. lift_vs_year = band rate / all-customers rate of the same year.

WITH seg AS (
    SELECT year, age_band, COUNT(*) AS customers, SUM(y_flag) AS subscribers
    FROM bank_clean
    GROUP BY year, age_band
),
yr AS (
    SELECT year, 1.0 * SUM(subscribers) / SUM(customers) AS year_rate FROM seg GROUP BY year
)
SELECT s.year, s.age_band, s.customers, s.subscribers,
       ROUND(100.0 * s.subscribers / s.customers, 1)                AS yes_rate_pct,
       ROUND((1.0 * s.subscribers / s.customers) / y.year_rate, 2)  AS lift_vs_year,
       CASE WHEN s.customers < 500 THEN 'small group' ELSE '' END   AS note
FROM seg s JOIN yr y ON y.year = s.year
ORDER BY s.year, CASE s.age_band WHEN '<25' THEN 1 WHEN '25-29' THEN 2 WHEN '30-39' THEN 3
                                 WHEN '40-49' THEN 4 WHEN '50-59' THEN 5 ELSE 6 END;


-- =====================================================================
-- 13. retry depth by year
-- =====================================================================
-- Business question: how many times was each client contacted, and did that change between years?
-- Output: share of each year's customers by number of contacts (campaign_band).

WITH counts AS (
    SELECT year, campaign_band, COUNT(*) AS customers
    FROM bank_clean
    GROUP BY year, campaign_band
)
SELECT c.year, c.campaign_band, c.customers,
       ROUND(100.0 * c.customers / SUM(c.customers) OVER (PARTITION BY c.year), 1) AS share_of_year_pct
FROM counts c
ORDER BY c.year, CASE c.campaign_band WHEN '1' THEN 1 WHEN '2' THEN 2 WHEN '3' THEN 3 WHEN '4' THEN 4
                                       WHEN '5' THEN 5 WHEN '6-7' THEN 6 WHEN '8-10' THEN 7 ELSE 8 END;
