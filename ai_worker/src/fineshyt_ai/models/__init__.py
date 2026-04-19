"""Stateful ML model holders — CLIP weights, instructor LLM client, pickled Ridge.

Each module owns lazy loading and process-wide caching. Shared by every
transport (HTTP now, queue-consumer later).
"""
