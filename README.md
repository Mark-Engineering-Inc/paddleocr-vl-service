# PaddleOCR-VL Service

A GPU-accelerated document OCR service built with FastAPI and PaddleOCR-VL. Extracts text, tables, charts, and formulas from documents in 109 languages.

## Features

- **GPU Accelerated**: Optimized for NVIDIA L4 GPU (g6.xlarge)
- **RESTful API**: Simple HTTP multipart file upload
- **Raw Results**: Direct output from PaddleOCR-VL's save_to_json() method
- **Production Ready**: Docker deployment with health checks

## Quick Start

### Prerequisites

- Docker with NVIDIA Container Toolkit
- AWS EC2 g6.xlarge instance (NVIDIA L4 GPU)
- Ubuntu 22.04 with CUDA 12.4+

### Deploy with Docker Compose

**Prerequisites:**
- Download PaddlePaddle GPU wheel file (1.8GB) to project root:
  ```bash
  curl -o paddlepaddle_gpu-3.2.0-cp310-cp310-linux_x86_64.whl \
    https://paddle-whl.bj.bcebos.com/stable/cu126/paddlepaddle-gpu/paddlepaddle_gpu-3.2.0-cp310-cp310-linux_x86_64.whl
  ```

**Build and Deploy:**
```bash
# Clone repository
git clone <repository-url>
cd paddleocr-vl-service

# Build Docker image (requires local wheel file)
docker-compose build

# Start service
docker-compose up -d

# Check status
curl http://localhost:8000/health
```

The service will be available at `http://localhost:8000`

**Important Notes:**
- **Local wheel file required**: The 1.8GB PaddlePaddle wheel must be in the project root before building to avoid 60+ minute downloads from China CDN
- **Lazy model loading**: OCR models (~2GB) download automatically on first API request (~1-2 seconds)
- **Persistent models**: Models are stored in Docker volume and persist across container restarts

## API Documentation

### Health Check

Check service status and GPU availability.

```bash
curl http://localhost:8000/health
```

**Response:**
```json
{
  "status": "healthy",
  "service": "PaddleOCR-VL Service",
  "version": "1.0.0",
  "gpu_enabled": true,
  "pipeline_ready": true,
  "timestamp": "2025-01-15T10:30:00Z"
}
```

### Extract Document (OCR)

Upload an image or PDF file to extract document structure.

**Endpoint:** `POST /api/v1/ocr/extract-document`

**Request:**
```bash
curl -X POST http://localhost:8000/api/v1/ocr/extract-document \
  -F "file=@/path/to/your/document.jpg" \
  -o response.json
```

**Supported Formats:**
- Images: `.jpg`, `.jpeg`, `.png`, `.bmp`, `.tiff`, `.tif`
- Documents: `.pdf`
- Max file size: 50MB

**Response:**
```json
{
  "success": true,
  "message": "Document processed successfully. Found 3 results.",
  "processing_time": 5.23,
  "results": [
    {
      "type": "text",
      "bbox": [10, 20, 200, 50],
      "content": "Document heading",
      "confidence": 0.98
    },
    {
      "type": "table",
      "bbox": [10, 60, 400, 200],
      "content": {
        "rows": 5,
        "columns": 3,
        "data": [...]
      }
    }
  ],
  "timestamp": "2025-01-15T10:30:00Z"
}
```

**Note:** The `results` field contains raw output from PaddleOCR-VL's `save_to_json()` method. Structure varies based on document content and element types (text, table, chart, formula).

### Example: Process from Local Machine to Remote Server

```bash
# Test with sample image
curl -X POST http://<EC2-PUBLIC-IP>:8000/api/v1/ocr/extract-document \
  -F "file=@/Users/zhangshengjie/Downloads/scan_samples_en/scan_samples_en_63.jpg" \
  | jq '.results[] | {type, content}'
```

### Interactive API Documentation

