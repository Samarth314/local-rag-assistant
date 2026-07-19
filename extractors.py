"""Convert supported file types into plain text."""

from pathlib import Path


def extract_text(path: Path) -> str:
    ext = path.suffix.lower()

    if ext == ".pdf":
        return _extract_pdf(path)
    if ext == ".docx":
        return _extract_docx(path)
    if ext == ".xlsx":
        return _extract_xlsx(path)

    # Plain text / code / config files
    return path.read_text(encoding="utf-8", errors="ignore")


def _extract_pdf(path: Path) -> str:
    import fitz  # PyMuPDF

    doc = fitz.open(path)
    try:
        pages = []
        for page in doc:
            text = page.get_text()
            if len(text.strip()) < 20:
                # Little/no text layer -- likely a scanned or image-based
                # page. Fall back to OCR via Apple's Vision framework.
                ocr_text = _ocr_page(page)
                if ocr_text:
                    text = ocr_text
            pages.append(text)
        return "\n\n".join(pages)
    finally:
        doc.close()


def _ocr_page(page) -> str:
    """OCR a rendered PDF page. Backends are tried in order of preference so
    the same code runs on the Mac (Apple Vision) and on Linux/Jetson
    (RapidOCR: `pip install rapidocr-onnxruntime`). OCR is best-effort -- a
    page no backend can handle just contributes no text."""
    import io
    import sys

    try:
        from PIL import Image

        pix = page.get_pixmap(dpi=200)
        image = Image.open(io.BytesIO(pix.tobytes("png")))
    except Exception:
        return ""

    if sys.platform == "darwin":
        try:
            from ocrmac import ocrmac

            results = ocrmac.OCR(image, recognition_level="accurate").recognize()
            return "\n".join(text for text, confidence, bbox in results)
        except Exception:
            pass

    try:
        import numpy as np

        result, _ = _rapidocr_engine()(np.array(image))
        if result:
            return "\n".join(line[1] for line in result)
    except Exception:
        pass
    return ""


_RAPIDOCR = None


def _rapidocr_engine():
    global _RAPIDOCR
    if _RAPIDOCR is None:
        from rapidocr_onnxruntime import RapidOCR

        _RAPIDOCR = RapidOCR()
    return _RAPIDOCR


def _extract_docx(path: Path) -> str:
    import docx

    doc = docx.Document(str(path))
    return "\n\n".join(p.text for p in doc.paragraphs if p.text.strip())


def _extract_xlsx(path: Path) -> str:
    import openpyxl

    wb = openpyxl.load_workbook(str(path), data_only=True, read_only=True)
    lines = []
    for sheet in wb.worksheets:
        for row in sheet.iter_rows(values_only=True):
            cells = [str(c) for c in row if c is not None]
            if cells:
                lines.append(" | ".join(cells))
    return "\n".join(lines)
