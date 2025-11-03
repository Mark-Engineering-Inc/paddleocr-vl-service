# CLAUDE.md - PaddleOCR-VL Service

This file provides comprehensive guidance to Claude Code (claude.ai/code) and developers working with the PaddleOCR-VL service.

## Repository Overview

**PaddleOCR-VL Service** is a GPU-accelerated document OCR microservice that provides RESTful API access to PaddlePaddle's PaddleOCR-VL model. It extracts structured information from documents including text, tables, charts, and formulas in 109 languages.

**Tech Stack:**
- **Framework**: FastAPI (Python 3.10)
- **OCR Engine**: PaddleOCR-VL 0.9B (NaViT + ERNIE-4.5)
- **GPU**: NVIDIA L4 (CUDA 12.4)
- **Deployment**: Docker + docker-compose with multi-stage builds
- **Build Optimization**: Local PaddlePaddle wheel (1.8GB) to avoid slow China CDN
- **Model Loading**: Lazy loading on first request with volume persistence
- **Target**: AWS EC2 g6.xlarge (us-west-2)

## Project Structure

```
paddleocr-vl-service/
├── config/                         # Application configuration
│   ├── settings.py                # Pydantic settings (env vars)
│   └── logging_config.py          # Logging setup
├── services/                       # Business logic layer
│   └── paddleocr_vl_service.py    # PaddleOCR-VL wrapper (singleton)
├── models/                         # Pydantic data models
│   └── api_models.py              # Request/response schemas
├── routers/                        # API endpoints
│   └── ocr_router.py              # OCR extraction endpoint
├── main.py                         # FastAPI application + lifespan
├── requirements.txt                # Python dependencies
├── Dockerfile                      # Multi-stage GPU build
├── docker-compose.yml              # Docker Compose config
└── .env.template                   # Environment variables template
```

## Architecture

### Service Layers

```
Client (HTTP) → FastAPI (main.py) → OCR Router → PaddleOCR-VL Service → GPU Pipeline
```

**Key Design Patterns:**
- **Singleton**: One pipeline instance, thread-safe initialization
- **Lazy Loading**: Pipeline initializes on first request (libcuda.so.1 unavailable during Docker build)
- **Temp File Handling**: Bytes → temp file → process → cleanup
- **Raw Passthrough**: Results use `save_to_json()` with no transformation

## API Endpoints

### 1. Health Check

**Endpoint:** `GET /health`

**Response:**
```json
{
  "status": "healthy",
  "service": "PaddleOCR-VL Service",
  "version": "1.0.0",
  "pipeline_ready": false,
  "timestamp": "2025-01-15T10:30:00Z"
}
```

**Usage:**
- Docker health check: `curl -f http://localhost:8000/health`
- Monitor `pipeline_ready` for model load status

**Note:** GPU with CUDA is mandatory. Service fails at startup if GPU is unavailable.

### 2. Extract Document

**Endpoint:** `POST /api/v1/ocr/extract-document`

**Request:**
- Content-Type: `multipart/form-data`
- Field: `file` (max 50MB)
- Extensions: `.jpg`, `.jpeg`, `.png`, `.bmp`, `.tiff`, `.tif`, `.pdf`

**Example:**
```bash
curl -X POST http://localhost:8000/api/v1/ocr/extract-document \
  -F "file=@document.jpg"
```

**Response:** (simplified example)
```json
{
  "success": true,
  "message": "Document processed successfully. Found 1 results.",
  "processing_time": 24.15,
  "results": [
    {
      "input_path": "/tmp/tmpg9eao3jp.jpg",
      "model_settings": {...},
      "parsing_res_list": [
        {
          "block_label": "text",
          "block_content": "Extracted text...",
          "block_bbox": [9, 22, 381, 94],
          "block_id": 0,
          "block_order": 1
        }
      ],
      "layout_det_res": {
        "boxes": [
          {
            "label": "text",
            "score": 0.72,
            "coordinate": [9.689, 22.654, 381.0, 94.012]
          }
        ]
      }
    }
  ]
}
```

**Note:** `results` contains raw PaddleOCR-VL output via `save_to_json()`. Structure includes:
- `parsing_res_list[]`: Extracted content blocks (text/table/chart/formula)
- `layout_det_res.boxes[]`: Layout detection with confidence scores
- Additional fields vary by document type

**Error Responses:**
- `400`: Invalid file format or empty
- `413`: File exceeds 50MB
- `500`: Processing error (check logs)

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `APP_NAME` | PaddleOCR-VL Service | Service name |
| `APP_VERSION` | 1.0.0 | Service version |
| `APP_PORT` | 8000 | HTTP port |
| `APP_HOST` | 0.0.0.0 | Bind address |
| `DEBUG` | false | Debug mode |
| `MAX_UPLOAD_SIZE` | 52428800 | Max file size (50MB) |
| `MAX_CONCURRENT_REQUESTS` | 3 | Concurrent limit |
| `LOG_LEVEL` | INFO | Logging level |
| `LOG_FORMAT` | json | json/text |

