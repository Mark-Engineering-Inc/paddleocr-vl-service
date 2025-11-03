# Test Data

This directory contains sample documents used for testing the PaddleOCR-VL service.

## Sample Documents

### sample-document.jpg

- **Size**: 33KB
- **Format**: JPEG
- **Language**: English
- **Content**: Text about mobile payment systems in China
- **Usage**: Default test image for OCR API verification in `scripts/verify-deployment.sh`

**Sample extracted text:**
```
pay in cash (paper money) out of habit. However, today, China is
leading the world in mobile payment, mainly WeChat Pay and Alipay...
```

## Usage in Scripts

The verification script automatically uses `sample-document.jpg` for OCR API testing:

```bash
# Automatic test with repository image
./scripts/verify-deployment.sh --host <HOST>

# Use custom test image
./scripts/verify-deployment.sh --host <HOST> --test-image /path/to/your/image.jpg

# Skip OCR API test
./scripts/verify-deployment.sh --host <HOST> --skip-api-test
```

## Adding More Test Images

To add additional test images:

1. Place the image in this directory
2. Use descriptive filename (e.g., `invoice-sample.pdf`, `receipt-sample.jpg`)
3. Update this README with image details
4. Test with: `./scripts/verify-deployment.sh --test-image test-data/your-image.jpg`

## Image Requirements

- **Supported formats**: JPG, JPEG, PNG, BMP, TIFF, TIF, PDF
- **Max size**: 50MB (configurable via `MAX_UPLOAD_SIZE` in service)
- **Recommended**: Clear text, good resolution (300+ DPI)
- **Languages**: PaddleOCR-VL supports 109 languages
