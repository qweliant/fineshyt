"""Transport layer — thin adapters around `domain/`.

Today: FastAPI (`http/`). Future: RabbitMQ consumer (`queue/`). Every
transport must marshal inputs into the same domain function signatures
and translate raised exceptions into whatever its wire format expects.
"""
