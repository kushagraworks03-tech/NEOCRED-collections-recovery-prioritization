-- ============================================================================
--     COLLECTIONS OPTIMIZATION & RECOVERY PRIORITIZATION — NEOCRED FINANCE
-- ============================================================================
-- Database : PostgreSQL / MySQL compatible
-- Author   : KUSHAGRA YADAV — Data Analyst
-- Sections :
--   1. Data Preparation & Feature Engineering
--   2. Portfolio Overview & Delinquency Snapshot
--   3. Roll Rate Analysis (SMA-0 -> SMA-1 -> SMA-2 -> NPA)
--   4. Vintage / Cohort Analysis
--   5. Pareto Analysis — Loss Concentration (80/20)
--   6. Recovery Rate by DPD Bucket — Cost of Delay
--   7. Segment-Level Collections Economics (Recovery ROI)
--   8. Final Prioritization Framework
-- ============================================================================
 
 
-- ============================================================================
-- GLOSSARY OF BUSINESS TERMS USED IN THIS ANALYSIS
-- ============================================================================
-- DPD  = Days Past Due
-- SMA  = Special Mention Account (RBI classification for early-stage overdue accounts)
--        SMA-0 = 1-30 DPD | SMA-1 = 31-60 DPD | SMA-2 = 61-90 DPD
-- NPA  = Non-Performing Asset (90+ DPD, per RBI classification norms)
-- OTS  = One-Time Settlement
-- DTI  = Debt-to-Income Ratio
-- FICO = Credit score model (used here as a proxy risk indicator)
-- ===========================================================================


-- =============================
-- TABLE DEFINITION
-- =============================

CREATE TABLE loan_collections (
    id                            BIGINT PRIMARY KEY,
    loan_amnt                     DECIMAL(12,2),
    term                          INT,
    int_rate                      DECIMAL(6,2),
    installment                   DECIMAL(10,2),
    grade                         VARCHAR(5),
    sub_grade                     VARCHAR(5),
    emp_length                    DECIMAL(4,1),
    home_ownership                VARCHAR(20),
    annual_inc                    DECIMAL(12,2),
    verification_status           VARCHAR(30),
    issue_d                       DATE,
    loan_status                   VARCHAR(30),
    purpose                       VARCHAR(50),
    dti                           DECIMAL(8,2),
    fico_range_low                DECIMAL(6,1),
    fico_range_high               DECIMAL(6,1),
    earliest_cr_line              DATE,
    open_acc                      DECIMAL(6,1),
    pub_rec                       DECIMAL(6,1),
    revol_bal                     DECIMAL(12,2),
    revol_util                    DECIMAL(6,2),
    total_acc                     DECIMAL(6,1),
    out_prncp                     DECIMAL(12,2),
    total_pymnt                   DECIMAL(12,2),
    total_rec_prncp               DECIMAL(12,2),
    total_rec_int                 DECIMAL(12,2),
    total_rec_late_fee            DECIMAL(12,2),
    recoveries                    DECIMAL(12,2),
    collection_recovery_fee       DECIMAL(12,2),
    last_pymnt_d                  DATE,
    last_pymnt_amnt               DECIMAL(12,2),
    next_pymnt_d                  DATE,
    collections_12_mths_ex_med    DECIMAL(6,1),
    mths_since_last_delinq        DECIMAL(6,1),
    delinq_2yrs                   DECIMAL(6,1),
    application_type              VARCHAR(20),
    mort_acc                      DECIMAL(6,1),
    pub_rec_bankruptcies          DECIMAL(6,1),
    hardship_flag                 VARCHAR(5),
    debt_settlement_flag          VARCHAR(5),
    settlement_status             VARCHAR(20),
    settlement_amount             DECIMAL(12,2),
    never_delinquent_flag         INT,
    had_settlement_flag           INT,
    loan_closed_flag              INT,
    fico_avg                      DECIMAL(6,1),
    credit_history_years          DECIMAL(6,2),
    dpd_stage                     VARCHAR(30),
    net_recovery_amount           DECIMAL(12,2)
);

-- ======================
-- VERIFY IMPORT
-- ======================
SELECT COUNT(*) FROM loan_collections;
SELECT * FROM loan_collections LIMIT 10;
SELECT dpd_stage, COUNT(*) FROM loan_collections GROUP BY dpd_stage;

-- ============================================================================
--  DATA PREPARATION & FEATURE ENGINEERING
-- ============================================================================

/* BUSINESS PROBLEM
 Raw loan-level data tells us a loan's current status, but not how severe that
 status is relative to others, which cohort it belongs to, or how long it has
 been active. Without this structure, we cannot compare accounts consistently
 across roll rate, vintage, or Pareto analysis later.

 OBJECTIVE
 Build a single reusable VIEW that:
   * Assigns a numeric severity order to dpd_stage (for roll rate transitions)
   * Buckets FICO and DTI into standard risk bands
   * Derives the issue-month cohort (for vintage analysis)
   * Calculates loan age in months (issue date to last payment date)
   * Calculates recovery rate % for accounts that have any recovery activity */

