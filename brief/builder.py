"""
builder.py — AI Case Brief assembler for fraud investigation triage.

Reads one row per vendor from vendor_scores (a pre-aggregated pipeline table)
and assembles a flat JSON payload, then generates an HTML investigation report
via Gemini on Vertex AI.

Data source:
    vendor_scores — pre-aggregated brief inputs, one row per vendor.
                    Includes anomaly scores, binary flags, exposure,
                    peer comparison metrics, and top transactions (JSON).
                    Built by sql/pipeline/vendor_scores.sql.

Usage:
    # CLI — generates brief for top-ranked vendor by anomaly score
    python3 brief/builder.py

    # CLI — specific vendor
    python3 brief/builder.py <vendor_number>

    # Programmatic
    from brief.builder import build_case_brief, build_and_generate
    brief = build_case_brief("V12345")
    html  = build_and_generate("V12345")

Authentication:
    Uses Application Default Credentials (ADC) or GOOGLE_APPLICATION_CREDENTIALS.
    No credentials are hardcoded (CWE-798).

Configuration (all via .env or environment):
    GCP_PROJECT_ID  — GCP project for BigQuery client
    BQ_DATASET      — BigQuery dataset containing pipeline tables
    GCP_LOCATION    — Vertex AI region
    GEMINI_MODEL    — Gemini model ID
"""

import json
import logging
import os
import sys
from datetime import date, datetime
from zoneinfo import ZoneInfo
from decimal import Decimal
from pathlib import Path

from dotenv import load_dotenv  # type: ignore
from google import genai
from google.cloud import bigquery
from google.genai.types import HttpOptions  # type: ignore

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)

# Config — all sourced from environment, no credentials hardcoded (CWE-798)
load_dotenv()

GCP_PROJECT_ID = os.environ.get("GCP_PROJECT_ID")
BQ_DATASET = os.environ.get("BQ_DATASET")
GCP_LOCATION = os.environ.get("GCP_LOCATION")
BQ_LOCATION = os.environ.get("BQ_LOCATION")
GEMINI_MODEL = os.environ.get("GEMINI_MODEL")

# Path constructed from a known constant — not user-supplied (CWE-22)
PROMPTS_DIR = Path(__file__).parent / "prompts"
MELBOURNE_TZ = ZoneInfo("Australia/Melbourne")

# ── Config / BQ helpers ───────────────────────────────────────────────────────


def _require_config() -> None:
    missing = [v for v in ("GCP_PROJECT_ID", "BQ_DATASET") if not os.environ.get(v)]
    if missing:
        raise EnvironmentError(
            f"Required environment variables not set: {', '.join(missing)}. "
            "Copy .env.example to .env and populate the values."
        )


def _bq_client() -> bigquery.Client:
    return bigquery.Client(project=GCP_PROJECT_ID, location=BQ_LOCATION)


def _table(name: str) -> str:
    # Table names are hardcoded constants — not user-supplied (CWE-89)
    return f"`{GCP_PROJECT_ID}.{BQ_DATASET}.{name}`"


# ── Row conversion ────────────────────────────────────────────────────────────


def _to_python(val):
    """Recursively convert BQ Row objects to plain Python types.

    BQ returns STRUCT columns as Row objects and ARRAY<STRUCT> as lists of Row
    objects — neither is JSON-serialisable by default. This converts them to
    plain dicts/lists so json.dumps works without a custom encoder.
    """
    if hasattr(val, "keys"):  # STRUCT → dict
        return {k: _to_python(v) for k, v in val.items()}
    if isinstance(val, list):  # ARRAY → list
        return [_to_python(item) for item in val]
    if isinstance(val, (date, datetime)):  # DATE/TIMESTAMP → ISO string
        return val.isoformat()
    if isinstance(val, Decimal):  # NUMERIC → float
        return float(val)
    return val


# ── Data loading ──────────────────────────────────────────────────────────────


