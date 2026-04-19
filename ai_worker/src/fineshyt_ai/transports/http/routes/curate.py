"""`/api/v1/curate` — structured LLM metadata for a single photo upload."""

from fastapi import APIRouter, File, HTTPException, UploadFile

from fineshyt_ai.domain import curate as curate_domain
from fineshyt_ai.errors import error_detail, status_for
from fineshyt_ai.schemas.curate import PhotoMetadata

router = APIRouter(prefix="/api/v1", tags=["Agent Workflow"])


@router.post("/curate", response_model=PhotoMetadata)
async def curate_photo(file: UploadFile = File(...)):
    image_bytes = await file.read()
    try:
        return await curate_domain.curate(image_bytes, file.content_type or "")
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        raise HTTPException(
            status_code=status_for(e),
            detail=error_detail("curate", e, filename=file.filename),
        )
