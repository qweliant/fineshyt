"""FastAPI application factory — wires the per-tag routers."""

from fastapi import FastAPI

from fineshyt_ai.transports.http.routes import burst, curate, ingestion, preference

app = FastAPI(title="Fineshyt Photo Curation API")

app.include_router(curate.router)
app.include_router(ingestion.router)
app.include_router(preference.router)
app.include_router(burst.router)
