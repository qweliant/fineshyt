"""`/api/v1/detect_bursts` — group near-duplicate photos."""

from fastapi import APIRouter, HTTPException

from fineshyt_ai.domain import bursts as bursts_domain
from fineshyt_ai.errors import error_detail
from fineshyt_ai.schemas.burst import BurstDetectRequest, BurstDetectResponse

router = APIRouter(prefix="/api/v1", tags=["Burst"])


@router.post("/detect_bursts", response_model=BurstDetectResponse)
def detect_bursts(request: BurstDetectRequest):
    try:
        return bursts_domain.detect_bursts(request)
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=error_detail("detect_bursts", e, n_photos=len(request.photos)),
        )
