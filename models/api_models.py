"""
API request and response models using Pydantic.
"""
from pydantic import BaseModel, Field
from typing import List, Dict, Any, Optional
from datetime import datetime


class OCRElement(BaseModel):
    """Represents a single raw PaddleOCR-VL result element.

    This is a flexible container for raw results from PaddleOCR-VL's save_to_json() method.
    The exact structure depends on the PaddleOCR-VL output format.
    """

    class Config:
        # Allow arbitrary fields to handle raw PaddleOCR-VL output
        extra = "allow"


class OCRResponse(BaseModel):
    """Response model for OCR extraction with raw PaddleOCR-VL results."""

    success: bool = Field(..., description="Whether the OCR processing was successful")
    message: str = Field(..., description="Status message")
    processing_time: float = Field(..., description="Processing time in seconds")
    results: List[Dict[str, Any]] = Field(default_factory=list, description="Raw PaddleOCR-VL results from save_to_json()")
    timestamp: datetime = Field(default_factory=datetime.utcnow, description="Response timestamp")

    class Config:
        json_schema_extra = {
            "example": {
                "success": True,
                "message": "Document processed successfully. Found 1 results.",
                "processing_time": 24.15,
                "results": [
                    {
                        "input_path": "/tmp/tmpg9eao3jp.jpg",
                        "page_index": None,
                        "model_settings": {
                            "use_doc_preprocessor": False,
                            "use_layout_detection": True,
                            "use_chart_recognition": False,
                            "format_block_content": False
                        },
                        "parsing_res_list": [
                            {
                                "block_label": "text",
                                "block_content": "Extracted document text content...",
                                "block_bbox": [9, 22, 381, 94],
                                "block_id": 0,
                                "block_order": 1
                            }
                        ],
                        "layout_det_res": {
                            "input_path": None,
                            "page_index": None,
                            "boxes": [
                                {
                                    "cls_id": 22,
                                    "label": "text",
                                    "score": 0.7198508381843567,
                                    "coordinate": [9.689, 22.654, 381.0, 94.012]
                                }
                            ]
                        }
                    }
                ],
                "timestamp": "2025-11-02T05:04:42.465560"
            }
        }


class HealthResponse(BaseModel):
    """Response model for health check."""

    status: str = Field(..., description="Service status (healthy/unhealthy)")
    service: str = Field(..., description="Service name")
    version: str = Field(..., description="Service version")
    pipeline_ready: bool = Field(..., description="Whether OCR pipeline is initialized")
    timestamp: datetime = Field(default_factory=datetime.utcnow, description="Response timestamp")

    class Config:
        json_schema_extra = {
            "example": {
                "status": "healthy",
                "service": "PaddleOCR-VL Service",
                "version": "1.0.0",
                "pipeline_ready": True,
                "timestamp": "2025-01-15T10:30:00Z"
            }
        }


class ErrorResponse(BaseModel):
    """Response model for errors."""

    success: bool = Field(False, description="Always False for errors")
    message: str = Field(..., description="Error message")
    error_type: str = Field(..., description="Error type/category")
    timestamp: datetime = Field(default_factory=datetime.utcnow, description="Error timestamp")

    class Config:
        json_schema_extra = {
            "example": {
                "success": False,
                "message": "Invalid file format. Only images and PDFs are supported.",
                "error_type": "ValidationError",
                "timestamp": "2025-01-15T10:30:00Z"
            }
        }
