"""
PaddleOCR-VL Service - FastAPI application entry point.

A GPU-accelerated document OCR service using PaddleOCR-VL for
extracting text, tables, charts, and formulas from documents.
"""
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import uvicorn

from config import settings, setup_logging, get_logger
from models.api_models import HealthResponse
from routers import ocr_router
from services import paddleocr_vl_service

# Setup logging
setup_logging()
logger = get_logger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Application lifespan manager for startup and shutdown events.

    Startup:
    - Initialize logging
    - Log configuration
    - PaddleOCR-VL pipeline will be initialized lazily on first request

    Shutdown:
    - Cleanup resources
    """
    # Startup
    logger.info("=" * 80)
    logger.info(f"{settings.app_name} v{settings.app_version} - Starting up")
    logger.info("=" * 80)

    # Validate GPU availability (mandatory requirement)
    try:
        import paddle
        if not paddle.device.is_compiled_with_cuda():
            logger.error("FATAL: GPU/CUDA not available. This service requires GPU.")
            raise RuntimeError("GPU is mandatory for this service")
        gpu_count = paddle.device.cuda.device_count()
        logger.info(f"GPU detected: {gpu_count} device(s)")
    except ImportError:
        logger.error("FATAL: PaddlePaddle not installed")
        raise RuntimeError("PaddlePaddle is required")

    logger.info(f"Max Upload Size: {settings.max_upload_size / (1024*1024):.1f}MB")
    logger.info(f"API Endpoint: http://{settings.app_host}:{settings.app_port}{settings.api_v1_prefix}")
    logger.info(f"Note: PaddleOCR-VL pipeline will be initialized on first request (lazy loading)")
    logger.info("=" * 80)

    yield

    # Shutdown
    logger.info("=" * 80)
    logger.info(f"{settings.app_name} - Shutting down")
    logger.info("=" * 80)


# Create FastAPI application
app = FastAPI(
    title=settings.app_name,
    description="GPU-accelerated document OCR service using PaddleOCR-VL",
    version=settings.app_version,
    lifespan=lifespan,
    docs_url=f"{settings.api_v1_prefix}/docs",
    redoc_url=f"{settings.api_v1_prefix}/redoc",
    openapi_url=f"{settings.api_v1_prefix}/openapi.json"
)

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Configure appropriately for production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers
app.include_router(ocr_router, prefix=settings.api_v1_prefix)


@app.get("/health", response_model=HealthResponse, tags=["Health"])
async def health_check() -> HealthResponse:
    """
    Health check endpoint.

    Returns service status and pipeline readiness.
    """
    service_status = paddleocr_vl_service.get_status()

    return HealthResponse(
        status="healthy",
        service=settings.app_name,
        version=settings.app_version,
        pipeline_ready=service_status["initialized"]
    )


@app.get("/", tags=["Root"])
async def root():
    """Root endpoint with service information."""
    return {
        "service": settings.app_name,
        "version": settings.app_version,
        "status": "running",
        "docs": f"{settings.api_v1_prefix}/docs",
        "health": "/health"
    }


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    """Global exception handler for unhandled errors."""
    logger.error(f"Unhandled exception: {exc}", exc_info=True)
    return JSONResponse(
        status_code=500,
        content={
            "success": False,
            "message": "Internal server error",
            "error_type": type(exc).__name__
        }
    )


if __name__ == "__main__":
    # Run the application
    uvicorn.run(
        "main:app",
        host=settings.app_host,
        port=settings.app_port,
        reload=settings.debug,
        log_level=settings.log_level.lower()
    )
