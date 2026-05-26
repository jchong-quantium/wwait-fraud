FROM python:3.11-slim

# Run as non-root user — reduces blast radius if container is compromised
RUN useradd -m -u 1000 appuser

WORKDIR /app

# Install dependencies before copying app code — improves Docker layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

USER appuser

# Cloud Run expects the container to listen on PORT (default 8080)
EXPOSE 8080

# gunicorn: 1 worker + 8 threads suits Cloud Run's single-instance concurrency model
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "8", "--timeout", "0", "main:app"]