CREATE VIEW feature_data AS
WITH base_data AS (
    SELECT *
    FROM loan_collections
    WHERE
        loan_amnt > 0
        AND fico_avg IS NOT NULL
        AND issue_d IS NOT NULL
)
SELECT
    *,

    -- DPD Severity Order (low -> high risk, used for roll rate transition logic)
    CASE dpd_stage
        WHEN 'Closed - Paid'       THEN 0
        WHEN 'SMA-0'               THEN 1
        WHEN 'SMA-1'               THEN 2
        WHEN 'SMA-2'               THEN 3
        WHEN 'NPA - Default'       THEN 4
        WHEN 'NPA - Charged Off'   THEN 5
    END AS dpd_severity_order,

    -- FICO Band (standard credit-score banding, same convention as bureau reporting)
    CASE
        WHEN fico_avg < 580              THEN 'Poor'
        WHEN fico_avg BETWEEN 580 AND 669 THEN 'Fair'
        WHEN fico_avg BETWEEN 670 AND 739 THEN 'Good'
        WHEN fico_avg BETWEEN 740 AND 799 THEN 'Very Good'
        ELSE                                   'Excellent'
    END AS fico_band,

    -- DTI Band (Debt-to-Income Ratio risk banding)
    CASE
        WHEN dti < 15               THEN 'Low DTI'
        WHEN dti BETWEEN 15 AND 30   THEN 'Medium DTI'
        ELSE                              'High DTI'
    END AS dti_band,

    -- Vintage Cohort — the month the loan was issued 
    DATE_TRUNC('month', issue_d) AS issue_cohort_month,

    -- Loan Age in months — issue date to last payment date
    -- (proxy for how long the loan has been active/monitored)
    ROUND(
        (EXTRACT(YEAR FROM last_pymnt_d) - EXTRACT(YEAR FROM issue_d)) * 12
        + (EXTRACT(MONTH FROM last_pymnt_d) - EXTRACT(MONTH FROM issue_d))
    , 0) AS loan_age_months,

    -- Recovery Rate % — only meaningful where recovery activity actually occurred
    CASE
        WHEN recoveries > 0
        THEN ROUND(net_recovery_amount * 100.0 / NULLIF(recoveries, 0), 2)
        ELSE NULL
    END AS recovery_rate_pct

FROM base_data;


-- DATA VALIDATION — confirm distributions look correct before analysis

SELECT 
    dpd_stage, 
    dpd_severity_order, 
    COUNT(*) AS n,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 3) AS pct_of_portfolio
FROM feature_data
GROUP BY dpd_stage, dpd_severity_order
ORDER BY dpd_severity_order;


SELECT 
    fico_band, 
    COUNT(*) AS n,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct_of_portfolio
FROM feature_data
GROUP BY fico_band
ORDER BY n DESC;


SELECT 
    dti_band,  
    COUNT(*) AS n,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct_of_portfolio
FROM feature_data
GROUP BY dti_band
ORDER BY n DESC;


SELECT 
    issue_cohort_month, 
    COUNT(*) AS n,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct_of_portfolio
FROM feature_data
GROUP BY issue_cohort_month
ORDER BY issue_cohort_month
LIMIT 20;

-- =========
-- INSIGHTS
-- =========
/* DPD Stage
 Most loans (66%) are Closed - Paid -> healthy chunk of the book
 But Charged Off is also huge (30%) -> that's the real problem this project targets
 SMA stages (early warning, before NPA) are only ~4% combined -> most bad loans
   have already turned into losses instead of being caught early
 Takeaway: the real opportunity is catching the ~34K SMA accounts before they
   become Charged Off too

 FICO Band
 Most borrowers fall in "Good" (71%) -> not obviously high-risk on paper
 No "Poor" band at all -> NeoCred already filters out low credit scores
   at approval stage
 So credit score alone doesn't explain why 30% of loans are charged off -
   something else is driving it, which is what later sections should explain

 DTI Band
 Medium DTI is most common (53%) -> nothing extreme at first look
 High DTI is actually the smallest group (11%)
 So DTI alone doesn't explain the risk either - same as FICO

 Vintage Cohort
 Loan volume grew steadily from 2013 to mid-2014 -> NeoCred was scaling fast
   during this period
 One month (July 2014) looks unusually high -> worth double-checking later,
   could be a data issue */


-- ============================================================================
--  PORTFOLIO OVERVIEW & DELINQUENCY SNAPSHOT
-- ============================================================================

/* BUSINESS PROBLEM
 Leadership needs a single, reliable health check of the loan book: how much
 money is at risk, how much has already been lost, and how much of that loss
 has been clawed back through collections. Without this snapshot, every other
 analysis in this project lacks context for how big the problem actually is.

 OBJECTIVE
 Calculate portfolio-wide KPIs: total exposure, charge-off rate, NPA rate,
 SMA (early-warning) rate, and recovery efficiency — how much of the money
 already lost to charge-off has been recovered through collections effort. */

