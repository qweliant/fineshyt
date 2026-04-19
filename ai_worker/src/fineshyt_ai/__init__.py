"""Fineshyt AI worker package.

The service is split along a transport/domain seam: the `domain/` modules
hold every inference + image-processing operation as plain functions that
know nothing about HTTP, while `transports/http/` marshals those functions
behind FastAPI. A future `transports/queue/` (RabbitMQ) consumer can import
the same domain functions without touching any of this layout.
"""
