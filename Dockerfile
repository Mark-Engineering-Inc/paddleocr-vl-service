# Multi-stage Dockerfile for PaddleOCR-VL Service
# Base: CUDA 12.4 runtime on Ubuntu 22.04

# ================================
# Stage 1: Builder
# ================================
FROM nvidia/cuda:12.4.0-base-ubuntu22.04 AS builder

# Prevent interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# Install system dependencies
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

# Create symlink for python
RUN ln -sf /usr/bin/python3.10 /usr/bin/python

# Upgrade pip
RUN python -m pip install --no-cache-dir --upgrade pip setuptools wheel

# Install PaddlePaddle GPU 3.2.0 (CUDA 12.6 compatible)
# CRITICAL: This must be installed BEFORE PaddleOCR
RUN python -m pip install --no-cache-dir \
    paddlepaddle-gpu==3.2.0 \
    -i https://www.paddlepaddle.org.cn/packages/stable/cu126/

# Install PaddleOCR with doc-parser support
RUN python -m pip install --no-cache-dir "paddleocr[doc-parser]>=3.3.0"

# Install PaddlePaddle-compatible safetensors
# CRITICAL: Standard safetensors doesn't support PaddlePaddle!
RUN python -m pip install --no-cache-dir \
    https://paddle-whl.bj.bcebos.com/nightly/cu126/safetensors/safetensors-0.6.2.dev0-cp38-abi3-linux_x86_64.whl \
    --force-reinstall

# Copy requirements and install Python dependencies
COPY requirements.txt /tmp/requirements.txt
RUN python -m pip install --no-cache-dir -r /tmp/requirements.txt

# Clean up builder stage to reduce size of copied artifacts
RUN pip uninstall -y pip setuptools wheel && \
    rm -rf /root/.cache /tmp/* && \
    find /usr/local/lib/python3.10/dist-packages -name "*.pyc" -delete && \
    find /usr/local/lib/python3.10/dist-packages -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

# ================================
# Stage 2: Runtime
# ================================
FROM nvidia/cuda:12.4.0-base-ubuntu22.04

# Prevent interactive prompts
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# Install runtime dependencies only
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

# Create symlink for python
RUN ln -sf /usr/bin/python3.10 /usr/bin/python

# Copy Python packages from builder
COPY --from=builder /usr/local/lib/python3.10/dist-packages /usr/local/lib/python3.10/dist-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Remove build tools and clean up Python packages to reduce image size
RUN rm -rf /usr/local/bin/pip* /usr/local/bin/wheel && \
    rm -rf /usr/local/lib/python3.10/dist-packages/{pip,pip-*,setuptools,setuptools-*,wheel,wheel-*,pkg_resources} && \
    find /usr/local/lib/python3.10/dist-packages -name "*.pyc" -delete && \
    find /usr/local/lib/python3.10/dist-packages -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true && \
    find /usr/local/lib/python3.10/dist-packages -name "tests" -type d -exec rm -rf {} + 2>/dev/null || true

# Create non-root user for security
RUN useradd -m -u 1000 -s /bin/bash appuser

# Set working directory
WORKDIR /app

# Copy application code
COPY --chown=appuser:appuser . /app

# Create directories for models and temp files
RUN mkdir -p /home/appuser/.paddleocr /tmp/paddleocr && \
    chown -R appuser:appuser /home/appuser/.paddleocr /tmp/paddleocr

# Switch to non-root user
USER appuser

# Pre-download PaddleOCR-VL models during build (MUST succeed or build fails)
# This eliminates the 10-15 second model download delay on first API request
RUN python -c "\
from paddleocr import PaddleOCRVL; \
import os; \
print('Downloading PaddleOCR-VL models...'); \
model = PaddleOCRVL(); \
model_dir = os.path.expanduser('~/.paddleocr'); \
assert os.path.exists(model_dir), 'Model directory not created'; \
assert os.listdir(model_dir), 'Model directory is empty'; \
print('✓ Models downloaded and verified successfully'); \
"

# Environment variables
ENV HOME=/home/appuser
ENV PATH="/home/appuser/.local/bin:${PATH}"
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility

# Expose port
EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# Run the application
CMD ["python", "main.py"]
