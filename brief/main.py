"""
Brief generation service — Cloud Run entry point.

Skeleton: accepts a POST request from GCP Workflows, validates the payload,
and returns 200 OK. Gemini and BigQuery logic to be added once the pipeline
wiring is confirmed end-to-end.

Authentication: Cloud Run IAM handles request authentication. Workflows calls
this service using OIDC — no unauthenticated requests are accepted at the
infrastructure level.
"""

import logging
import os

from flask import Flask, jsonify, request

# Configure structured logging for Cloud Run (outputs JSON-compatible format)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)


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

    # TODO: read case brief inputs from BigQuery
    # TODO: call Gemini to generate brief
    # TODO: render HTML and write to Cloud Storage

    return jsonify({
        "status": "ok",
        "vendor_id": vendor_id,
        "message": "Brief generation placeholder — pipeline wiring confirmed",
    }), 200


@app.route("/health", methods=["GET"])
def health():
    """Health check endpoint for Cloud Run."""
    return jsonify({"status": "healthy"}), 200


if __name__ == "__main__":
    # Local dev only — gunicorn is used in Cloud Run (see Dockerfile)
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port, debug=False)  # nosec — debug disabled