"""Ingestion endpoints — conversion, EXIF, and quality-score backfill ops."""

from pathlib import Path

from fastapi import APIRouter, File, HTTPException, UploadFile

from fineshyt_ai.domain import convert as convert_domain
from fineshyt_ai.errors import error_detail
from fineshyt_ai.schemas.convert import (
    ConvertResponse,
    ExifRequest,
    ExifResponse,
    QualityScoresRequest,
    QualityScoresResponse,
)

router = APIRouter(prefix="/api/v1", tags=["Ingestion"])


@router.post("/convert", response_model=ConvertResponse)
async def convert_file(file: UploadFile = File(...)):
    """Convert an uploaded source image to a resized JPEG + scores.

    Receives the source bytes as a multipart upload (the orchestrator reads
    the original off disk — which may be a drive Docker can't mount — and
    streams it here) so this container never needs filesystem access to the
    user's photo library. The filename carries the extension used to pick the
    RAW vs PIL decode path.
    """
    data = await file.read()
    try:
        return convert_domain.convert(data, file.filename or "")
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=error_detail("convert", e, filename=file.filename),
        )


@router.post("/exif", response_model=ExifResponse)
def read_exif(request: ExifRequest):
    path = Path(request.file_path)
    if not path.is_file():
        raise HTTPException(status_code=404, detail=f"File not found: {request.file_path}")
    return convert_domain.exif(path)


@router.post("/quality_scores", response_model=QualityScoresResponse)
def quality_scores(request: QualityScoresRequest):
    path = Path(request.file_path)
    if not path.is_file():
        raise HTTPException(status_code=404, detail=f"File not found: {request.file_path}")
    try:
        return convert_domain.quality_scores(path)
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=error_detail("quality_scores", e, file_path=request.file_path),
        )
