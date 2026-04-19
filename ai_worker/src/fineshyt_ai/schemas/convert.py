"""Ingestion I/O — conversion, EXIF extraction, quality scoring."""

from pydantic import BaseModel


class ConvertRequest(BaseModel):
    file_path: str


class ConvertResponse(BaseModel):
    jpeg_path: str
    technical_score: int
    sharpness_score: int
    exposure_score: int
    captured_at: str | None = None


class ExifRequest(BaseModel):
    file_path: str


class ExifResponse(BaseModel):
    captured_at: str | None = None


class QualityScoresRequest(BaseModel):
    file_path: str


class QualityScoresResponse(BaseModel):
    technical_score: int
    sharpness_score: int
    exposure_score: int