SELECT DISTINCT

    COUNT(*) OVER ()                      AS total_loans,
    SUM(loan_amnt) OVER ()                AS total_exposure,

    -- Charge-Off Rate — % of all loans that ended in Charged Off
    ROUND(
        SUM(CASE WHEN dpd_stage = 'NPA - Charged Off' THEN 1 ELSE 0 END) OVER ()
        * 100.0 / COUNT(*) OVER ()
    , 2) AS charge_off_rate_pct,

    -- NPA Rate — Charged Off + Default combined (RBI's 90+ DPD definition)
    ROUND(
        SUM(CASE WHEN dpd_stage IN ('NPA - Charged Off', 'NPA - Default') THEN 1 ELSE 0 END) OVER ()
        * 100.0 / COUNT(*) OVER ()
    , 2) AS npa_rate_pct,

    -- SMA Rate — accounts still in early-warning stages (not yet NPA)
    ROUND(
        SUM(CASE WHEN dpd_stage IN ('SMA-0', 'SMA-1', 'SMA-2') THEN 1 ELSE 0 END) OVER ()
        * 100.0 / COUNT(*) OVER ()
    , 2) AS sma_rate_pct,

    -- Total value sitting in Charged Off accounts (money already lost)
    SUM(CASE WHEN dpd_stage = 'NPA - Charged Off' THEN loan_amnt ELSE 0 END) OVER ()
        AS total_charged_off_value,

    -- Total recoveries collected (gross, before collection fees)
    SUM(recoveries) OVER ()               AS total_gross_recoveries,

    -- Total collection fees paid to recover that money
    SUM(collection_recovery_fee) OVER ()  AS total_collection_fees,

    -- Net recovery — what NeoCred actually kept after paying collection costs
    SUM(net_recovery_amount) OVER ()      AS total_net_recovery,

    -- Recovery Efficiency — of the money lost to charge-off, how much came back?
    ROUND(
        SUM(net_recovery_amount) OVER () * 100.0
        / NULLIF(SUM(CASE WHEN dpd_stage = 'NPA - Charged Off' THEN loan_amnt ELSE 0 END) OVER (), 0)
    , 2) AS recovery_efficiency_pct,

    -- Average time (in months) a loan takes to reach Charged Off status
    ROUND(
        AVG(CASE WHEN dpd_stage = 'NPA - Charged Off' THEN loan_age_months END) OVER ()
    , 1) AS avg_months_to_charge_off

FROM feature_data;


-- =========
-- INSIGHTS
-- =========
/* Portfolio Size
 847,494 loans totaling ~₹1,255.7 Cr in exposure -> a large, meaningful book

 Charge-Off & NPA Rate
 29.74% of all loans charged off, NPA rate almost identical at 29.75%
   -> confirms Default is basically a pass-through status, not a separate risk pool
 Only 4.03% of loans are in SMA stages (still recoverable, not yet NPA)
   -> most risk has already turned into a loss; very few accounts are currently
   sitting in the "catchable" window

 Money Already Lost
 ~₹395 Cr sitting in Charged Off accounts -> this is the real size of the problem
   this project is trying to solve

 Recovery Performance (this is the key number)
 Only 6.49% of that ₹395 Cr has actually been recovered (~₹25.6 Cr net,
   after paying ~₹5.2 Cr in collection fees)
 -> Recovery efficiency is very low -> confirms NeoCred's current collections
   process is largely reactive, not prioritized
 -> This is the baseline number any prioritization strategy in this project
   needs to beat

 Time to Charge-Off
 Loans take ~15.9 months on average to go from issued to Charged Off
 -> there's a real window of over a year where early intervention could
   change the outcome, but only 4% of accounts are currently being caught
   in that window (per the SMA rate above) */

-- ============================================================================
--  ROLL RATE ANALYSIS (STAGE CONCENTRATION PROXY)
-- ============================================================================

/* BUSINESS PROBLEM
 NeoCred wants to know which borrower segments deteriorate into worse
 delinquency stages most often, so collections effort can be focused there
 before accounts reach Charged Off.

 OBJECTIVE
 Rank loan grades and purposes by their concentration in high-severity stages,
 to identify which segments deserve earliest collections attention. */

-- STAGE DISTRIBUTION BY GRADE — % of each grade sitting in each dpd_stage
SELECT
    grade,
    dpd_stage,
    COUNT(*) AS n,
    ROUND(
        COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY grade)
    , 3) AS pct_within_grade
FROM feature_data
GROUP BY grade, dpd_stage
ORDER BY grade, dpd_stage;


-- DETERIORATION CONCENTRATION INDEX — % of each grade in SMA-2 + NPA stages
-- (i.e. the stages closest to or already at Charged Off)
WITH grade_severity AS (
    SELECT
        grade,
        COUNT(*) AS total_loans,
        SUM(CASE WHEN dpd_severity_order >= 3 THEN 1 ELSE 0 END) AS high_severity_loans
    FROM feature_data
    GROUP BY grade
)
SELECT
    grade,
    total_loans,
    high_severity_loans,
    ROUND(high_severity_loans * 100.0 / total_loans, 2) AS deterioration_rate_pct,
    RANK() OVER (ORDER BY high_severity_loans * 1.0 / total_loans DESC)
        AS deterioration_rank
FROM grade_severity
ORDER BY deterioration_rank;


-- SAME ANALYSIS BY LOAN PURPOSE — which stated purpose deteriorates most
WITH purpose_severity AS (
    SELECT
        purpose,
        COUNT(*) AS total_loans,
        SUM(CASE WHEN dpd_severity_order >= 3 THEN 1 ELSE 0 END) AS high_severity_loans
    FROM feature_data
    GROUP BY purpose
)
SELECT
    purpose,
    total_loans,
    high_severity_loans,
    ROUND(high_severity_loans * 100.0 / total_loans, 2) AS deterioration_rate_pct,
    RANK() OVER (ORDER BY high_severity_loans * 1.0 / total_loans DESC)
        AS deterioration_rank
FROM purpose_severity
ORDER BY deterioration_rank;


-- =========
-- INSIGHTS
-- =========
/* Stage Distribution by Grade
 Charge-off rate rises consistently A -> G: 9.9% -> 20.8% -> 32.5% -> 41.6%
   -> 50.5% -> 57.6% -> 61.1%
 -> Grade shows a clean, near-perfectly monotonic risk gradient - explains
    the 30% overall charge-off rate far better than FICO or DTI did alone
	
 SMA (still-recoverable) share stays small across all grades (~2-5%) but is
   proportionally highest in Grade G -> even the "catchable" pool skews
   toward the worst grades

 Deterioration Concentration Rank (SMA-2 + NPA combined)
 Same A-to-G gradient holds: Grade G has the highest deterioration rate
   (64.48%), Grade A the lowest (10.89%) -> confirms grade is the strongest
   single predictor of high-severity outcomes in this portfolio
 Gap between adjacent grades widens toward the bottom (E->F->G jumps ~7-10
   points each) -> risk doesn't increase linearly, it accelerates in the
   worst grades

 Deterioration by Loan Purpose
 small_business is the riskiest purpose (45.15% deterioration rate) -> makes
   intuitive sense, business income is less stable than salaried income
 debt_consolidation, despite being the largest purpose by volume (498,668
   loans), sits mid-pack at 33.75% -> not disproportionately risky, just big
 wedding and car loans are the safest purposes (24-26%) -> smaller, more
   predictable loan use-cases

Takeaway: purpose adds a secondary signal on top of grade, but grade remains
   the dominant driver - small_business + low grade together would be the
   highest-priority combination */

-- ============================================================================
--  VINTAGE / COHORT ANALYSIS
-- ============================================================================