**Note:** GPU with CUDA is mandatory - no configuration option to disable.

### Logging

**Default:** JSON format `{"timestamp": "...", "level": "INFO", "logger": "main", "message": "..."}`

**Suppressed:** `paddleocr`, `ppocr`, `PIL`, `urllib3` set to WARNING (verbose)

## Deployment

### Prerequisites

**AWS EC2 g6.xlarge Instance:**
- Region: us-west-2
- GPU: NVIDIA L4 (24GB VRAM)
- vCPUs: 4, RAM: 16GB
- Storage: Instance Store (250GB NVMe SSD)
- AMI: Ubuntu 22.04 with CUDA 12.4+

**Required Software:**
- Docker 24.0+
- Docker Compose 2.20+
- NVIDIA Container Toolkit

### Step 1: Create EC2 Instance

**Checklist:**
1. Create key pair: `aws ec2 create-key-pair --region us-west-2 --key-name paddleocr-vl-key`
2. Create security group: Allow SSH (port 22) from your IP, HTTP (port 8000) publicly
3. Launch g6.xlarge instance with Ubuntu 22.04 Deep Learning AMI (CUDA included)

**Launch command:**
```bash
aws ec2 run-instances \
  --region us-west-2 \
  --image-id ami-0xyz... \
  --instance-type g6.xlarge \
  --key-name paddleocr-vl-key \
  --security-groups paddleocr-vl-sg
```

### Step 2: Configure Instance

```bash
# SSH and update
ssh -i paddleocr-vl-key.pem ubuntu@<PUBLIC_IP>
sudo apt-get update && sudo apt-get upgrade -y

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER

# Install NVIDIA Container Toolkit
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | \
  sudo tee /etc/apt/sources.list.d/nvidia-docker.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo systemctl restart docker

# Verify
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

### Step 3: Deploy Service

```bash
git clone <repository-url> && cd paddleocr-vl-service
cp .env.template .env  # Optional
docker-compose up -d
docker-compose logs -f
curl http://localhost:8000/health
```

### Step 4: Test from Local Machine

```bash
# Health check
curl http://<EC2_PUBLIC_IP>:8000/health

# OCR extraction
curl -X POST http://<EC2_PUBLIC_IP>:8000/api/v1/ocr/extract-document \
  -F "file=@document.jpg" -o result.json

# Parse results with jq
cat result.json | jq -r '.results[].parsing_res_list[].block_content'
```

## Performance Tuning

### GPU Memory Management

**Monitor:** `nvidia-smi -l 1` or `docker exec paddleocr-vl-service nvidia-smi`

**Expected Usage:**
- Idle: ~100MB
- Loaded: ~2GB (model)
- Processing: ~4-6GB (varies by image)

**Optimize:** Set `MAX_CONCURRENT_REQUESTS=1` for large docs, resize images client-side

### Startup Times

**Cold start:** Container (~5s) + model init (~5-10s) = **10-15s total**
- Models pre-downloaded during Docker build (~2GB embedded in image)

**Warm start:** ~3-10s (processing only)

## Troubleshooting

### Docker Build Fails (Model Download)

**Symptoms:** Build fails during model download

**Solutions:**
- Test connectivity: `curl -I https://paddle-whl.bj.bcebos.com`
- Check disk space: ~7GB needed (3GB build + 4GB image)

### GPU Not Detected (Fatal Error)

**Symptoms:** Service fails to start with "GPU is mandatory" error

**Solution:** GPU with CUDA is required. Service cannot run without it.
- Verify GPU: `nvidia-smi`
- Test Docker GPU: `docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi`
- Check `docker-compose.yml` has GPU config under `deploy.resources.reservations.devices`
- Ensure NVIDIA Container Toolkit is installed

### CUDA Out of Memory

**Symptoms:** "CUDA out of memory" error

**Solutions:**
- Set `MAX_CONCURRENT_REQUESTS=1` in `.env`
- Check other GPU processes: `nvidia-smi`
- Upgrade to g6.2xlarge (48GB VRAM)

### safetensors Import Error

**Symptoms:** "safetensors does not support PaddlePaddle"

**Solution:**
```bash
docker exec paddleocr-vl-service pip install \
  https://paddle-whl.bj.bcebos.com/nightly/cu126/safetensors/safetensors-0.6.2.dev0-cp38-abi3-linux_x86_64.whl \
  --force-reinstall
```
**Cause:** Standard `safetensors` lacks PaddlePaddle support; must use custom wheel.

