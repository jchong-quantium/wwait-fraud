# Fraud Detection Pipeline

AI-assisted vendor fraud detection pipeline for Woolworths Group procurement data. The pipeline ingests data from SAP, Ariba, and Maximo, builds vendor-level risk features, scores vendors by fraud risk, and generates AI case briefs for investigators using Gemini.

## Architecture

![Architecture](docs/image.webp)

The pipeline is orchestrated by GCP Workflows and runs in three stages:

1. **BigQuery**: SQL pipeline refreshes vendor data, features, triage scores, and case brief inputs
2. **Cloud Run**: calls Gemini to generate an HTML case brief per high-risk vendor
3. **Cloud Storage**: stores generated HTML briefs
4. **Looker Studio**: dashboard for investigators to view vendor risk summaries

## Repo Structure

```
├── sql/
│   ├── views/          # Input views over source datasets (Ariba, SAP)
│   └── pipeline/       # BigQuery pipeline tables — run in this order:
│       ├── vendor_attributes.sql
│       ├── employee_attributes.sql
│       ├── base_transaction.sql
│       ├── vendor_features.sql
├── brief/              # Cloud Run service — generates HTML case briefs via Gemini
├── workflows/          # GCP Workflows pipeline definition
├── routines/           # Existing risk team P2P control check views (reference only)
├── scripts/            # Deployment and utility scripts
├── test/               # Connectivity tests
└── docs/               # Architecture diagram
```

## Prerequisites

- GCP project: `agentic-platforms-sandbox` (Gemini/Workflows) and `gcp-wow-groupit-bizwear-dev` (BigQuery)
- [gcloud CLI](https://cloud.google.com/sdk/docs/install) authenticated
- Python 3.11+
- Docker (for Cloud Run builds)

## Setup

```bash
# 1. Copy and fill in environment variables
cp .env.example .env

# 2. Authenticate with GCP
gcloud auth application-default login

# 3. Install Python dependencies
pip install -r requirements.txt
```

## Environment Variables

See `.env.example` for the full list. Key variables:

| Variable         | Description                                |
| ---------------- | ------------------------------------------ |
| `GCP_PROJECT_ID` | Billing project for BigQuery jobs          |
| `GCP_LOCATION`   | GCP region (e.g. `australia-southeast1`)   |
| `BQ_DATASET`     | Target BigQuery dataset (e.g. `fraud_dev`) |
| `CLOUD_RUN_URL`  | Deployed Cloud Run service URL             |
| `GEMINI_MODEL`   | Gemini model (e.g. `gemini-2.5-flash`)     |
| `GCS_BUCKET`     | Cloud Storage bucket for HTML briefs       |

## Running Locally

Use `run_pipeline.py` to run the full pipeline with your personal ADC credentials. This is the development path while Workflows service account access to enterprise source datasets is being provisioned.

```bash
python3 scripts/run_pipeline.py
```

This runs each SQL file in `sql/pipeline/` in sequence, then triggers the Cloud Run brief generation service.

## Deployment

### Deploy Cloud Run (brief generation service)

```bash
bash scripts/deploy_brief.sh
```

### Upload SQL files to Cloud Storage

Required for the Workflows pipeline to read SQL at runtime.

```bash
bash scripts/deploy_sql.sh
```

### Deploy Workflow

```bash
bash scripts/deploy_workflow.sh
```

### Execute Workflow (console)

Go to **GCP Console → Workflows → fraud-pipeline → Execute** with:

```json
{
  "project_id": "gcp-wow-groupit-bizwear-dev",
  "bucket": "fraud-pipeline-dev",
  "location": "australia-southeast1"
}
```

## Testing Connectivity

```bash
# Test BigQuery source dataset access
python3 test/test_bigquery.py

# Test Gemini access
python3 test/test_gemini.py
```
