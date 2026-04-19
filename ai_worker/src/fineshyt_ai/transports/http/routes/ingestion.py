"""Ingestion endpoints — conversion, EXIF, and quality-score backfill ops."""

from pathlib import Path

from fastapi import APIRouter, HTTPException

from fineshyt_ai.domain import convert as convert_domain
from fineshyt_ai.errors import error_detail
from fineshyt_ai.schemas.convert import (
    ConvertRequest,
    ConvertResponse,
    ExifRequest,
    ExifResponse,
    QualityScoresRequest,
    QualityScoresResponse,
)

router = APIRouter(prefix="/api/v1", tags=["Ingestion"])


@router.post("/convert", response_model=ConvertResponse)
def convert_file(request: ConvertRequest):
    path = Path(request.file_path)
    if not path.is_file():
        raise HTTPException(status_code=404, detail=f"File not found: {request.file_path}")
    try:
        return convert_domain.convert(path)
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=error_detail("convert", e, file_path=str(path)),
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