### Processing Timeout

**Symptoms:** Request hangs >60s

**Solutions:**
- Increase timeout: `curl --max-time 120 ...`
- Check model download: `docker-compose logs -f`
- Verify resources: `top` and `free -h`

### File Upload 413 Error

**Solutions:**
- Check size: `ls -lh file.jpg` (<50MB)
- Increase: `MAX_UPLOAD_SIZE=104857600` in `.env`

## Development Workflow

### Platform Limitations

**⚠️ PRODUCTION TARGET:** Linux x86_64 + NVIDIA GPU only

| Platform | Status | Note |
|----------|--------|------|
| Linux x86_64 + NVIDIA GPU | ✅ Full support | Production |
| Linux x86_64 (CPU) | ⚠️ Untested | Dev only |
| macOS ARM64 (M1/M2/M3) | ❌ NOT SUPPORTED | No ARM64 safetensors wheel |
| macOS x86_64 | ❌ NOT SUPPORTED | |
| Windows | ⚠️ Untested | |

**macOS Incompatibility:** PaddlePaddle-compatible `safetensors` wheel (`safetensors-0.6.2-cp38-abi3-linux_x86_64.whl`) only exists for Linux x86_64. Standard PyPI `safetensors` doesn't support PaddlePaddle framework.

### Adding Features

**New endpoint:** Add to `routers/ocr_router.py` + models in `models/api_models.py` + include in `main.py`

**Config changes:** Update `config/settings.py` + `.env.template` + docs

**Service logic:** Extend `services/paddleocr_vl_service.py` (maintain singleton)

### Testing Checklist

- [ ] `curl http://localhost:8000/health`
- [ ] OCR test with sample image
- [ ] Check logs: `docker-compose logs`
- [ ] GPU usage: `nvidia-smi`
- [ ] Error cases (invalid file, oversized, etc.)
- [ ] Update docs if API changes

## Critical Dependencies

### Installation Order (⚠️ CRITICAL)

**Must install in this exact order:**

1. **PaddlePaddle GPU 3.2.0** (CUDA 12.6)
   ```bash
   pip install paddlepaddle-gpu==3.2.0 -i https://www.paddlepaddle.org.cn/packages/stable/cu126/
   ```

2. **PaddleOCR with doc-parser**
   ```bash
   pip install "paddleocr[doc-parser]>=3.3.0"
   ```

3. **PaddlePaddle-compatible safetensors**
   ```bash
   pip install https://paddle-whl.bj.bcebos.com/nightly/cu126/safetensors/safetensors-0.6.2.dev0-cp38-abi3-linux_x86_64.whl --force-reinstall
   ```

**Why:** PaddleOCR depends on PaddlePaddle; safetensors must be compatible version. Wrong order → import errors.

### System Libraries

Ubuntu 22.04 packages: `libglib2.0-0 libsm6 libxext6 libxrender1 libgomp1 libgl1-mesa-glx`

## Model Information

**PaddleOCR-VL 0.9B:**
- Architecture: NaViT visual encoder + ERNIE-4.5-0.3B
- Capabilities: 109 languages, tables, formulas (LaTeX), charts
- Location: `/home/appuser/.paddleocr/models/` (~2GB)
- Performance: SOTA vs pipeline methods, competitive with 72B VLMs

## Monitoring

### Health Check Integration

```bash
curl -f http://localhost:8000/health || echo "unhealthy"
curl -s http://localhost:8000/health | jq -r '.status'
```

### Key Metrics

1. Health: `/health` returns 200
2. Pipeline ready: `.pipeline_ready == true`
3. Response time: `processing_time` field
4. Error rate: 4xx/5xx counts
5. GPU memory: `nvidia-smi --query-gpu=memory.used`
6. Container status: `docker ps | grep paddleocr-vl`

## Security Considerations

**File Upload:**
- ✅ Extension whitelist, size limits, temp cleanup, non-root user
- 💡 Add: Magic byte validation, rate limiting, filename sanitization, VPC isolation

**Container:**
- ✅ Non-root (`appuser`, UID 1000), minimal image, health checks
- 💡 Add: Read-only filesystem, drop capabilities, vulnerability scanning, secrets management

## References

- **PaddleOCR-VL**: https://huggingface.co/PaddlePaddle/PaddleOCR-VL
- **PaddleOCR GitHub**: https://github.com/PaddlePaddle/PaddleOCR
- **FastAPI**: https://fastapi.tiangolo.com/
- **NVIDIA Container Toolkit**: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/

## Changelog

### v1.0.0 (2025-01-15)
- Initial release with FastAPI, GPU support, multipart upload, Docker deployment, health check
