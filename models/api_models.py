"""
API request and response models using Pydantic.
"""
from pydantic import BaseModel, Field
from typing import List, Dict, Any, Optional
from datetime import datetime


class OCRElement(BaseModel):
    """Represents a single raw PaddleOCR-VL result element.

    This is a flexible container for raw results from PaddleOCR-VL's to_dict() method.
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
    results: List[Dict[str, Any]] = Field(default_factory=list, description="Raw PaddleOCR-VL results from to_dict()")
    timestamp: datetime = Field(default_factory=datetime.utcnow, description="Response timestamp")

    class Config:
        json_schema_extra = {
            "example": {
                "success": True,
                "message": "Document processed successfully",
                "processing_time": 5.23,
                "results": [
                    {
                        "type": "text",
                        "bbox": [10, 20, 100, 50],
                        "content": "Sample document text"
                    }
                ],
                "timestamp": "2025-01-15T10:30:00Z"
            }
        }


class HealthResponse(BaseModel):
    """Response model for health check."""

    status: str = Field(..., description="Service status (healthy/unhealthy)")
    service: str = Field(..., description="Service name")
    version: str = Field(..., description="Service version")
    gpu_enabled: bool = Field(..., description="Whether GPU is enabled")
    pipeline_ready: bool = Field(..., description="Whether OCR pipeline is initialized")
    timestamp: datetime = Field(default_factory=datetime.utcnow, description="Response timestamp")

    class Config:
        json_schema_extra = {
            "example": {
                "status": "healthy",
                "service": "PaddleOCR-VL Service",
                "version": "1.0.0",
                "gpu_enabled": True,
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
