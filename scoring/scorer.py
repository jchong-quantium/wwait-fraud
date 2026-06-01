"""
scorer.py — Shared BigQuery helpers for the scoring pipeline.

Used by transaction_scorer.py (transaction-level) and future vendor_scorer.py
(vendor-level). Keeps BQ client creation and I/O in one place.

Authentication: Application Default Credentials (ADC) — no credentials
hardcoded (CWE-798).
"""

import logging
import os

import pandas as pd
from google.cloud import bigquery
from google.cloud.exceptions import GoogleCloudError  # noqa: F401 — re-exported

logger = logging.getLogger(__name__)


def bq_client() -> bigquery.Client:
    """Return a BigQuery client using ADC — no credentials passed explicitly."""
    project = os.environ.get("GCP_PROJECT_ID")
    location = os.environ.get("BQ_LOCATION")
    return bigquery.Client(project=project, location=location)


def read_table(
    client: bigquery.Client,
    project: str,
    dataset: str,
    table: str,
    columns: list[str] | None = None,
    where: str | None = None,
) -> pd.DataFrame:
    """Read a BigQuery table into a DataFrame.

    Table and column names are hardcoded constants in callers — not
    user-supplied — so there is no SQL injection risk (CWE-89).
    The optional where clause is also caller-controlled (no user input).

    Args:
        client:  BigQuery client.
        project: GCP project ID.
        dataset: BigQuery dataset name.
        table:   Table name — must be a hardcoded constant, not user input.
        columns: Optional list of column names to select (SELECT * if None).
        where:   Optional WHERE clause string — must be a hardcoded constant.

    Returns:
        DataFrame with query results.
    """
    col_clause = ", ".join(columns) if columns else "*"
    # Backtick-quoted fully-qualified table ref — not user-supplied (CWE-89)
    fqt = f"`{project}.{dataset}.{table}`"
    sql = f"SELECT {col_clause} FROM {fqt}"
    if where:
        sql += f" WHERE {where}"

    logger.info("Reading %s.%s.%s ...", project, dataset, table)
    df = client.query(sql).to_dataframe()
    logger.info("  → %s rows × %s cols", f"{len(df):,}", len(df.columns))
    return df


def write_scores(
    client: bigquery.Client,
    df: pd.DataFrame,
    project: str,
    dataset: str,
    table: str,
) -> None:
    """Write a scores DataFrame to BigQuery, replacing any existing data.

    Uses WRITE_TRUNCATE — each pipeline run produces a full refresh.
    Schema is inferred from the DataFrame; types must match the BQ table.

    Args:
        client:  BigQuery client.
        df:      DataFrame to write.
        project: GCP project ID.
        dataset: BigQuery dataset name.
        table:   Destination table name.
    """
    destination = f"{project}.{dataset}.{table}"
    job_config = bigquery.LoadJobConfig(
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
        # Autodetect is off — schema is defined in transaction_scores.sql (CWE-20)
        autodetect=False,
        schema=[
            bigquery.SchemaField("transaction_id", "STRING"),
            bigquery.SchemaField("vendor_number", "STRING"),
            bigquery.SchemaField("cost_centre", "STRING"),
            bigquery.SchemaField("anomaly_score", "FLOAT64"),
            bigquery.SchemaField("is_anomaly", "BOOL"),
            bigquery.SchemaField("top_driver_feature", "STRING"),
            bigquery.SchemaField("top_driver_shap", "FLOAT64"),
            bigquery.SchemaField("model_version", "STRING"),
            bigquery.SchemaField("scored_at", "TIMESTAMP"),
        ],
    )

    logger.info("Writing %s rows to %s ...", f"{len(df):,}", destination)
    job = client.load_table_from_dataframe(df, destination, job_config=job_config)
    job.result()
    logger.info("  → Write complete")