/* BUSINESS PROBLEM
 NeoCred's underwriting standards may have shifted over time. Leadership
 wants to know whether loans issued in more recent periods are performing
 worse than older ones — a signal that credit quality is degrading, not
 just that risk is inherent to the portfolio.

 OBJECTIVE
 Track charge-off rate and grade mix by issue-month cohort over time, to
 identify whether newer vintages are riskier than older ones. */

-- COHORT PERFORMANCE OVER TIME
SELECT
    issue_cohort_month,
    COUNT(*) AS total_loans,
    SUM(CASE WHEN dpd_stage = 'NPA - Charged Off' THEN 1 ELSE 0 END) AS charged_off_loans,
    ROUND(
        SUM(CASE WHEN dpd_stage = 'NPA - Charged Off' THEN 1 ELSE 0 END) * 100.0
        / COUNT(*)
    , 2) AS charge_off_rate_pct,
    ROUND(AVG(loan_age_months), 1) AS avg_loan_age_months
FROM feature_data
GROUP BY issue_cohort_month
ORDER BY issue_cohort_month;


-- MATURE COHORTS ONLY — comparing recent cohorts to old ones is unfair,
-- recent loans haven't had enough time on book to default yet.
-- Restrict to cohorts at least 24 months old (a full seasoning window).
SELECT
    issue_cohort_month,
    COUNT(*) AS total_loans,
    ROUND(
        SUM(CASE WHEN dpd_stage = 'NPA - Charged Off' THEN 1 ELSE 0 END) * 100.0
        / COUNT(*)
    , 2) AS charge_off_rate_pct,
    RANK() OVER (
        ORDER BY SUM(CASE WHEN dpd_stage = 'NPA - Charged Off' THEN 1 ELSE 0 END) * 1.0
        / COUNT(*) DESC
    ) AS risk_rank
FROM feature_data
WHERE issue_cohort_month <= (SELECT MAX(issue_cohort_month) FROM feature_data) - INTERVAL '24 months'
GROUP BY issue_cohort_month
ORDER BY issue_cohort_month;


-- GRADE MIX SHIFT BY COHORT — did NeoCred's underwriting quality shift over time?
SELECT
    issue_cohort_month,
    grade,
    COUNT(*) AS n,
    ROUND(
        COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY issue_cohort_month)
    , 1) AS pct_within_cohort
FROM feature_data
GROUP BY issue_cohort_month, grade
ORDER BY issue_cohort_month, grade;


-- =========
-- INSIGHTS
-- =========
/* Raw Cohort Trend (unadjusted)
 Charge-off rate rises from ~24-26% in 2013 to a peak of ~35-37% around
   April-Sept 2016, then appears to fall sharply through 2017-2018 (down to
   under 1% by Dec 2018)
 But avg_loan_age_months falls in parallel (26 months -> 1.6 months) -> the
   late "improvement" is right-censoring, not real - recent loans simply
   haven't had time to default yet

 Mature Cohorts Only (24+ months old, properly comparable)
 After removing the censoring bias, 2016 cohorts are confirmed as the
   genuinely riskiest vintage - risk_rank 1-9 (the 9 worst cohorts) are ALL
   from April-November 2016, peaking at 37.47% in July 2016
 2013 cohorts sit at the safer end (~24-26%), 2015 cohorts sit in between
   (~29-31%) -> risk climbed steadily from 2013 to 2016, not randomly

 Grade Mix Shift Over Time
 F and G (worst grades) shrink steadily over time - from ~3% combined in
   2013 to under 1% by 2017-2018 -> NeoCred visibly tightened approval on
   the extreme tail
 C grade share grows substantially through 2016-2017, at times exceeding
   35% of monthly originations, while D grade share shrinks from ~17%
   (2013-14) down to ~12-14% during the 2016 peak-risk period

 The real finding (combining all three)
 Grade mix alone does NOT explain the 2016 risk spike - if anything, the
   mix looks safer on paper (fewer F/G, more mid-tier C) during exactly the
   period charge-off rates were highest
 -> This suggests grade quality itself drifted in 2016 - loans graded C
    in 2016 were not as safe as loans graded C in 2013/2014, even though
    they carried the same label
 -> Points to either a change in NeoCred's underwriting model calibration,
    or a macro/borrower-behavior shift that grade alone didn't capture
 -> This is a stronger, more specific finding than "some vintages are
    riskier" - it's "the grading system itself became less reliable during
    a specific window".*/

-- ============================================================================
--  PARETO ANALYSIS — LOSS CONCENTRATION (80/20)
-- ============================================================================

/* BUSINESS PROBLEM
 NeoCred's collections team has limited capacity and cannot treat every
 segment equally. Leadership wants to know: if we could only focus on a
 handful of segments, which ones would cover the majority of total losses?

 OBJECTIVE
 Rank segments (sub_grade, purpose, and grade x purpose combined) by total
 charged-off value, and calculate cumulative % of total loss to identify
 the minimum set of segments responsible for ~80% of losses. */

-- PARETO BY SUB_GRADE
WITH subgrade_loss AS (
    SELECT
        sub_grade,
        COUNT(*) AS total_loans,
        SUM(CASE WHEN dpd_stage = 'NPA - Charged Off' THEN loan_amnt ELSE 0 END)
            AS total_loss
    FROM feature_data
    GROUP BY sub_grade
)
SELECT
    sub_grade,
    total_loans,
    total_loss,
    ROUND(total_loss * 100.0 / SUM(total_loss) OVER (), 2) AS pct_of_total_loss,
    ROUND(
        SUM(total_loss) OVER (ORDER BY total_loss DESC) * 100.0
        / SUM(total_loss) OVER ()
    , 2) AS cumulative_pct_of_loss,
    ROW_NUMBER() OVER (ORDER BY total_loss DESC) AS loss_rank
FROM subgrade_loss
ORDER BY total_loss DESC;


