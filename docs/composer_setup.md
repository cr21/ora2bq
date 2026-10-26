# Cloud Composer environment - setup, use, teardown

The ora2bq DAGs run on a Cloud Composer 3 environment. It is meant to be created on
demand and deleted when not in use, so every step is scripted.

| Setting | Value |
|---|---|
| Project | `project-5c016d48-80d5-4534-b69` |
| Region | `us-central1` |
| Environment | `ora2bq-composer` |
| Image | `composer-3-airflow-2.11.1-build.21` (Airflow 2.11) |
| Size | `small` |
| Service account | `ora2bq-composer@project-5c016d48-80d5-4534-b69.iam.gserviceaccount.com` |
| Env variables | `BQ_PROJECT`, `BQ_DATASET=orc_dataset`, `BQ_LOCATION=US` |

All of these live in [`infra/composer/composer.env`](../infra/composer/composer.env). Change them there, not in the scripts.

**Cost:** a small Composer 3 environment costs roughly **$12-15 per day** (about $350-450 per month) while it exists, even when idle. Delete it when you're done.

## Prerequisites

1. Install the gcloud CLI and log in:
   ```bash
   gcloud auth login
   gcloud auth application-default login     # used by tools/bq_utils.py
   gcloud config set project project-5c016d48-80d5-4534-b69
   ```
2. Your account needs `roles/owner`, or all of these: `roles/composer.admin`, `roles/iam.serviceAccountAdmin`, `roles/resourcemanager.projectIamAdmin`, `roles/serviceusage.serviceUsageAdmin`.
3. `curl` is needed (step 2 calls the Service Usage REST API, so the gcloud `beta` component is not required).

## Create the environment

```bash
infra/composer/setup_composer.sh
```

The script is idempotent. If it fails partway, fix the cause and run it again. It does the following:

| Step | What it does | Manual equivalent |
|---|---|---|
| 1 | Enables the Composer, BigQuery and Storage APIs | `gcloud services enable composer.googleapis.com bigquery.googleapis.com storage.googleapis.com` |
| 2 | Makes sure the Composer service agent `service-<PROJECT_NUMBER>@cloudcomposer-accounts.iam.gserviceaccount.com` exists | `gcloud beta services identity create --service=composer.googleapis.com` (the script uses the equivalent REST call) |
| 3 | Creates the service account `ora2bq-composer` | `gcloud iam service-accounts create ora2bq-composer` |
| 4 | Grants project roles to the service account: `composer.worker` (run Airflow), `bigquery.jobUser` (run queries and CALLs), `bigquery.dataEditor` (read and write tables, run routines) | `gcloud projects add-iam-policy-binding ... --role <role>` |
| 5 | Grants the Composer service agent `roles/composer.ServiceAgentV2Ext` on the service account, which Composer 2 and 3 require | `gcloud iam service-accounts add-iam-policy-binding <SA> --member serviceAccount:<agent> --role roles/composer.ServiceAgentV2Ext` |
| 6 | Creates the environment (~25 minutes) | see the `gcloud composer environments create` command in the script |
| 7 | Prints the state, the DAG bucket and the Airflow UI URL | `gcloud composer environments describe ...` |

To watch progress from another terminal:
```bash
gcloud composer operations list --locations us-central1 --filter="metadata.resource~ora2bq-composer"
```

### Choosing a different image version

```bash
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://composer.googleapis.com/v1/projects/project-5c016d48-80d5-4534-b69/locations/us-central1/imageVersions?pageSize=200" \
  | python3 -c "import json,sys; [print(v['imageVersionId']) for v in json.load(sys.stdin)['imageVersions'] if v['imageVersionId'].startswith('composer-3')]"
```
Put the chosen version in `IMAGE_VERSION` in `composer.env`. Older gcloud releases have no `gcloud composer images list` command, which is why this uses the REST API.

## Verify the environment

```bash
source infra/composer/composer.env
gcloud composer environments describe $ENV_NAME --location $REGION \
  --format="value(state,config.dagGcsPrefix,config.airflowUri)"
```
`state` should be `RUNNING`. Open `airflowUri` in a browser to reach the Airflow UI. It uses your Google login.

## Deploy a DAG

```bash
infra/composer/deploy_dag.sh dags/<proc>_daily.py
```
This uploads the file to the environment's `dags/` bucket, waits up to 5 minutes for Airflow to register it, and prints any import errors.

Useful Airflow CLI commands, run through gcloud:
```bash
source infra/composer/composer.env
R="gcloud composer environments run $ENV_NAME --location $REGION"
$R dags list
$R dags list-import-errors
$R dags unpause -- <dag_id>
$R dags trigger -- <dag_id>
$R dags list-runs -- -d <dag_id>
```

## Delete the environment

```bash
infra/composer/teardown_composer.sh
```
This deletes the environment (~10 minutes) and its GCS bucket. DAG files live in git under `dags/`, so nothing is lost. The service account and its IAM bindings are kept because they cost nothing. After recreating the environment, redeploy the DAGs:
```bash
for f in dags/*.py; do infra/composer/deploy_dag.sh "$f"; done
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Cloud Composer Service Agent ... does not have required permissions` during create | Step 5 hasn't taken effect yet. Wait 1-2 minutes and rerun the script. |
| Create fails with a quota error | Check the `us-central1` quotas for CPUs and IP addresses, or switch `REGION`. |
| A DAG task fails with `Access Denied: ... bigquery.routines.get` | The environment service account is missing `bigquery.dataEditor`. Rerun step 4. |
| `Not found: Dataset ... was not found in location` | Pass `location="US"` (`BQ_LOCATION`) to `BigQueryInsertJobOperator`. |
