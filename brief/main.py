"""
Brief generation service — Cloud Run entry point.

Accepts a POST /generate request from GCP Workflows, builds a vendor case
brief from BigQuery, generates HTML via Gemini on Vertex AI, and uploads
the result to Cloud Storage.

Authentication: Cloud Run IAM handles request authentication. Workflows calls
this service using OIDC — no unauthenticated requests are accepted at the
infrastructure level.
"""

import logging
import os
from datetime import datetime
from zoneinfo import ZoneInfo

from builder import build_case_brief, generate_case_brief_html
from flask import Flask, jsonify, request  # type: ignore
from google.cloud import storage
from google.cloud.exceptions import GoogleCloudError  # type: ignore

# GCS config — all sourced from environment, no credentials hardcoded (CWE-798)
GCS_BUCKET     = os.environ.get("GCS_BUCKET")
GCP_PROJECT_ID = os.environ.get("GCP_PROJECT_ID")

# Configure structured logging for Cloud Run (outputs JSON-compatible format)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def upload_html_to_gcs(html: str, vendor_number: str, timestamp: str) -> str:
    """Upload a case brief HTML string to Cloud Storage.

    Uses ADC — no credentials hardcoded (CWE-798).
    Raises EnvironmentError if GCS_BUCKET is not configured.
    """
    if not GCS_BUCKET:
        raise EnvironmentError(
            "GCS_BUCKET must be set in .env to upload to Cloud Storage."
        )

    gcs_client = storage.Client(project=GCP_PROJECT_ID)
    bucket = gcs_client.bucket(GCS_BUCKET)
    blob_name = f"briefs/{vendor_number}/case_brief_{vendor_number}_{timestamp}.html"
    bucket.blob(blob_name).upload_from_string(
        html, content_type="text/html; charset=utf-8"
    )

    uri = f"gs://{GCS_BUCKET}/{blob_name}"
    logger.info("Case brief uploaded to %s", uri)
    return uri


app = Flask(__name__)

MELBOURNE_TZ = ZoneInfo("Australia/Melbourne")


@app.route("/generate", methods=["POST"])
def generate():
    # Reject non-JSON requests early
    if not request.is_json:
        logger.warning("Rejected non-JSON request")
        return jsonify({"error": "Request must be JSON"}), 415

    payload = request.get_json(silent=True)
    if payload is None:
        return jsonify({"error": "Invalid JSON body"}), 400

    # Validate required field — vendor_id must be a non-empty string
    vendor_id = payload.get("vendor_id")
    if not vendor_id or not isinstance(vendor_id, str):
        return jsonify({"error": "vendor_id is required and must be a string"}), 400

    # Sanitise: strip whitespace, enforce max length to prevent abuse
    vendor_id = vendor_id.strip()[:128]
    logger.info("Received generate request for vendor_id=%s", vendor_id)

    try:
        # Step 1: query vendor_scores and assemble the case brief JSON
        brief = build_case_brief(vendor_id)
        brief["generated_at"] = datetime.now(tz=MELBOURNE_TZ).strftime("%-d %B %Y")

        # Step 2: send the JSON to Gemini on Vertex AI and get back HTML
        html = generate_case_brief_html(brief)

        # Step 3: upload HTML to Cloud Storage under briefs/<vendor_id>/
        ts = datetime.now(tz=MELBOURNE_TZ).strftime("%Y%m%dT%H%M%S")
        gcs_uri = upload_html_to_gcs(html, vendor_id, ts)

    except EnvironmentError as exc:
        logger.error("Configuration error: %s", exc)
        return jsonify({"error": "Service misconfigured"}), 500
    except GoogleCloudError as exc:
        logger.error("GCP error for vendor %s: %s", vendor_id, exc)
        return jsonify({"error": "GCP error"}), 502
    except Exception:  # noqa: BLE001 — catch-all for unexpected errors
        logger.exception("Unexpected error for vendor %s", vendor_id)
        return jsonify({"error": "Internal error"}), 500

    return jsonify(
        {
            "status": "ok",
            "vendor_id": vendor_id,
            "gcs_uri": gcs_uri,
        }
    ), 200


@app.route("/health", methods=["GET"])
def health():
    """Health check endpoint for Cloud Run."""
    return jsonify({"status": "healthy"}), 200


if __name__ == "__main__":
    # Local dev only — gunicorn is used in Cloud Run (see Dockerfile)
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port, debug=False)  # nosec — debug disabled