-- PARETO BY LOAN PURPOSE
WITH purpose_loss AS (
    SELECT
        purpose,
        COUNT(*) AS total_loans,
        SUM(CASE WHEN dpd_stage = 'NPA - Charged Off' THEN loan_amnt ELSE 0 END)
            AS total_loss
    FROM feature_data
    GROUP BY purpose
)
SELECT
    purpose,
    total_loans,
    total_loss,
    ROUND(total_loss * 100.0 / SUM(total_loss) OVER (), 2) AS pct_of_total_loss,
    ROUND(
        SUM(total_loss) OVER (ORDER BY total_loss DESC) * 100.0
        / SUM(total_loss) OVER ()
    , 2) AS cumulative_pct_of_loss,
    ROW_NUMBER() OVER (ORDER BY total_loss DESC) AS loss_rank
FROM purpose_loss
ORDER BY total_loss DESC;


-- PARETO BY GRADE x PURPOSE COMBINED — the actual actionable segment list
WITH combo_loss AS (
    SELECT
        grade,
        purpose,
        COUNT(*) AS total_loans,
        SUM(CASE WHEN dpd_stage = 'NPA - Charged Off' THEN loan_amnt ELSE 0 END)
            AS total_loss
    FROM feature_data
    GROUP BY grade, purpose
)
SELECT
    grade,
    purpose,
    total_loans,
    total_loss,
    ROUND(total_loss * 100.0 / SUM(total_loss) OVER (), 2) AS pct_of_total_loss,
    ROUND(
        SUM(total_loss) OVER (ORDER BY total_loss DESC) * 100.0
        / SUM(total_loss) OVER ()
    , 2) AS cumulative_pct_of_loss,
    ROW_NUMBER() OVER (ORDER BY total_loss DESC) AS loss_rank
FROM combo_loss
WHERE total_loss > 0
ORDER BY total_loss DESC
LIMIT 20;


-- =========
-- INSIGHTS
-- =========
/* Sub-Grade Pareto
 It takes 18 out of 35 sub-grades to reach ~80% cumulative loss (E4 hits
   78.8%, E5 crosses to 81.5%) -> this is NOT a sharp classic 80/20 pattern
 -> Loss is moderately concentrated, but spread across roughly half the
    sub-grades, not a tiny handful
 
 No single sub-grade dominates - the top row (C4) is only 7% of total loss
 -> Confirms the Roll Rate Analysis finding again: losses come from volume x risk
    together, not risk alone
 
 C and D grades sit at the TOP of the loss ranking (positions 1-9), ahead
   of E, F, G -> this looks counterintuitive since C/D aren't the riskiest
   grades individually
 -> Reason: C and D have far higher loan volume (50K+ loans in C4 alone) vs
   G5's 914 loans -> even at a lower individual charge-off rate, C/D's
   sheer scale produces more total ₹ lost than the smaller, riskier E-G pool
 -> This is the single most important operational insight in the section:
    collections effort focused only on the "riskiest-looking" grades (F, G)
    would miss the majority of actual ₹ losses, which sit in the much
    larger C/D segment
 
 Purpose Pareto
 This one IS a sharp classic Pareto - debt_consolidation alone accounts for
   64.29% of all charged-off value, and just the top 2 purposes
   (debt_consolidation + credit_card) reach 83.4% cumulative
 -> Only 2 out of 13 purposes drive the vast majority of losses - a much
    tighter concentration than sub_grade showed
 -> Makes sense given volume: debt_consolidation is ~59% of the entire
    portfolio by loan count, so its dominance in loss is largely proportional,
    not a red flag on its own - but it does mean any collections strategy
    that doesn't specifically address debt_consolidation accounts is
    ignoring nearly two-thirds of total losses
 
 Grade x Purpose Combined (the real actionable list)
 Just 10 grade-purpose combinations reach ~80% cumulative loss (E-credit_card
   crosses to 79.65%, C-home_improvement pushes to 81.49%) out of ~91 possible
   combinations
 -> This is the sharpest, most useful Pareto in the section - 10 specific
    segments to focus on, not 18 or "all of debt_consolidation"
 Top 2 rows alone - C/debt_consolidation and D/debt_consolidation - account
   for 35.3% of total loss by themselves
 -> Final recommendation for further analysis: prioritize C & D grade debt_consolidation
    accounts first (largest single loss driver), then credit_card accounts
    across B-E grades as the second tier */

-- ============================================================================
-- SECTION 6 — RECOVERY RATE BY DPD BUCKET — COST OF DELAY
-- ============================================================================

/* BUSINESS PROBLEM
 NeoCred's collections team treats all overdue accounts with roughly equal
 urgency today. Leadership needs to know whether the delinquency stage an
 account is in actually predicts how much money is recoverable — i.e. does
 waiting longer to act really cost real money?

 OBJECTIVE
 For each DPD stage, measure what % of the loan's value has been recovered
 through payments so far, and — for accounts that have already gone through
 formal collections — how much of the remaining unpaid balance was clawed
 back. Together these quantify the cost of delayed intervention. */

-- PAYMENT RECOVERY RATE BY DPD STAGE
-- (% of loan value recovered through normal payments up to this point)
SELECT
    dpd_stage,
    dpd_severity_order,
    COUNT(*) AS total_loans,
    SUM(loan_amnt) AS total_exposure,
    SUM(total_pymnt) AS total_paid_so_far,
    ROUND(SUM(total_pymnt) * 100.0 / SUM(loan_amnt), 2) AS payment_recovery_rate_pct
FROM feature_data
GROUP BY dpd_stage, dpd_severity_order
ORDER BY dpd_severity_order;


