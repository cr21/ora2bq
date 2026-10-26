#!/usr/bin/env bash
# Upload a DAG file to the Composer environment and wait until Airflow has parsed it.
#
# Usage: infra/composer/deploy_dag.sh dags/<proc>_daily.py
set -euo pipefail

source "$(dirname "$0")/composer.env"

DAG_FILE="${1:?usage: deploy_dag.sh dags/<file>.py}"
DAG_ID=$(basename "$DAG_FILE" .py)

gcloud composer environments storage dags import \
  --environment "$ENV_NAME" --location "$REGION" --project "$PROJECT_ID" --source "$DAG_FILE"

echo "==> Waiting for Airflow to pick up $DAG_ID (up to 5 minutes)"
for _ in $(seq 1 20); do
  if gcloud composer environments run "$ENV_NAME" --location "$REGION" --project "$PROJECT_ID" \
       dags list -- --output plain 2>/dev/null | grep -qw "$DAG_ID"; then
    echo "    $DAG_ID is registered"
    gcloud composer environments run "$ENV_NAME" --location "$REGION" --project "$PROJECT_ID" \
      dags list-import-errors 2>/dev/null || true
    exit 0
  fi
  sleep 15
done

echo "$DAG_ID did not appear; check import errors:" >&2
gcloud composer environments run "$ENV_NAME" --location "$REGION" --project "$PROJECT_ID" \
  dags list-import-errors >&2 || true
exit 1
