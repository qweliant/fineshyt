import base64
import os
import shutil
import tempfile
from pathlib import Path
from fastapi import FastAPI, Form, UploadFile, File, HTTPException
from pydantic import BaseModel, Field
from openai import AsyncOpenAI
import instructor
import instaloader
from dotenv import load_dotenv

load_dotenv()

LLM_BASE_URL = os.getenv("LLM_BASE_URL", "http://localhost:11434/v1/")
LLM_API_KEY = os.getenv("LLM_API_KEY", "ollama")
LLM_MODEL = os.getenv("LLM_MODEL", "llava")
INSTAGRAM_USERNAME = os.getenv("INSTAGRAM_USERNAME", "")
INSTAGRAM_PASSWORD = os.getenv("INSTAGRAM_PASSWORD", "")
UPLOAD_DIR = os.getenv("UPLOAD_DIR", "/tmp/fineshyt_uploads")

client = instructor.from_openai(
    AsyncOpenAI(base_url=LLM_BASE_URL, api_key=LLM_API_KEY),
    mode=instructor.Mode.JSON,
)


app = FastAPI(title="Fineshyt Photo Curation API")


class PhotoMetadata(BaseModel):
    subject: str = Field(description="The primary subject of the photo.")
    is_macro: bool = Field(description="True if the photo appears to be a macro or extreme close-up shot.")
    lighting_critique: str = Field(description="A brief, one-sentence critique of the lighting and contrast.")
    artistic_mood: str = Field(description="The emotional tone of the photo.")
    suggested_tags: list[str] = Field(description="5 to 7 specific tags for a portfolio database.")
    style_match: bool = Field(description="True if the photo matches the provided style description. False if no style description was given.")
    style_score: int = Field(description="Style match confidence from 0 to 100. 0 if no style description was given.")
    style_reason: str = Field(description="One sentence explaining the style match decision. Empty string if no style description was given.")


class InstagramDownloadRequest(BaseModel):
    username: str
    max_posts: int = 50


class InstagramDownloadResponse(BaseModel):
    file_paths: list[str]
    shortcodes: list[str]


@app.post("/api/v1/curate", response_model=PhotoMetadata, tags=["Agent Workflow"])
async def curate_photo(
    file: UploadFile = File(...),
    style_description: str = Form(""),
):
    if not file.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="File must be an image.")

    image_bytes = await file.read()
    base64_image = base64.b64encode(image_bytes).decode('utf-8')

    style_prompt = ""
    if style_description:
        style_prompt = f"""
The photographer's style is described as:
"{style_description}"

Evaluate whether this photograph matches that style. Be strict — only mark style_match: true
if the photo genuinely fits the described aesthetic. Set style_score (0-100) and style_reason accordingly.
"""
    else:
        style_prompt = "No style description provided. Set style_match: false, style_score: 0, style_reason: empty string."

    try:
        metadata = await client.chat.completions.create(
            model=LLM_MODEL,
            response_model=PhotoMetadata,
            messages=[
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "text": f"You are an expert photo curator. Analyze this photograph and extract the metadata.\n\n{style_prompt}"
                        },
                        {"type": "image_url", "image_url": {"url": f"data:{file.content_type};base64,{base64_image}"}}
                    ]
                }
            ],
            max_retries=3,
        )
        return metadata

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"AI Processing failed: {str(e)}")


@app.post("/api/v1/download/instagram", response_model=InstagramDownloadResponse, tags=["Ingestion"])
async def download_instagram(request: InstagramDownloadRequest):
    """Download recent posts from a public Instagram profile."""
    dest_dir = Path(UPLOAD_DIR) / "instagram" / request.username
    dest_dir.mkdir(parents=True, exist_ok=True)

    loader = instaloader.Instaloader(
        download_videos=False,
        download_video_thumbnails=False,
        download_geotags=False,
        download_comments=False,
        save_metadata=False,
        post_metadata_txt_pattern="",
        filename_pattern="{shortcode}",
        dirname_pattern=str(dest_dir),
        quiet=True,
    )

    # Try password login from env first (most reliable)
    session_loaded = False
    if INSTAGRAM_USERNAME and INSTAGRAM_PASSWORD:
        try:
            loader.login(INSTAGRAM_USERNAME, INSTAGRAM_PASSWORD)
            if not loader.context.is_logged_in:
                raise HTTPException(status_code=401, detail="Instagram login appeared to succeed but session is not authenticated. Instagram may be blocking this login — use the session file approach instead: uv run instaloader --login=" + INSTAGRAM_USERNAME)
            session_loaded = True
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=401, detail=f"Instagram login failed: {str(e)}")

    # Fall back to saved session file (created by: uv run instaloader --login=<username>)
    if not session_loaded:
        session_user = INSTAGRAM_USERNAME or request.username
        try:
            loader.load_session_from_file(session_user)
            session_loaded = True
        except FileNotFoundError:
            pass
        except Exception as e:
            raise HTTPException(status_code=401, detail=f"Session file invalid: {str(e)}. Run: uv run instaloader --login={request.username}")

    if not session_loaded:
        raise HTTPException(
            status_code=401,
            detail=(
                f"Instagram requires authentication. "
                f"Either set INSTAGRAM_USERNAME and INSTAGRAM_PASSWORD in ai_worker/.env, "
                f"or run: uv run instaloader --login={request.username}"
            ),
        )

    try:
        profile = instaloader.Profile.from_username(loader.context, request.username)
    except instaloader.exceptions.ProfileNotExistsException as e:
        raise HTTPException(status_code=404, detail=f"Instagram profile '{request.username}' not found or session expired: {str(e)}")
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Failed to fetch Instagram profile: {str(e)}")

    file_paths = []
    shortcodes = []

    try:
        posts = profile.get_posts()
        count = 0
        for post in posts:
            if count >= request.max_posts:
                break
            if post.is_video:
                continue
            try:
                loader.download_post(post, target=dest_dir)
                # instaloader saves as {shortcode}.jpg
                candidate = dest_dir / f"{post.shortcode}.jpg"
                if candidate.exists():
                    file_paths.append(str(candidate))
                    shortcodes.append(post.shortcode)
                    count += 1
            except Exception:
                # Skip posts that fail individually
                continue
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Failed to download posts: {str(e)}")

    return InstagramDownloadResponse(file_paths=file_paths, shortcodes=shortcodes)
