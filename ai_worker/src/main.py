import base64
import os
from pathlib import Path

import instaloader
import instructor
from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from openai import AsyncOpenAI
from pydantic import BaseModel, Field

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

# Build a single shared Instaloader instance at startup.
# Strategy: load saved session → skip login entirely.
# If no session exists yet: login with credentials → save session for next time.
_loader = instaloader.Instaloader(
    download_videos=False,
    download_video_thumbnails=False,
    download_geotags=False,
    download_comments=False,
    save_metadata=False,
    post_metadata_txt_pattern="",
    quiet=True,
)
_instagram_ready = False
_instagram_error: str | None = None

def _try_load_session() -> bool:
    """Load session from file, trusting it if the file loads cleanly.
    test_login() hits the network and can be rate-limited — treat that as a
    soft warning, not a hard failure. Only reject if the file is missing or
    the session belongs to a different user."""
    global _instagram_ready, _instagram_error
    if not INSTAGRAM_USERNAME:
        _instagram_error = "INSTAGRAM_USERNAME is not set in ai_worker/.env"
        return False
    try:
        _loader.load_session_from_file(INSTAGRAM_USERNAME)
    except FileNotFoundError:
        _instagram_error = f"No session file for @{INSTAGRAM_USERNAME}. Run: make instagram-auth"
        return False
    except Exception as e:
        _instagram_error = f"Could not load session for @{INSTAGRAM_USERNAME}: {e}. Run: make instagram-auth"
        return False

    # Session file loaded. Optionally verify with test_login, but don't fail
    # on rate-limit errors — Instagram 401s here just mean "try later".
    try:
        logged_in_as = _loader.test_login()
        if logged_in_as is not None and logged_in_as != INSTAGRAM_USERNAME:
            _instagram_error = f"Session belongs to @{logged_in_as}, expected @{INSTAGRAM_USERNAME}. Run: make instagram-auth"
            return False
        if logged_in_as == INSTAGRAM_USERNAME:
            print(f"[instagram] session verified for @{INSTAGRAM_USERNAME}")
        else:
            print(f"[instagram] session loaded for @{INSTAGRAM_USERNAME} (test_login rate-limited, proceeding anyway)")
    except Exception:
        print(f"[instagram] session loaded for @{INSTAGRAM_USERNAME} (test_login failed, proceeding anyway)")

    _instagram_ready = True
    _instagram_error = None
    return True


if INSTAGRAM_USERNAME:
    _try_load_session()
else:
    _instagram_error = "INSTAGRAM_USERNAME is not set in ai_worker/.env"


app = FastAPI(title="Fineshyt Photo Curation API")


class PhotoMetadata(BaseModel):
    subject: str = Field(description="The primary subject of the photo.")
    is_macro: bool = Field(
        description="True if the photo appears to be a macro or extreme close-up shot."
    )
    lighting_critique: str = Field(
        description="A brief, one-sentence critique of the lighting and contrast."
    )
    artistic_mood: str = Field(description="The emotional tone of the photo.")
    suggested_tags: list[str] = Field(description="5 to 7 specific tags for a portfolio database.")
    style_match: bool = Field(
        description="True if the photo matches the provided style description. False if no style description was given."
    )
    style_score: int = Field(
        description="Style match confidence from 0 to 100. 0 if no style description was given."
    )
    style_reason: str = Field(
        description="One sentence explaining the style match decision. Empty string if no style description was given."
    )


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
    base64_image = base64.b64encode(image_bytes).decode("utf-8")

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
                            "text": f"You are an expert photo curator. Analyze this photograph and extract the metadata.\n\n{style_prompt}",
                        },
                        {
                            "type": "image_url",
                            "image_url": {"url": f"data:{file.content_type};base64,{base64_image}"},
                        },
                    ],
                }
            ],
            max_retries=3,
        )
        return metadata

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"AI Processing failed: {str(e)}")


@app.post(
    "/api/v1/download/instagram", response_model=InstagramDownloadResponse, tags=["Ingestion"]
)
async def download_instagram(request: InstagramDownloadRequest):
    """Download recent posts from an Instagram profile using the shared authenticated loader."""
    if not _instagram_ready and not _try_load_session():
        raise HTTPException(
            status_code=401, detail=_instagram_error or "Instagram not authenticated."
        )

    dest_dir = Path(UPLOAD_DIR) / "instagram" / request.username
    dest_dir.mkdir(parents=True, exist_ok=True)

    try:
        profile = instaloader.Profile.from_username(_loader.context, request.username)
    except instaloader.exceptions.ProfileNotExistsException as e:
        # Instagram returns 404 for both missing profiles AND rate limiting.
        # If the username looks right, it's almost certainly a rate limit.
        raise HTTPException(
            status_code=429,
            detail=f"Instagram is rate-limiting the profile lookup for @{request.username}. Wait a few minutes and try again. (Raw: {str(e)})"
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Failed to fetch profile: {str(e)}")

    file_paths = []
    shortcodes = []

    try:
        count = 0
        for post in profile.get_posts():
            if count >= request.max_posts:
                break
            if post.is_video:
                continue
            try:
                _loader.dirname_pattern = str(dest_dir)
                _loader.filename_pattern = "{shortcode}"
                _loader.download_post(post, target=dest_dir)
                candidate = dest_dir / f"{post.shortcode}.jpg"
                if candidate.exists():
                    file_paths.append(str(candidate))
                    shortcodes.append(post.shortcode)
                    count += 1
            except Exception:
                continue
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Failed to download posts: {str(e)}")

    return InstagramDownloadResponse(file_paths=file_paths, shortcodes=shortcodes)