-- POST-CHARGE-OFF COLLECTIONS EFFECTIVENESS
-- (of the money still outstanding at charge-off, how much did collections claw back?)
SELECT
    dpd_stage,
    COUNT(*) AS total_loans,
    SUM(loan_amnt - total_pymnt) AS total_outstanding_at_chargeoff,
    SUM(net_recovery_amount) AS total_net_recovered,
    ROUND(
        SUM(net_recovery_amount) * 100.0
        / NULLIF(SUM(loan_amnt - total_pymnt), 0)
    , 2) AS post_chargeoff_recovery_rate_pct
FROM feature_data
WHERE dpd_stage IN ('NPA - Charged Off', 'NPA - Default')
GROUP BY dpd_stage;


-- COST OF DELAY SUMMARY — direct comparison across the full severity spectrum
SELECT
    dpd_stage,
    dpd_severity_order,
    COUNT(*) AS total_loans,
    ROUND(SUM(total_pymnt) * 100.0 / SUM(loan_amnt), 2) AS payment_recovery_rate_pct,
    ROUND(AVG(loan_age_months), 1) AS avg_months_active,
    -- Recovery rate gap vs Closed-Paid loans (severity_order 0 = the healthy baseline)
    ROUND(
        FIRST_VALUE(SUM(total_pymnt) * 100.0 / SUM(loan_amnt))
            OVER (ORDER BY dpd_severity_order)
        - (SUM(total_pymnt) * 100.0 / SUM(loan_amnt))
    , 2) AS recovery_rate_gap_vs_earliest_stage
FROM feature_data
GROUP BY dpd_stage, dpd_severity_order
ORDER BY dpd_severity_order;


-- =========
-- INSIGHTS
-- =========
/* Payment Recovery Rate by Stage
 Closed-Paid loans recovered 116.09% of loan value (interest pushes it above
   100%) -> this is the healthy baseline every other stage is compared to
 Within SMA stages, recovery rate does decline as expected: SMA-0 (59.70%)
   -> SMA-1 (56.76%) -> SMA-2 (52.64%) -> a real ~7-point drop as accounts
   get more overdue

 But NPA-Charged Off (53.20%) is NOT dramatically worse than SMA-2 (52.64%)
 -> This breaks the simple "the longer you wait, the worse it gets" story -
    by the time a loan is charged off, it's actually recovered a similar
    share of its value to an account still sitting in SMA-2
 -> The real gap isn't between SMA-2 and Charged Off, it's between ANY
    distressed stage and Closed-Paid - every stage from SMA-0 to Charged Off
    sits 56-63 percentage points below a healthy loan

 Loan Age at Each Stage (the more interesting finding)
 Charged Off loans have the SHORTEST average age (15.9 months), while SMA
   loans that are still active sit at 18.8-20.8 months
 -> This suggests loans that eventually go bad tend to go bad relatively
    early - if a loan survives past ~16 months without charging off, it's
    more likely to keep struggling in SMA territory than to suddenly default
 -> This means "time on book" alone isn't a reliable risk signal - a loan's
    behavior in its first year matters more than how long it's been open

 NPA-Default caveat
 Only 40 loans in this category -> too small a sample to draw a reliable
   conclusion from its 58.04% figure, consistent with the earlier finding 
   that Default is a fast-transitioning, not a stable, status

 What this means for prioritization (feeds into the Recovery ROI segmentation)
 The clearest, most defensible message isn't "chase SMA-2 harder than
   Charged Off" - it's "any account showing distress recovers dramatically
   less value than a healthy loan, so the real win is catching accounts
   while they're still SMA-0/SMA-1, before the ~7-point decline into SMA-2
   even begins" */

-- ============================================================================
-- SECTION 7 — SEGMENT-LEVEL COLLECTIONS ECONOMICS (RECOVERY ROI)
-- ============================================================================

/* BUSINESS PROBLEM
 Not all recoverable segments are equally worth chasing — some segments
 return far more per rupee spent on collections than others. NeoCred needs
 to know where collections spend actually generates the best return, not
 just where the largest losses sit.

 OBJECTIVE
 Using actual collection_recovery_fee (real cost incurred) against
 net_recovery_amount (real money recovered), calculate a Recovery ROI per
 segment — grade, purpose, and grade x purpose combined — to rank where
 collections resourcing should be directed for maximum return. */

-- RECOVERY ROI BY GRADE
WITH grade_roi AS (
    SELECT
        grade,
        COUNT(*) AS charged_off_loans,
        SUM(recoveries) AS total_gross_recovered,
        SUM(collection_recovery_fee) AS total_fees_paid,
        SUM(net_recovery_amount) AS total_net_recovered
    FROM feature_data
    WHERE dpd_stage = 'NPA - Charged Off'
    GROUP BY grade
)
SELECT
    grade,
    charged_off_loans,
    total_net_recovered,
    total_fees_paid,
    ROUND(total_net_recovered * 1.0 / NULLIF(total_fees_paid, 0), 2) AS roi_multiple,
    ROUND(total_net_recovered / NULLIF(charged_off_loans, 0), 2) AS avg_net_recovery_per_loan,
    RANK() OVER (ORDER BY total_net_recovered * 1.0 / NULLIF(total_fees_paid, 0) DESC)
        AS roi_rank
FROM grade_roi
ORDER BY roi_rank;


-- RECOVERY ROI BY PURPOSE
WITH purpose_roi AS (
    SELECT
        purpose,
        COUNT(*) AS charged_off_loans,
        SUM(collection_recovery_fee) AS total_fees_paid,
        SUM(net_recovery_amount) AS total_net_recovered
    FROM feature_data
    WHERE dpd_stage = 'NPA - Charged Off'
    GROUP BY purpose
)
SELECT
    purpose,
    charged_off_loans,
    total_net_recovered,
    total_fees_paid,
    ROUND(total_net_recovered * 1.0 / NULLIF(total_fees_paid, 0), 2) AS roi_multiple,
    ROUND(total_net_recovered / NULLIF(charged_off_loans, 0), 2) AS avg_net_recovery_per_loan,
    RANK() OVER (ORDER BY total_net_recovered * 1.0 / NULLIF(total_fees_paid, 0) DESC)
        AS roi_rank
