"""Preference endpoints — CLIP embedding + Ridge train/score."""

from pathlib import Path

from fastapi import APIRouter, HTTPException

from fineshyt_ai.domain import embed as embed_domain
from fineshyt_ai.domain import preference as preference_domain
from fineshyt_ai.domain.preference import NoModelTrainedError, NotEnoughSamplesError
from fineshyt_ai.errors import error_detail, status_for
from fineshyt_ai.schemas.embed import EmbedRequest, EmbedResponse
from fineshyt_ai.schemas.preference import (
    PreferenceScoreRequest,
    PreferenceScoreResponse,
    PreferenceTrainRequest,
    PreferenceTrainResponse,
)

router = APIRouter(prefix="/api/v1", tags=["Preference"])


@router.post("/embed", response_model=EmbedResponse)
def embed_file(request: EmbedRequest):
    path = Path(request.file_path)
    if not path.is_file():
        raise HTTPException(status_code=404, detail=f"File not found: {request.file_path}")
    try:
        return embed_domain.embed(path)
    except Exception as e:
        raise HTTPException(
            status_code=status_for(e),
            detail=error_detail("embed", e, file_path=str(path)),
        )


@router.post("/preference/train", response_model=PreferenceTrainResponse)
def train_preference_model(request: PreferenceTrainRequest):
    try:
        return preference_domain.train(request.samples, request.min_samples)
    except NotEnoughSamplesError as e:
        raise HTTPException(
            status_code=400,
            detail=error_detail(
                "preference_train", e,
                n_samples=e.n_samples, min_samples=e.min_samples,
            ),
        )
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=error_detail("preference_train", e, n_samples=len(request.samples)),
        )


@router.post("/preference/score", response_model=PreferenceScoreResponse)
def score_preference(request: PreferenceScoreRequest):
    try:
        return preference_domain.score(request.embeddings)
    except NoModelTrainedError as e:
        raise HTTPException(
            status_code=400,
            detail=error_detail(
                "preference_score", e, n_embeddings=len(request.embeddings),
            ),
        )
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=error_detail(
                "preference_score", e, n_embeddings=len(request.embeddings),
            ),
        )
