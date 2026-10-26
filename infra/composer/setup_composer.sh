#!/usr/bin/env bash
# Create the ora2bq Cloud Composer 3 environment from scratch.
# Every step is safe to re-run: existing resources are left as they are.
#
# Usage: infra/composer/setup_composer.sh
set -euo pipefail

source "$(dirname "$0")/composer.env"

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
COMPOSER_AGENT="service-${PROJECT_NUMBER}@cloudcomposer-accounts.iam.gserviceaccount.com"

echo "==> 1. Enable required APIs"
gcloud services enable composer.googleapis.com bigquery.googleapis.com storage.googleapis.com \
  --project "$PROJECT_ID"

echo "==> 2. Make sure the Composer service agent exists"
# Same as `gcloud beta services identity create`, without needing the beta component
curl -sf -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://serviceusage.googleapis.com/v1beta1/projects/${PROJECT_NUMBER}/services/composer.googleapis.com:generateServiceIdentity" \
  >/dev/null

echo "==> 3. Create the environment service account"
if ! gcloud iam service-accounts describe "$SA_EMAIL" --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$SA_NAME" --project "$PROJECT_ID" \
    --display-name "ora2bq Composer environment"
fi

echo "==> 4. Grant project roles to the service account"
for role in roles/composer.worker roles/bigquery.jobUser roles/bigquery.dataEditor; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member "serviceAccount:${SA_EMAIL}" --role "$role" --condition=None >/dev/null
  echo "    granted $role"
done

echo "==> 5. Let the Composer service agent act for the service account"
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" --project "$PROJECT_ID" \
  --member "serviceAccount:${COMPOSER_AGENT}" --role roles/composer.ServiceAgentV2Ext >/dev/null

echo "==> 6. Create the Composer environment (takes ~25 minutes)"
if gcloud composer environments describe "$ENV_NAME" --location "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "    $ENV_NAME already exists"
else
  gcloud composer environments create "$ENV_NAME" \
    --project "$PROJECT_ID" \
    --location "$REGION" \
    --image-version "$IMAGE_VERSION" \
    --environment-size "$ENV_SIZE" \
    --service-account "$SA_EMAIL" \
    --env-variables "BQ_PROJECT=${PROJECT_ID},BQ_DATASET=${BQ_DATASET},BQ_LOCATION=${BQ_LOCATION}" \
    --labels "app=ora2bq"
fi

echo "==> 7. Environment details"
gcloud composer environments describe "$ENV_NAME" --location "$REGION" --project "$PROJECT_ID" \
  --format="table(state,config.dagGcsPrefix,config.airflowUri)"
