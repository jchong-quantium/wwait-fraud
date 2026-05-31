import os
import sys

from dotenv import load_dotenv  # type: ignore
from google import genai  # type: ignore

load_dotenv()

GCP_PROJECT_ID = os.environ.get("GCP_PROJECT_ID")
GCP_LOCATION = os.environ.get("GCP_LOCATION")
GEMINI_MODEL = os.environ.get("GEMINI_MODEL")

if not GCP_PROJECT_ID or not GCP_LOCATION or not GEMINI_MODEL:
    sys.exit("Missing GCP_PROJECT_ID, GCP_LOCATION or GEMINI_MODEL in .env")

client = genai.Client(vertexai=True, project=GCP_PROJECT_ID, location=GCP_LOCATION)

response = client.models.generate_content(model=GEMINI_MODEL, contents="Hello")
print(response.text)