Access Swagger UI at: `http://localhost:8000/api/v1/docs`

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  FastAPI Application                │
│                     (main.py)                       │
├─────────────────────────────────────────────────────┤
│                                                     │
│  ┌─────────────────┐      ┌──────────────────┐    │
│  │  OCR Router     │─────▶│  PaddleOCR-VL    │    │
│  │ (multipart API) │      │    Service       │    │
│  └─────────────────┘      └──────────────────┘    │
│                                   │                │
│                                   ▼                │
│                          ┌──────────────────┐     │
│                          │  PaddleOCR-VL    │     │
│                          │    Pipeline      │     │
│                          │   (0.9B model)   │     │
│                          └──────────────────┘     │
│                                   │                │
│                                   ▼                │
│                          ┌──────────────────┐     │
│                          │   NVIDIA L4 GPU  │     │
│                          │   (CUDA 12.4)    │     │
│                          └──────────────────┘     │
└─────────────────────────────────────────────────────┘
```

**Key Components:**
- **FastAPI**: Web framework with async support
- **PaddleOCR-VL**: Vision-language OCR model (0.9B parameters)
- **Lazy Model Loading**: Models download on first API request and persist in volume
- **Thread-Safe**: Singleton pattern for pipeline management
- **Local Wheel Optimization**: PaddlePaddle installed from local file to avoid slow CDN downloads

## Configuration

Environment variables (see `.env.template`):

```bash
# Application
APP_PORT=8000
DEBUG=false

# GPU Settings
USE_GPU=true
DEVICE=gpu

# Upload Limits
MAX_UPLOAD_SIZE=52428800  # 50MB

# Logging
LOG_LEVEL=INFO
LOG_FORMAT=json
```

## Performance

**Hardware:** g6.xlarge (NVIDIA L4, 4 vCPUs, 16GB RAM)

**Typical Processing Times:**
- Container startup: ~5 seconds
- First API request: ~1-2 seconds (lazy model loading from volume)
- Simple document (1 page, text only): 1-2 seconds
- Complex document (tables, charts): 2-5 seconds

**GPU Memory Usage:**
- Model size: ~2GB VRAM
- Processing overhead: ~4GB VRAM
- Recommended: 8GB+ VRAM

## Deployment Guide

### AWS EC2 Deployment

See [CLAUDE.md](CLAUDE.md) for detailed deployment instructions including:
- EC2 instance creation and configuration
- Docker and NVIDIA Container Toolkit installation
- Security group setup
- Performance tuning

### Health Monitoring

```bash
# Check health status
curl http://localhost:8000/health

# View logs
docker-compose logs -f paddleocr-vl

# Monitor GPU usage
nvidia-smi -l 1
```

## Troubleshooting

### Docker Build Fails - Missing Wheel File

**Problem:** Build fails with "paddlepaddle_gpu-3.2.0-cp310-cp310-linux_x86_64.whl: not found"

**Solution:** Download the PaddlePaddle GPU wheel file to project root:
```bash
curl -o paddlepaddle_gpu-3.2.0-cp310-cp310-linux_x86_64.whl \
  https://paddle-whl.bj.bcebos.com/stable/cu126/paddlepaddle-gpu/paddlepaddle_gpu-3.2.0-cp310-cp310-linux_x86_64.whl

# Verify file exists (should be ~1.8GB)
ls -lh paddlepaddle_gpu-3.2.0-cp310-cp310-linux_x86_64.whl

# Retry build
docker-compose build
```

### Disk Space Issues

**Problem:** Build fails with "no space left on device"

**Solution:** Free up Docker disk space:
```bash
# Check Docker disk usage
docker system df

# Clean up unused Docker resources
docker system prune -af --volumes

# Verify available space (recommend 50GB+)
df -h
```

### GPU Not Detected

**Problem:** Service runs on CPU instead of GPU

**Solution:** Verify NVIDIA Container Toolkit:
```bash
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

### Out of Memory Errors

**Problem:** CUDA OOM during processing

**Solution:**
- Reduce `MAX_CONCURRENT_REQUESTS` in `.env`
- Ensure g6.xlarge or larger instance
- Check other GPU processes: `nvidia-smi`

## Development

For detailed development guidelines, architecture documentation, and troubleshooting, see [CLAUDE.md](CLAUDE.md).

## License

MIT License

## Support

For issues and questions, please open an issue on GitHub.
