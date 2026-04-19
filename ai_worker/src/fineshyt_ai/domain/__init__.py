"""Transport-free business operations.

Each module exports one or two plain functions whose inputs are concrete
types (`Path`, `bytes`, numpy arrays, Pydantic schemas) and whose outputs
are Pydantic response schemas. They raise normal Python exceptions; the
transport layer decides whether those become HTTP 500s, dead-lettered
queue messages, or something else.
"""
