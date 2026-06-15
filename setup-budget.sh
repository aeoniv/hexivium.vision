#!/usr/bin/env bash
# ============================================================================
# Qi Pipeline Director — Billing Budget Guardrail (one-time, idempotent)
# ============================================================================
# Creates a monthly budget with email alerts at 50/90/100% of the cap so a
# runaway VM can't quietly rack up charges. Safe to re-run: it updates the
# existing budget of the same display name instead of creating duplicates.
#
# PREREQUISITES:
#   • gcloud authenticated with Billing Account Administrator on the account
#   • Billing budgets API enabled:
#       gcloud services enable billingbudgets.googleapis.com --project=PROJECT_ID
# ============================================================================

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-hexivium-vision}"
BUDGET_NAME="${BUDGET_NAME:-qi-pipeline-monthly-cap}"
BUDGET_AMOUNT="${BUDGET_AMOUNT:-50}"          # USD per month
CURRENCY="${CURRENCY:-USD}"

# ── Resolve the billing account linked to the project ───────────────────────
BILLING_ACCOUNT="${BILLING_ACCOUNT:-$(gcloud billing projects describe "${PROJECT_ID}" \
    --format='value(billingAccountName)' | sed 's#billingAccounts/##')}"

if [ -z "${BILLING_ACCOUNT}" ]; then
    echo "[!] No billing account linked to project ${PROJECT_ID}. Set BILLING_ACCOUNT explicitly." >&2
    exit 1
fi

echo "[*] Project:         ${PROJECT_ID}"
echo "[*] Billing account: ${BILLING_ACCOUNT}"
echo "[*] Monthly cap:     ${BUDGET_AMOUNT} ${CURRENCY}"

# ── Find an existing budget by display name (idempotency) ───────────────────
EXISTING=$(gcloud billing budgets list \
    --billing-account="${BILLING_ACCOUNT}" \
    --filter="displayName=${BUDGET_NAME}" \
    --format="value(name)" 2>/dev/null | head -1 || true)

COMMON_ARGS=(
    --display-name="${BUDGET_NAME}"
    --budget-amount="${BUDGET_AMOUNT}${CURRENCY}"
    --filter-projects="projects/${PROJECT_ID}"
    --threshold-rule=percent=0.5
    --threshold-rule=percent=0.9
    --threshold-rule=percent=1.0
)

if [ -n "${EXISTING}" ]; then
    echo "[*] Updating existing budget: ${EXISTING}"
    gcloud billing budgets update "${EXISTING}" \
        --billing-account="${BILLING_ACCOUNT}" \
        "${COMMON_ARGS[@]}"
else
    echo "[*] Creating new budget: ${BUDGET_NAME}"
    gcloud billing budgets create \
        --billing-account="${BILLING_ACCOUNT}" \
        "${COMMON_ARGS[@]}"
fi

echo ""
echo "[✓] Budget configured. Alerts fire at 50%, 90%, and 100% of ${BUDGET_AMOUNT} ${CURRENCY}/mo."
echo "    Default recipients = Billing Account Admins & users. To add Pub/Sub or"
echo "    custom email channels, attach a notification channel in the Cloud Console."
