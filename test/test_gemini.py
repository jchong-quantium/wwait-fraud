from google import genai

client = genai.Client(
    vertexai=True, project="agentic-platforms-sandbox", location="us-central1"
)

response = client.models.generate_content(model="gemini-2.5-flash", contents="Hello")

print(response.text)
