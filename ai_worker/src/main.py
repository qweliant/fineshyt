import base64
import os
from fastapi import FastAPI, UploadFile, File, HTTPException
from pydantic import BaseModel, Field
from openai import AsyncOpenAI
import instructor
from dotenv import load_dotenv

load_dotenv()

# genai_client = genai.Client(api_key="GEMINI_API_KEY") 

# client = instructor.from_genai(
#     genai_client, 
#     mode=instructor.Mode.GENAI_STRUCTURED_OUTPUTS
# )

hf_client = AsyncOpenAI(
    base_url="http://localhost:11434/v1/",
    api_key="ollama"
)

client = instructor.from_openai(
    hf_client,
    mode=instructor.Mode.JSON,
)


app = FastAPI(title="Hugging Face Photo Curation API")

class PhotoMetadata(BaseModel):
    subject: str = Field(description="The primary subject of the photo.")
    is_macro: bool = Field(description="True if the photo appears to be a macro or extreme close-up shot.")
    lighting_critique: str = Field(description="A brief, one-sentence critique of the lighting and contrast.")
    artistic_mood: str = Field(description="The emotional tone of the photo.")
    suggested_tags: list[str] = Field(description="5 to 7 specific tags for a portfolio database.")

@app.post("/api/v1/curate", response_model=PhotoMetadata, tags=["Agent Workflow"])
async def curate_photo(file: UploadFile = File(...)):
    if not file.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="File must be an image.")

    image_bytes = await file.read()
    base64_image = base64.b64encode(image_bytes).decode('utf-8')

    try:
        metadata = await client.chat.completions.create(
            model="llava", 
            response_model=PhotoMetadata,
            messages=[
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": "Analyze this photograph and extract the metadata."},
                        {"type": "image_url", "image_url": {"url": f"data:{file.content_type};base64,{base64_image}"}}
                    ]
                }
            ],
            max_retries=3,
        )
        return metadata

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"AI Processing failed: {str(e)}")