def load_vendor_scores(
    vendor_number: str,
    client: bigquery.Client,
) -> dict | None:
    """Load one row from vendor_scores for the given vendor.

    Returns None if the vendor is not found.
    Raises GoogleCloudError on BQ failure.
    """
    # Parameterised query — prevents SQL injection (CWE-89)
    sql = (
        f"SELECT * FROM {_table('vendor_scores')} "
        "WHERE vendor_number = @vendor_number "
        "LIMIT 1"
    )
    params = [bigquery.ScalarQueryParameter("vendor_number", "STRING", vendor_number)]
    rows = list(
        client.query(
            sql, job_config=bigquery.QueryJobConfig(query_parameters=params)
        ).result()
    )
    return _to_python(rows[0]) if rows else None


def select_top_vendors(top_n: int, client: bigquery.Client) -> list[str]:
    """Return the top N vendor_numbers ranked by anomaly_score descending."""
    # Parameterised query — top_n is internal but parameterised for safety (CWE-89)
    sql = (
        f"SELECT vendor_number FROM {_table('vendor_scores')} "
        "ORDER BY anomaly_score DESC "
        "LIMIT @top_n"
    )
    params = [bigquery.ScalarQueryParameter("top_n", "INT64", top_n)]
    rows = client.query(
        sql, job_config=bigquery.QueryJobConfig(query_parameters=params)
    ).result()
    return [row["vendor_number"] for row in rows]


# ── Main assembly ─────────────────────────────────────────────────────────────


def build_case_brief(
    vendor_number: str,
    client: bigquery.Client | None = None,
) -> dict:
    """Assemble a case brief for a single vendor from vendor_scores.

    Returns the vendor_scores row as a flat JSON-serialisable dict with JSON
    string columns parsed into Python objects.

    Raises:
        EnvironmentError: if GCP_PROJECT_ID or BQ_DATASET are not set.
        ValueError: if vendor_number is empty or not found in vendor_scores.
        GoogleCloudError: if the BigQuery query fails.
    """
    _require_config()

    if not isinstance(vendor_number, str) or not vendor_number.strip():
        raise ValueError(
            f"vendor_number must be a non-empty string, got: {vendor_number!r}"
        )

    vn = vendor_number.strip()
    logger.info("Building case brief for vendor %s", vn)

    if client is None:
        client = _bq_client()

    vs = load_vendor_scores(vn, client)
    if vs is None:
        raise ValueError(
            f"Vendor {vn!r} not found in vendor_scores — run the pipeline first."
        )

    return vs


def build_batch(vendor_numbers: list[str]) -> list[dict]:
    """Build case briefs for a list of vendor_numbers, sharing one BQ client."""
    _require_config()
    client = _bq_client()
    briefs: list[dict] = []

    for vn in vendor_numbers:
        try:
            briefs.append(build_case_brief(vn, client=client))
        except Exception as exc:
            logger.error("Failed to build brief for vendor %s: %s", vn, exc)
            briefs.append({"vendor_number": vn, "error": str(exc)})

    return briefs


# ── LLM integration ───────────────────────────────────────────────────────────

_SYSTEM_PROMPT_CACHE: str | None = None
_GENAI_CLIENT_CACHE: genai.Client | None = None


def _load_system_prompt() -> str:
    """Load and cache the system prompt + HTML template from brief/prompts/.

    Reads files once on first call; returns cached string on subsequent calls.
    Raises FileNotFoundError if either file is missing.
    """
    global _SYSTEM_PROMPT_CACHE
    if _SYSTEM_PROMPT_CACHE is not None:
        return _SYSTEM_PROMPT_CACHE

    # Paths constructed from a known constant directory — not user-supplied (CWE-22)
    prompt_path = PROMPTS_DIR / "prompt.md"
    template_path = PROMPTS_DIR / "template.html"

    for path in (prompt_path, template_path):
        if not path.exists():
            raise FileNotFoundError(
                f"Required prompt file not found: {path}\n"
                "Ensure both brief/prompts/prompt.md and "
                "brief/prompts/template.html exist."
            )

    _SYSTEM_PROMPT_CACHE = (
        prompt_path.read_text(encoding="utf-8")
        + "\n\n### HTML Template\n\n"
        + template_path.read_text(encoding="utf-8")
    )
    return _SYSTEM_PROMPT_CACHE


