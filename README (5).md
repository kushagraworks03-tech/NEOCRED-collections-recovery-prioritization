<div align="center">

# 💳 NeoCred Finance — Collections Optimization & Recovery Prioritization

### *A data-driven collections strategy for an NBFC with fixed headcount and a shrinking recovery window.*

**[🚀 Live App](#)** · **[📊 Dashboard Screenshots](#-power-bi-bringing-it-together-for-a-decision-maker)** · **[🗃️ SQL Workbook](<./SQL%20PROJECT/NEOCRED%20FINANCE%20PROJECT.sql>)** · **[🐍 Python Notebook](<./NEOCRED%20PYTHON%20FILE/NEOCRED_FINANCE_PROJECT_.ipynb>)**

</div>

---

## 🎯 The Problem

NeoCred Finance is a Delhi NCR-based NBFC offering unsecured personal loans and short-tenure BNPL-style credit — the same space as players like Fibe, Navi, or MoneyTap. Like most lenders in this segment, NeoCred is feeling real pressure: post the RBI's November 2023 risk-weight hike on unsecured consumer credit and the 2025 IRACP borrower-wise NPA classification rule, unsecured retail loans have made up roughly **52% of new retail NPAs** industry-wide in H1FY25.

NeoCred's collections team has **fixed headcount**. They cannot call every overdue borrower every day — and the data shows that matters enormously. Recovery rates collapse the longer an account is left untouched:

> 🟢 **85–95%** recoverable at SMA-0 (1–30 DPD) → 🟡 **40–60%** by SMA-2 (61–90 DPD) → 🔴 **below 25%** once an account crosses 90 DPD into NPA

Leadership's ask was simple to state and hard to solve:

> ### *"Given limited collections capacity, how do we identify, prioritize, and strategize recovery efforts across the loan book to maximize ₹ recovered while minimizing accounts rolling forward into NPA?"*

This project answers that question — first by diagnosing **where** the risk lives in the portfolio, then by predicting **who** is actually worth chasing and **when**, and finally by turning both into a dashboard a collections manager could use on a Monday morning.

---

## 🧭 The Approach: Two Independent Workstreams, One Answer

Rather than running one blended analysis, this project deliberately splits into two non-overlapping workstreams — one built like a business/PM analyst would build it, one built like a statistician/ML practitioner would.

| 🗃️ SQL asks | 🐍 Python asks | 📊 Power BI asks |
|---|---|---|
| *What is happening in the portfolio, and where should business attention go?* | *Given a specific account, what's the probability and expected value of recovering it, and when?* | *How do I put both of those in front of a decision-maker who has five minutes?* |

> **The story in one sentence:** SQL told us where the risk was. Python told us who's worth chasing and when. Power BI brought both together for a business decision.

---

## 📁 Dataset

[LendingClub 2007–2018](https://www.kaggle.com/datasets/wordsforthewise/lending-club) (Kaggle), cleaned and filtered to **847,494 loans** representing **₹1,255.7 Cr** in total exposure. Cleaning handled type coercion (term, employment length, dates), missing-value logic with explicit business reasoning per column (e.g. missing `mths_since_last_delinq` means *never delinquent*, not *unknown* — flagged and filled accordingly, not blanket-imputed), and derived fields like `dpd_stage` (an RBI-style SMA/NPA classification) that both workstreams build on.

---

## 🗃️ Part A — SQL: *"Where Is the Risk Coming From?"*

*Business-analyst framing, using named, industry-standard techniques — the kind you'd find in any bank's or NBFC's portfolio risk reporting, not something invented for this project.*

| Question | Technique | SQL tools used |
|---|---|---|
| How fast do accounts deteriorate through DPD stages? | 🔻 **Roll Rate Analysis** | Window functions, CTEs |
| Do certain loan vintages perform worse over time? | 📅 **Vintage / Cohort Analysis** | Cohort grouping, censoring-aware "mature cohorts only" filtering |
| Which segments drive most of the ₹ loss? | 📉 **Pareto Analysis (80/20 on charged-off value)** | Cumulative SUM, RANK() window functions |
| How much value is lost simply by delaying contact? | ⏱️ **Recovery Rate by DPD Bucket** | CASE-based bucketing |
| Which segments are worth prioritizing given limited capacity? | 💰 **Segment-Level Collections Economics (Recovery ROI)** | Multi-CTE joins, ratio metrics |

### 🔑 What the data showed

- 📈 **Charge-off rate climbs cleanly from Grade A (9.87%) to Grade G (61.13%)** — a textbook Roll Rate deterioration curve, confirming grade as the strongest single risk signal in the book.
- 📅 **2016-issued loans are the riskiest vintage**, peaking at a 37.1–37.5% charge-off rate — not explained by grade mix alone, suggesting a real underwriting/market shift that year, not just noise.
- 🎯 **Just 10 grade × purpose combinations drive roughly 80% of total losses.** Grade C and D debt-consolidation loans alone account for over a third of it — this is the single most actionable finding in the SQL phase.
- 🔀 **The twist that sets up the entire Python phase:** Recovery ROI is essentially flat across grade (4.83x–5.07x, barely moving). Grade predicts whether a loan goes bad — it tells you almost nothing about whether you'll get money back once it does.
- ✅ A retroactive validation of the resulting priority-scoring logic against **real historical outcomes** confirmed it wasn't arbitrary: accounts that would have scored "High Priority" actually charged off at **52.03%**, versus **25.51%** for "Low Priority" accounts — roughly a 2x separation.

> **SQL deliverable:** a segment-to-strategy table — e.g. *"Grade D, 31–60 DPD, debt-consolidation purpose → highest recovery-per-contact-attempt, prioritize this segment first."* Pure business reasoning, no modeling.

---

## 🐍 Part B — Python: *"Who's Actually Worth Chasing, and When?"*

*Statistical/ML framing — genuinely technical depth (survival analysis is rare in fresher portfolios) without drifting into research-lab complexity.*

### 🔍 B1 — Feature Engineering & EDA
Built the modeling backbone: `event`/`duration_months` for survival analysis, `chargedoff_balance` and `recovery_rate` (correctly using charged-off balance, not the LendingClub-zeroed `out_prncp`, as the exposure denominator — an early modeling bug caught and fixed mid-project) for the recovery model. EDA independently reconfirmed every SQL finding in Python.

### ⏳ B2 — Survival Analysis: Kaplan-Meier + Cox Proportional Hazards
Kaplan-Meier curves show default risk is **front-loaded** — the steepest decline happens in the first 24 months. A multivariate log-rank test confirms grade-based separation is statistically significant (**p < 0.005**).

The Cox Proportional Hazards model quantifies this while controlling for DTI, FICO, income, and more simultaneously:

> ### 🔥 A Grade G loan carries **7.23x** the instantaneous risk of charge-off compared to Grade A, holding everything else constant.

Concordance = 0.66 — a believable, non-inflated fit for origination-time-only features.

### 🤖 B3 — Recovery Likelihood Model: A Real Multi-Model Comparison
Four models benchmarked head-to-head on the *charged-off population only* (252,103 loans), using ROC-AUC and F1 rather than accuracy, since the target was imbalanced (67% recovered / 33% not):

| Model | ROC-AUC | F1 |
|---|:---:|:---:|
| Logistic Regression | 0.5712 | 0.8028* |
| Decision Tree | 0.5700 | 0.6489 |
| Random Forest | 0.5837 | 0.6548 |
| 🏆 **XGBoost (tuned)** | **0.6022** | **0.6658** |

*\*Logistic Regression's high F1/Recall is an imbalance artifact — it's close to predicting "recovered" for nearly everyone, which is why ROC-AUC (ranking ability, independent of threshold) was the deciding metric.*

XGBoost was tuned via `RandomizedSearchCV` (3-fold CV, 15 sampled configurations) — a deliberate choice over exhaustive `GridSearchCV`, since the four-model comparison had already shown the ceiling was feature-signal-limited, not tuning-limited.

### 💡 B4 — SHAP Explainability: The Key Twist

> ### Recovery is driven by financial capacity (`annual_inc`, `fico_avg`, `dti`) and loan size — **not** by the origination risk grade that dominated the survival analysis.

Worse-grade loans even show a *slight positive* association with recovery in SHAP, likely because higher-risk accounts receive more aggressive collections attention. This closes the loop the SQL phase opened: **grade predicts default. It does not predict recovery.**

### 🎯 B5 — Recovery Value Score
Combining recovery probability (XGBoost) with charged-off exposure produces a single number per loan: expected recoverable value.

<div align="center">

| 🔴 Priority Tier | Loan Count | Avg. Recovery Probability | % of Total Expected Recovery |
|---|:---:|:---:|:---:|
| 🟢 **High Priority** | 50,421 | 0.57 | **44.6%** |
| 🟡 Medium Priority | 75,630 | 0.52 | 34.2% |
| ⚪ Low Priority | 126,052 | 0.48 | 21.2% |

</div>

The **top 20% of accounts by score hold 44.6% of total expected recovery value** (₹66.32 Cr of ₹148.82 Cr) — and carry the highest average recovery probability too, confirming the tiering isn't just "chase the biggest debts," it's "chase the debts most worth chasing."

---

## 📊 Part C — Power BI: Bringing It Together for a Decision-Maker

A four-page executive dashboard, built specifically to answer a business question per page rather than replicate raw data.

### 1️⃣ Executive Summary — *"Where is NeoCred losing money?"*
Portfolio scale, the ₹4bn already lost to charge-offs, and today's 6.49% recovery efficiency.

![Executive Summary](<./POWER BI DASHBOARD/EXECUTIVE SUMMARY.png>)

### 2️⃣ SQL Diagnosis — *"Where is the risk coming from?"*
Deterioration by grade, the top-loss-driving segments, the 2016 vintage spike, and the flat-ROI twist.

![SQL Analysis](<./POWER BI DASHBOARD/SQL ANALYSIS.png>)

### 3️⃣ Python Modeling — *"How do we predict what SQL can't explain?"*
Hazard ratios by grade, survival probability over time, and the SHAP ranking that reveals recovery's different drivers.

![Python Analysis](<./POWER BI DASHBOARD/PYTHON ANALYSIS.png>)

### 4️⃣ Business Recommendation — *"What should NeoCred do about it?"*
The priority-tier breakdown, the 44.6% headline concentration stat, and direct recommended actions.

![Business Recommendation](<./POWER BI DASHBOARD/BUSINESS RECOMMENDATION.png>)

---

## 🚀 Live Demo

An interactive Streamlit app lets you input a hypothetical loan's characteristics (grade, income, DTI, FICO, purpose, etc.) and get back a live recovery probability, an estimated Recovery Value Score, and a priority tier.

### **[🔗 Try the live app →](#)**

---

## 🛠️ Tech Stack

| Layer | Tools |
|---|---|
| 🗃️ Data Cleaning & SQL Analysis | PostgreSQL, window functions, CTEs |
| 🐍 Python Modeling | Pandas, NumPy, Matplotlib, Seaborn, `lifelines` (Kaplan-Meier, Cox PH), Scikit-learn, XGBoost, SHAP |
| 📊 Dashboarding | Power BI, DAX |
| 🚀 Deployment | Streamlit |

## 🧠 Techniques & Concepts Used

`Roll Rate Analysis` `Vintage/Cohort Analysis` `Pareto Analysis` `Segment-Level Collections Economics` `Survival Analysis (Kaplan-Meier, Log-Rank Test)` `Cox Proportional Hazards Regression` `Multi-Model Classification Benchmarking` `RandomizedSearchCV with Cross-Validation` `SHAP Explainability` `Probability-Weighted Expected Value Scoring` `DAX Measures & Conditional Formatting`

---

## 📂 Repository Structure

```
├── SQL PROJECT/
│   └── NEOCRED FINANCE PROJECT.sql          # Full SQL workbook (8 sections)
├── NEOCRED PYTHON FILE/
│   └── NEOCRED_FINANCE_PROJECT_.ipynb       # Full Python notebook (EDA → survival → recovery model → SHAP → scoring)
├── NEOCRED APP/
│   ├── app.py                               # Streamlit app
│   ├── requirements.txt                     # Python dependencies for deployment
│   ├── recovery_xgb_model.pkl               # Trained, tuned XGBoost recovery model
│   ├── model_columns.pkl                    # Feature column structure for inference
│   └── reference_data.pkl                   # Dropdown reference lists for the app
└── POWER BI DASHBOARD/
    ├── EXECUTIVE SUMMARY.png
    ├── SQL ANALYSIS.png
    ├── PYTHON ANALYSIS.png
    └── BUSINESS RECOMMENDATION.png
```

---

## ⚖️ A Note on Scope

This is a self-directed, portfolio-based project built on public data (LendingClub), not a production system — it doesn't handle data drift, live monitoring, or real deployment constraints. The recovery model's ROC-AUC (~0.60) is real but modest, and that's stated plainly rather than oversold: origination-time features carry limited signal for predicting recovery specifically, which is itself a genuine finding, not a shortcoming to hide. What this project demonstrates is a complete, defensible analytics lifecycle — from raw data to a business-ready recommendation — built and reasoned through end to end.

