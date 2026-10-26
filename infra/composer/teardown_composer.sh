#!/usr/bin/env bash
# Delete the ora2bq Composer environment and its leftover bucket to stop billing.
# The service account and IAM bindings are kept (they are free) so setup is faster next time.
#
# Usage: infra/composer/teardown_composer.sh
set -euo pipefail

source "$(dirname "$0")/composer.env"

BUCKET=$(gcloud composer environments describe "$ENV_NAME" --location "$REGION" --project "$PROJECT_ID" \
  --format="value(config.dagGcsPrefix)" 2>/dev/null | sed -E 's#^(gs://[^/]+)/.*#\1#' || true)

echo "==> Deleting environment $ENV_NAME (takes ~10 minutes)"
gcloud composer environments delete "$ENV_NAME" --location "$REGION" --project "$PROJECT_ID" --quiet

# Composer does not delete its bucket; DAG files live in git, so it is safe to remove
if [[ -n "$BUCKET" ]]; then
  echo "==> Deleting environment bucket $BUCKET"
  gcloud storage rm --recursive "$BUCKET" --project "$PROJECT_ID"
fi

echo "Done. Recreate with infra/composer/setup_composer.sh"
