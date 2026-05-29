import os
import sys

from dotenv import load_dotenv
from google import genai

load_dotenv()

GCP_PROJECT_ID = os.environ.get("GCP_PROJECT_ID")
GCP_LOCATION = os.environ.get("GCP_LOCATION")

if not GCP_PROJECT_ID or not GCP_LOCATION:
    sys.exit("Missing GCP_PROJECT_ID or GCP_LOCATION in .env")

client = genai.Client(
    vertexai=True, project=GCP_PROJECT_ID, location=GCP_LOCATION
)

response = client.models.generate_content(model="gemini-2.5-flash", contents="Hello")
print(response.text)