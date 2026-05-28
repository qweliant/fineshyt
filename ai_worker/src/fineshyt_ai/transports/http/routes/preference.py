"""Preference endpoints — CLIP embedding + Ridge train/score."""

from fastapi import APIRouter, File, HTTPException, UploadFile

from fineshyt_ai.domain import embed as embed_domain
from fineshyt_ai.domain import preference as preference_domain
from fineshyt_ai.domain.preference import NoModelTrainedError, NotEnoughSamplesError
from fineshyt_ai.errors import error_detail, status_for
from fineshyt_ai.schemas.embed import EmbedResponse
from fineshyt_ai.schemas.preference import (
    PreferenceScoreRequest,
    PreferenceScoreResponse,
    PreferenceTrainRequest,
    PreferenceTrainResponse,
)

router = APIRouter(prefix="/api/v1", tags=["Preference"])


@router.post("/embed", response_model=EmbedResponse)
async def embed_file(file: UploadFile = File(...)):
    """Return a CLIP embedding for an uploaded image.

    Receives the image bytes as a multipart upload (the orchestrator reads
    the converted JPEG off its own uploads dir and streams it) so this
    container never needs filesystem access to resolve the path.
    """
    data = await file.read()
    try:
        return embed_domain.embed(data, file.filename or "")
    except Exception as e:
        raise HTTPException(
            status_code=status_for(e),
            detail=error_detail("embed", e, filename=file.filename),
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