def generate_case_brief_html(vendor_json: dict) -> str:
    """Generate a 5-section HTML investigation report via Gemini on Vertex AI."""
    missing = [v for v in ("GCP_PROJECT_ID", "GEMINI_MODEL") if not os.environ.get(v)]
    if missing:
        raise EnvironmentError(
            f"Required environment variables not set: {', '.join(missing)}. "
            "Copy .env.example to .env and populate the values."
        )

    system_prompt = _load_system_prompt()
    vendor_json_str = json.dumps(vendor_json, indent=2, default=str)

    global _GENAI_CLIENT_CACHE
    if _GENAI_CLIENT_CACHE is None:
        # 5-minute timeout guards against hung Cloud Run requests
        _GENAI_CLIENT_CACHE = genai.Client(
            vertexai=True,
            project=GCP_PROJECT_ID,
            location=GCP_LOCATION,
            http_options=HttpOptions(timeout=300_000),
        )
    client = _GENAI_CLIENT_CACHE

    contents = (
        f"{system_prompt}\n\n---\n\n"
        f"## Case Brief JSON\n\n```json\n{vendor_json_str}\n```"
    )

    logger.info(
        "Sending case brief for vendor %s to %s (Vertex AI, %s)",
        vendor_json.get("vendor_number", "unknown"),
        GEMINI_MODEL,
        GCP_LOCATION,
    )

    response = client.models.generate_content(model=GEMINI_MODEL, contents=contents)
    return response.text


def build_and_generate(vendor_number: str) -> str:
    """End-to-end: build case brief JSON then generate HTML via Gemini."""
    return generate_case_brief_html(build_case_brief(vendor_number))


# ── CLI ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    """
    Usage:
        python3 brief/builder.py                  # top vendor by anomaly score
        python3 brief/builder.py <vendor_number>  # specific vendor
    """
    _require_config()
    client = _bq_client()

    if len(sys.argv) > 1:
        # Sanitise CLI argument — strip whitespace, cap length (CWE-20)
        target_vendor = sys.argv[1].strip()[:128]
        if not target_vendor:
            sys.exit("ERROR: vendor_number argument is empty")
        logger.info("Using supplied vendor_number: %s", target_vendor)
    else:
        logger.info("No vendor_number supplied — selecting top vendor by anomaly score")
        top = select_top_vendors(1, client)
        if not top:
            sys.exit("ERROR: vendor_scores is empty — run the pipeline first.")
        target_vendor = top[0]
        logger.info("Auto-selected vendor %s", target_vendor)

    brief = build_case_brief(target_vendor, client=client)
    now = datetime.now(tz=MELBOURNE_TZ)
    brief["generated_at"] = now.strftime("%-d %B %Y")

    ts = now.strftime("%Y%m%dT%H%M%S")
    output_dir = Path(__file__).parent / "output"
    output_dir.mkdir(exist_ok=True)

    json_path = output_dir / f"case_brief_{target_vendor}_{ts}.json"
    json_path.write_text(json.dumps(brief, indent=2, default=str), encoding="utf-8")
    logger.info("Case brief JSON saved to %s", json_path)

    logger.info("Generating HTML report via Gemini...")
    html = generate_case_brief_html(brief)
    html_path = output_dir / f"case_brief_{target_vendor}_{ts}.html"
    html_path.write_text(html, encoding="utf-8")
    logger.info("Case brief HTML saved to %s", html_path)
