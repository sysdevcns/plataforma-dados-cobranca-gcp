"""
Gera docs/proposta-peopleware.pdf a partir de docs/proposta-peopleware.html usando o Microsoft Word
(COM, só Windows). Depois confere com pdfplumber que o PDF tem no máximo 2 páginas e texto legível.

Uso:
    python scripts/gerar_pdf_proposta.py
"""
import os
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
HTML = RAIZ / "docs" / "proposta-peopleware.html"
DOCX = RAIZ / "docs" / "proposta-peopleware.docx"
PDF = RAIZ / "docs" / "proposta-peopleware.pdf"


def gerar() -> int:
    import win32com.client as win32

    word = win32.gencache.EnsureDispatch("Word.Application")
    word.Visible = False
    word.DisplayAlerts = 0
    doc = word.Documents.Open(str(HTML), ConfirmConversions=False, ReadOnly=True, AddToRecentFiles=False,
                              Encoding=65001)
    try:
        ps = doc.PageSetup
        ps.PaperSize = 7  # A4
        ps.TopMargin = ps.BottomMargin = 28   # ~1,0 cm
        ps.LeftMargin = ps.RightMargin = 40   # ~1,4 cm
        ps.HeaderDistance = ps.FooterDistance = 8
        doc.SaveAs2(str(DOCX), FileFormat=16)
        doc.SaveAs2(str(PDF), FileFormat=17)
        paginas = doc.ComputeStatistics(2)
    finally:
        doc.Close(False)
        if word.Documents.Count == 0:
            word.Quit()
    return paginas


def conferir() -> None:
    import pdfplumber

    with pdfplumber.open(PDF) as pdf:
        n = len(pdf.pages)
        texto = "\n".join((p.extract_text() or "") for p in pdf.pages)
    print(f"{PDF.name}: {n} página(s), {len(texto):,} caracteres, {os.path.getsize(PDF):,} bytes")
    for trecho in ("Plataforma de dados de cobrança", "Plano de 90 dias", "Riscos e mitigações",
                   "Sidney Moraes", "linkedin.com/in/sid-moraes", "PASS=177"):
        print(f"  {'ok ' if trecho in texto else 'FALTA'} {trecho}")
    if n > 2:
        sys.exit(f"PDF com {n} páginas; o limite é 2. Reduza o conteúdo ou a fonte em {HTML.name}.")


if __name__ == "__main__":
    print("páginas segundo o Word:", gerar())
    conferir()
