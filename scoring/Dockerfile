FROM python:3.11-slim

# Run as non-root user — reduces blast radius if container is compromised
RUN useradd -m -u 1000 appuser

WORKDIR /app

# Install dependencies before copying app code — improves Docker layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

USER appuser

# Cloud Run Job: runs to completion and exits (no HTTP server needed)
CMD ["python", "transaction_scorer.py"]