FROM purpose_roi
ORDER BY roi_rank;


-- COMBINED GRADE x PURPOSE — cross-referenced against Section 5's top loss segments
-- (does the highest-loss segment also give the best return on collections spend?)
WITH combo_roi AS (
    SELECT
        grade,
        purpose,
        COUNT(*) AS charged_off_loans,
        SUM(loan_amnt) AS total_loss_exposure,
        SUM(collection_recovery_fee) AS total_fees_paid,
        SUM(net_recovery_amount) AS total_net_recovered
    FROM feature_data
    WHERE dpd_stage = 'NPA - Charged Off'
    GROUP BY grade, purpose
    HAVING SUM(collection_recovery_fee) > 0
)
SELECT
    grade,
    purpose,
    charged_off_loans,
    total_loss_exposure,
    total_net_recovered,
    ROUND(total_net_recovered * 1.0 / total_fees_paid, 2) AS roi_multiple,
    RANK() OVER (ORDER BY total_net_recovered * 1.0 / total_fees_paid DESC) AS roi_rank,
    RANK() OVER (ORDER BY total_loss_exposure DESC) AS loss_rank
FROM combo_roi
ORDER BY roi_rank
LIMIT 20;

-- =========
-- INSIGHTS
-- =========
/* Recovery ROI by Grade
 ROI is actually fairly FLAT across grades (4.83x - 5.07x) - only a narrow
   0.24x spread from best (G) to worst (A)
 -> Slightly counterintuitive: G and F (riskiest grades) show marginally
    BETTER ROI than A and B, and also recover more ₹ per loan on average
    (G: ₹1,663 vs A: ₹703)
 -> Real takeaway: grade does NOT meaningfully predict collections
    efficiency - no grade should be deprioritized purely because it "seems"
    harder to collect from

 Recovery ROI by Purpose
 debt_consolidation - despite being the single largest loss driver from the
   Pareto Analysis (64% of total loss) - sits mid-pack on ROI (4.90x, rank 8
   of 13)
 -> Not the most efficient segment to collect from, but still solidly
    average - no red flag here
 credit_card sits near the bottom (4.86x, rank 12) despite being the
   2nd-largest loss driver -> slightly less efficient to collect on

 Grade x Purpose Combined - the critical catch
 The apparent "best ROI" segments (G-wedding at 99x, C/E/D-wedding all
   12-16x) are driven by tiny sample sizes - as few as 3 to 38 loans each
 -> These numbers are statistical noise, not a real pattern - one large
    recovery on a single wedding loan can swing the ROI multiple wildly
 -> Cross-checking against the Pareto Analysis's loss ranking confirms it:
   these "high ROI" segments rank 80-88 out of ~91 in total loss exposure -
   meaning they're worth almost nothing in absolute ₹ terms

 THE KEY STRATEGIC FINDING
 There is no meaningful trade-off between "highest loss" and "best ROI" at
   the volume that matters - the big loss-driver segments from the Pareto
   Analysis (C/D grade debt_consolidation) have solid, average ROI (~4.9x),
   while the flashy high-ROI segments are too small to matter financially
 -> Conclusion for the Final Prioritization Framework: prioritize by
    ABSOLUTE loss value, not by ROI percentage - chasing "efficient-looking"
    small segments would be a mistake; the real money is in the big
    segments, and they're perfectly collectible */

-- ============================================================================
-- SECTION 8 — FINAL PRIORITIZATION FRAMEWORK
-- ============================================================================

/* BUSINESS PROBLEM
 All prior analysis has produced separate findings — which grades
 deteriorate fastest, which segments drive the most loss, and where
 collections spend is most efficient. NeoCred's collections team needs a
 single, unified scoring system that combines these findings into one
 ranked worklist of currently open, at-risk accounts.

 OBJECTIVE
 Build a priority score for every account still in SMA-0/1/2 (not yet
 Charged Off) combining: how close it is to NPA, whether its grade
 historically deteriorates fast, and how much money is at stake. Bucket
 accounts into three action tiers, then validate the scoring logic against
 historical resolved loans to confirm it actually predicts charge-off. */

-- PRIORITY SCORING ON CURRENTLY OPEN AT-RISK ACCOUNTS
WITH scored_accounts AS (
    SELECT
        id,
        grade,
        purpose,
        dpd_stage,
        dpd_severity_order,
        loan_amnt,

        -- DPD proximity points — closer to NPA = higher urgency
        (dpd_severity_order * 10) AS dpd_points,

        -- Grade risk points — based on the Roll Rate Analysis finding that
        -- D-G grades deteriorate 2-6x more than A-C
        CASE
            WHEN grade IN ('D','E','F','G') THEN 15
            WHEN grade IN ('B','C')         THEN 8
            ELSE 3
        END AS grade_risk_points,

        -- Exposure points — larger loans carry more ₹ at stake
        CASE
            WHEN loan_amnt >= 20000 THEN 10
            WHEN loan_amnt >= 10000 THEN 6
            ELSE 3
        END AS exposure_points

    FROM feature_data
    WHERE dpd_stage IN ('SMA-0', 'SMA-1', 'SMA-2')
)
SELECT
    id,
    grade,
    purpose,
    dpd_stage,
    loan_amnt,
    (dpd_points + grade_risk_points + exposure_points) AS priority_score,
    CASE
        WHEN (dpd_points + grade_risk_points + exposure_points) >= 40 THEN 'TIER 1 - Immediate'
        WHEN (dpd_points + grade_risk_points + exposure_points) >= 25 THEN 'TIER 2 - Priority'
        ELSE 'TIER 3 - Monitor'
    END AS priority_tier
FROM scored_accounts
ORDER BY priority_score DESC;


