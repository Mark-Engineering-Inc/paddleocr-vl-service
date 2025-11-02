# ==============================================================================
# Multi-stage Dockerfile for PaddleOCR-VL Service
# ==============================================================================
# Production-ready Docker image for GPU-accelerated OCR service
# Base: CUDA 12.4 runtime on Ubuntu 22.04
# Target: AWS EC2 g6.xlarge (NVIDIA L4 GPU)
#
# Build Requirements:
#   - Local PaddlePaddle wheel file (1.8GB) stored outside git repo
#     Download: https://paddle-whl.bj.bcebos.com/stable/cu126/paddlepaddle-gpu/paddlepaddle_gpu-3.2.0-cp310-cp310-linux_x86_64.whl
#   - Docker 24.0+ with NVIDIA Container Toolkit (nvidia-container-toolkit package)
#   - 30GB+ free disk space for build artifacts and layers
#
# Build Command:
#   docker-compose build
# ==============================================================================

# ================================
# Stage 1: Builder
# ================================
FROM nvidia/cuda:12.4.0-runtime-ubuntu22.04 AS builder

# Environment configuration
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Install build dependencies and Python 3.10
# Note: Using Python 3.10 (Ubuntu 22.04 default) instead of 3.13.5 because:
#   - Python 3.13 not available in Ubuntu 22.04 repos (would require PPA or different base image)
#   - PaddlePaddle GPU 3.2.0 is tested and certified with Python 3.10
#   - Changing Python version risks compatibility issues with CUDA/PaddlePaddle stack
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.10 \
    python3-pip \
    python3-dev \
    build-essential \
    wget \
    curl \
    ca-certificates \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    libgomp1 \
    libgl1-mesa-glx \
    && rm -rf /var/lib/apt/lists/*

# Set Python 3.10 as default python
RUN ln -sf /usr/bin/python3.10 /usr/bin/python

# Upgrade pip and build tools
RUN python -m pip install --no-cache-dir --upgrade pip setuptools wheel

# Install PaddlePaddle GPU 3.2.0 from local wheel file
# Why local wheel: Avoids 60+ minute download from China CDN (paddle-whl.bj.bcebos.com)
# Note: This must be installed BEFORE PaddleOCR to ensure correct dependencies
COPY /tmp/paddlepaddle_gpu-3.2.0-cp310-cp310-linux_x86_64.whl /tmp/
RUN python -m pip install --no-cache-dir /tmp/paddlepaddle_gpu-3.2.0-cp310-cp310-linux_x86_64.whl

# Install PaddleOCR with doc-parser support (includes PaddleOCR-VL)
RUN python -m pip install --no-cache-dir "paddleocr[doc-parser]>=3.3.0"

# Install PaddlePaddle-compatible safetensors
# Why custom wheel: Standard PyPI safetensors doesn't support PaddlePaddle framework
RUN python -m pip install --no-cache-dir \
    https://paddle-whl.bj.bcebos.com/nightly/cu126/safetensors/safetensors-0.6.2.dev0-cp38-abi3-linux_x86_64.whl \
    --force-reinstall

# Install application dependencies (FastAPI, uvicorn, etc.)
COPY requirements.txt /tmp/requirements.txt
RUN python -m pip install --no-cache-dir -r /tmp/requirements.txt

# Clean up builder artifacts while keeping runtime dependencies
# IMPORTANT: Keep setuptools - required by PaddleOCR-VL at runtime (import pkg_resources)
RUN pip uninstall -y pip wheel && \
    rm -rf /root/.cache /tmp/* && \
    find /usr/local/lib/python3.10/dist-packages -name "*.pyc" -delete && \
    find /usr/local/lib/python3.10/dist-packages -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

# ================================
# Stage 2: Runtime
# ================================
FROM nvidia/cuda:12.4.0-runtime-ubuntu22.04

# Environment configuration
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Install runtime dependencies (no build tools needed)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.10 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    libgomp1 \
    libgl1-mesa-glx \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Set Python 3.10 as default python
RUN ln -sf /usr/bin/python3.10 /usr/bin/python

# Copy Python packages and binaries from builder stage
COPY --from=builder /usr/local/lib/python3.10/dist-packages /usr/local/lib/python3.10/dist-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Clean up unnecessary build tools to reduce image size
# IMPORTANT: Keep setuptools and pkg_resources - required by PaddleOCR-VL (import pkg_resources)
# Note: Only removing pip and wheel, keeping setuptools intact
RUN rm -rf /usr/local/bin/pip* /usr/local/bin/wheel && \
    rm -rf /usr/local/lib/python3.10/dist-packages/{pip,pip-*,wheel,wheel-*} && \
    find /usr/local/lib/python3.10/dist-packages -name "*.pyc" -delete && \
    find /usr/local/lib/python3.10/dist-packages -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

# Create non-root user for security best practices
RUN useradd -m -u 1000 -s /bin/bash appuser

# Set application working directory
WORKDIR /app

# Copy application code
# Note: Using selective COPY to exclude large wheel file (1.8GB) from runtime image
COPY --chown=appuser:appuser config/ /app/config/
COPY --chown=appuser:appuser services/ /app/services/
COPY --chown=appuser:appuser models/ /app/models/
COPY --chown=appuser:appuser routers/ /app/routers/
COPY --chown=appuser:appuser main.py /app/main.py

# Create directories for PaddleOCR models and temporary files
# Models will be downloaded to ~/.paddleocr on first API request (lazy loading)
RUN mkdir -p /home/appuser/.paddleocr /tmp/paddleocr && \
    chown -R appuser:appuser /home/appuser/.paddleocr /tmp/paddleocr

# Switch to non-root user for runtime security
USER appuser

# ==============================================================================
# Model Download Strategy
# ==============================================================================
# Models are NOT pre-downloaded during build because:
#   1. libcuda.so.1 (NVIDIA driver) is not available during Docker build
#   2. PaddleOCR-VL initialization requires GPU access which fails at build time
#
# Instead, models download lazily on first API request:
#   - First request: ~1-2 seconds (models download from PaddleOCR servers)
#   - Subsequent requests: < 2 seconds
#   - Models persist in volume across container restarts
#
# Trade-off: Slightly slower first request vs. faster Docker builds
# ==============================================================================

# Runtime environment variables
ENV HOME=/home/appuser \
    PATH="/home/appuser/.local/bin:${PATH}" \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

# Expose FastAPI port
EXPOSE 8000

# Docker health check for container orchestration
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# Start FastAPI application
CMD ["python", "main.py"]
