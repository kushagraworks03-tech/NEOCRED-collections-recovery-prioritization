import streamlit as st
import pandas as pd
import joblib

# Load saved artifacts
model = joblib.load('recovery_xgb_model.pkl')
model_columns = joblib.load('model_columns.pkl')
reference_data = joblib.load('reference_data.pkl')

st.set_page_config(page_title="NeoCred Recovery Prioritization", layout="centered")
st.title("📊 Collections Recovery Prioritization Tool")
st.write("Estimate recovery likelihood and prioritization tier for a charged-off loan.")

st.header("Loan Details")

col1, col2 = st.columns(2)

with col1:
    grade = st.selectbox("Loan Grade", reference_data['grades'])
    purpose = st.selectbox("Loan Purpose", reference_data['purposes'])
    home_ownership = st.selectbox("Home Ownership", reference_data['home_ownership_types'])
    term = st.selectbox("Term (months)", [36, 60])

with col2:
    loan_amnt = st.number_input("Loan Amount (₹)", min_value=1000, max_value=100000, value=15000, step=500)
    annual_inc = st.number_input("Annual Income (₹)", min_value=0, max_value=1000000, value=60000, step=1000)
    dti = st.slider("Debt-to-Income Ratio (DTI)", 0.0, 50.0, 18.0)
    fico_avg = st.slider("FICO Score (avg)", 600, 850, 700)

col3, col4 = st.columns(2)
with col3:
    emp_length = st.slider("Employment Length (years)", 0, 10, 5)
with col4:
    credit_history_years = st.slider("Credit History Length (years)", 0.0, 40.0, 10.0)

duration_months = st.slider("Months Survived Before Charge-Off", 0, 66, 15)

# -------------------------------------------------
#  Build the model input row (handles one-hot encoding behind the scenes)
# -------------------------------------------------
if st.button("Predict Recovery Likelihood"):

    # Start with all zeros for every column the model expects
    input_row = {col: 0 for col in model_columns}

    # Fill numeric fields directly
    input_row['dti'] = dti
    input_row['fico_avg'] = fico_avg
    input_row['loan_amnt'] = loan_amnt
    input_row['term'] = term
    input_row['emp_length'] = emp_length
    input_row['annual_inc'] = annual_inc
    input_row['credit_history_years'] = credit_history_years
    input_row['duration_months'] = duration_months

    # Flip the correct one-hot column, if it exists (baseline categories simply stay 0)
    grade_col = f'grade_{grade}'
    if grade_col in input_row:
        input_row[grade_col] = 1

    purpose_col = f'purpose_{purpose}'
    if purpose_col in input_row:
        input_row[purpose_col] = 1

    home_col = f'home_ownership_{home_ownership}'
    if home_col in input_row:
        input_row[home_col] = 1

    # Build a single-row DataFrame in the exact column order the model expects
    X_input = pd.DataFrame([input_row])[model_columns]

    # Predict
    recovery_prob = model.predict_proba(X_input)[0, 1]

    # Compute Recovery Value Score using loan amount as the exposure proxy
    # (for a new/hypothetical loan, there is no historical charged-off balance yet)
    chargedoff_balance_est = loan_amnt
    recovery_value_score = recovery_prob * chargedoff_balance_est

    # Priority tier thresholds (from the 50th/80th percentile of the historical
    # recovery_probability distribution computed in the notebook)
    if recovery_prob >= 0.565:
        tier = "🔴 High Priority"
    elif recovery_prob >= 0.456:
        tier = "🟡 Medium Priority"
    else:
        tier = "🟢 Low Priority"

    st.header("Results")
    st.metric("Recovery Probability", f"{recovery_prob:.1%}")
    st.metric("Estimated Recovery Value Score", f"₹{recovery_value_score:,.0f}")
    st.metric("Priority Tier", tier)

    st.caption("Note: Priority tier thresholds are based on the recovery probability distribution "
               "observed across NeoCred's historical charged-off loan portfolio.")
