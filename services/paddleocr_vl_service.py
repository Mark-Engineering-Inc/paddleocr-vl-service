"""
PaddleOCR-VL service wrapper for document OCR processing.
"""
import threading
from typing import Optional, Dict, Any, List
from pathlib import Path
import tempfile
import time
import json

from config.logging_config import get_logger

logger = get_logger(__name__)


class PaddleOCRVLService:
    """
    Thread-safe wrapper for PaddleOCR-VL pipeline.
    Implements lazy initialization and manages the OCR pipeline lifecycle.
    """

    _instance: Optional["PaddleOCRVLService"] = None
    _lock = threading.Lock()
    _pipeline = None
    _initialized = False

    def __new__(cls):
        """Singleton pattern to ensure only one instance."""
        if cls._instance is None:
            with cls._lock:
                if cls._instance is None:
                    cls._instance = super().__new__(cls)
        return cls._instance

    def __init__(self):
        """Initialize the service (lazy loading)."""
        if not self._initialized:
            with self._lock:
                if not self._initialized:
                    logger.info("PaddleOCRVLService instance created (pipeline will be initialized on first use)")
                    self._initialized = True

    def _initialize_pipeline(self) -> None:
        """
        Initialize the PaddleOCR-VL pipeline.
        This is called lazily on first use to avoid loading models during startup.
        """
        if self._pipeline is not None:
            return

        with self._lock:
            if self._pipeline is not None:
                return

            logger.info("Initializing PaddleOCR-VL pipeline...")
            start_time = time.time()

            try:
                from paddleocr import PaddleOCRVL

                # Initialize pipeline (GPU usage is automatic based on CUDA availability)
                self._pipeline = PaddleOCRVL()

                elapsed = time.time() - start_time
                logger.info(f"PaddleOCR-VL pipeline initialized successfully in {elapsed:.2f}s")

            except Exception as e:
                logger.error(f"Failed to initialize PaddleOCR-VL pipeline: {e}")
                raise RuntimeError(f"PaddleOCR-VL initialization failed: {e}") from e

    def process_image(self, image_path: str) -> List[Dict[str, Any]]:
        """
        Process an image file and extract document structure.

        Args:
            image_path: Path to the image file

        Returns:
            List of raw PaddleOCR-VL results as dictionaries (using save_to_json())

        Raises:
            RuntimeError: If pipeline initialization or processing fails
        """
        # Ensure pipeline is initialized
        if self._pipeline is None:
            self._initialize_pipeline()

        try:
            start_time = time.time()
            logger.info(f"Processing image: {image_path}")

            # Run PaddleOCR-VL prediction
            output = self._pipeline.predict(image_path)

            # Convert results using the save_to_json() method
            results = []
            for res in output:
                # Create temp file for JSON output
                with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as tmp:
                    tmp_path = tmp.name

                # Save result to JSON file (returns None)
                res.save_to_json(save_path=tmp_path)

                # Read JSON file back
                with open(tmp_path, 'r') as f:
                    result_json = json.load(f)

                # Clean up temp file
                Path(tmp_path).unlink()

                results.append(result_json)

            elapsed = time.time() - start_time
            logger.info(f"Image processed successfully in {elapsed:.2f}s - Found {len(results)} results")

            return results

        except Exception as e:
            logger.error(f"Error processing image: {e}")
            raise RuntimeError(f"Image processing failed: {e}") from e

    def process_image_bytes(self, image_bytes: bytes, filename: str = "image.jpg") -> List[Dict[str, Any]]:
        """
        Process image from bytes.

        Args:
            image_bytes: Image file bytes
            filename: Original filename (for extension detection)

        Returns:
            List of OCR results with document structure

        Raises:
            RuntimeError: If processing fails
        """
        # Create temporary file
        suffix = Path(filename).suffix or ".jpg"
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as temp_file:
            temp_file.write(image_bytes)
            temp_path = temp_file.name

        try:
            # Process the temporary file
            results = self.process_image(temp_path)
            return results
        finally:
            # Clean up temporary file
            try:
                Path(temp_path).unlink()
            except Exception as e:
                logger.warning(f"Failed to delete temporary file {temp_path}: {e}")


    def is_ready(self) -> bool:
        """Check if the pipeline is initialized and ready."""
        return self._pipeline is not None

    def get_status(self) -> Dict[str, Any]:
        """Get service status information."""
        return {
            "initialized": self.is_ready()
        }


# Global service instance
paddleocr_vl_service = PaddleOCRVLService()