-- VALIDATION — apply the same scoring logic retroactively to RESOLVED loans
-- (Closed-Paid vs Charged Off) to confirm higher scores actually predicted
-- worse outcomes historically
WITH resolved_scored AS (
    SELECT
        dpd_stage,
        grade,
        loan_amnt,
        (
            CASE WHEN grade IN ('D','E','F','G') THEN 15
                 WHEN grade IN ('B','C')         THEN 8
                 ELSE 3 END
            +
            CASE WHEN loan_amnt >= 20000 THEN 10
                 WHEN loan_amnt >= 10000 THEN 6
                 ELSE 3 END
        ) AS retro_score
    FROM feature_data
    WHERE dpd_stage IN ('Closed - Paid', 'NPA - Charged Off')
)
SELECT
    CASE
        WHEN retro_score >= 20 THEN 'High Score (would be Tier 1/2)'
        ELSE 'Low Score (would be Tier 3)'
    END AS retro_tier_group,
    COUNT(*) AS total_loans,
    SUM(CASE WHEN dpd_stage = 'NPA - Charged Off' THEN 1 ELSE 0 END) AS actually_charged_off,
    ROUND(
        SUM(CASE WHEN dpd_stage = 'NPA - Charged Off' THEN 1 ELSE 0 END) * 100.0
        / COUNT(*)
    , 2) AS actual_charge_off_rate_pct
FROM resolved_scored
GROUP BY retro_tier_group;


-- FINAL TIER SUMMARY — the actual deliverable for the collections team
WITH scored_accounts AS (
    SELECT
        loan_amnt,
        (
            (dpd_severity_order * 10)
            + CASE WHEN grade IN ('D','E','F','G') THEN 15
                   WHEN grade IN ('B','C')         THEN 8
                   ELSE 3 END
            + CASE WHEN loan_amnt >= 20000 THEN 10
                   WHEN loan_amnt >= 10000 THEN 6
                   ELSE 3 END
        ) AS priority_score
    FROM feature_data
    WHERE dpd_stage IN ('SMA-0', 'SMA-1', 'SMA-2')
)
SELECT
    CASE
        WHEN priority_score >= 40 THEN 'TIER 1 - Immediate'
        WHEN priority_score >= 25 THEN 'TIER 2 - Priority'
        ELSE 'TIER 3 - Monitor'
    END AS priority_tier,
    COUNT(*) AS accounts,
    SUM(loan_amnt) AS total_exposure,
    ROUND(AVG(loan_amnt), 2) AS avg_loan_size
FROM scored_accounts
GROUP BY priority_tier
ORDER BY priority_tier;


-- =========
-- INSIGHTS
-- =========
/* Scored Worklist (currently open SMA-0/1/2 accounts)
 The Tier 1 list is overwhelmingly D and E grade, debt_consolidation purpose
   -> directly consistent with the Roll Rate Analysis (D-G deteriorate
   fastest) and the Pareto Analysis (debt_consolidation drives 64% of loss) -
   the three separate analyses are all pointing at the same accounts, which
   is a strong internal consistency check
 
 Validation Against Historical Outcomes (the proof this framework works)
 Loans that WOULD have scored "High" (Tier 1/2 equivalent) actually charged
   off at 52.03% historically
 Loans that WOULD have scored "Low" (Tier 3 equivalent) only charged off at
   25.51% historically
 -> That's roughly a 2x difference in actual charge-off rate between the two
    groups - this is real proof the scoring logic isn't arbitrary, it
    genuinely separates loans that go bad from loans that don't
 
 Final Tier Summary (the live worklist)
 TIER 1 - Immediate: 21,747 accounts, ~₹38.0 Cr exposure, avg loan ₹17,479
 TIER 2 - Priority: 8,822 accounts, ~₹16.5 Cr exposure, avg loan ₹18,690
 TIER 3 - Monitor: 3,581 accounts, ~₹4.2 Cr exposure, avg loan ₹11,736
 Total: 34,150 open accounts, ~₹58.7 Cr total exposure currently recoverable
   -> Tier 1 alone covers ~64% of all currently open at-risk accounts and
      ~65% of total exposure - collections capacity should be weighted
      heavily toward this group first
 Interestingly, Tier 2 has the highest average loan size (₹18,690, even
   above Tier 1's ₹17,479) -> worth a manual spot-check in practice, since
   a handful of large Tier-2 loans could justify bumping specific accounts
   up a tier despite a lower composite score */
 
 
-- ==============================================================================
-- STRATEGIC RECOMMENDATIONS (EXECUTIVE SUMMARY)
-- ==============================================================================
/* TIER 1 - IMMEDIATE ACTION (21,747 accounts, ~₹38.0 Cr exposure)
   Assign to senior collections agents. Contact within 48 hours via phone,
   not automated channels. This tier is dominated by D/E grade
   debt_consolidation and credit_card loans in SMA-2 — the exact segment
   the Pareto Analysis and Roll Rate Analysis both independently flagged
   as highest-loss and fastest-deteriorating.
 
   TIER 2 - PRIORITY (8,822 accounts, ~₹16.5 Cr exposure)
   Standard collections cadence — SMS + call combination, contact within
   1 week. Given this tier's slightly higher average loan size than Tier 1,
   flag any individual account above ₹25,000 for manual review regardless
   of its composite score.
 
   TIER 3 - MONITOR (3,581 accounts, ~₹4.2 Cr exposure)
   Automated reminders only. Re-score weekly and escalate to Tier 2 the
   moment an account's dpd_stage worsens.
 
   OVERALL RECOMMENDATION
   The validation check confirms this framework is grounded in real
   outcomes, not assumptions — the "high score" group historically charged
   off at more than double the rate of the "low score" group (52.03% vs
   25.51%). Combined with the Recovery ROI segmentation showing no real
   efficiency trade-off across segments, the clearest strategy is to
   prioritize by absolute exposure and deterioration risk (this tiering),
   not by chasing seemingly "efficient" small segments. Tier 1 alone
   covers roughly two-thirds of all currently recoverable exposure and
   should receive the majority of collections capacity. */