"""
API REST simulada de uma plataforma de acordos / CRM, para exercitar o ingest_api_rest.py sem
depender de um fornecedor real. Imita o que se encontra em APIs tipo Pipedrive/DocuSign:

  GET /v1/acordos?updated_since=<ISO>&page=<n>&limit=<n>
      -> {"data": [...], "page": 1, "has_more": true, "total": 131}
  Header obrigatório: Authorization: Bearer <token>   (qualquer token não vazio é aceito)
  A cada ~10 requisições responde 429 (rate limit) para testar o retry do cliente.

Os dados vêm de seeds/raw_acordos.csv (ou de --arquivo), com um campo updated_at para a
extração incremental.

Uso:
    python ingest/mock_api.py --porta 8089
"""
from __future__ import annotations

import argparse
import csv
import json
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

RAIZ = Path(__file__).resolve().parent.parent
CONTADOR = {"requisicoes": 0}
REGISTROS: list[dict] = []


def carregar(arquivo: Path) -> list[dict]:
    with arquivo.open(encoding="utf-8") as f:
        linhas = list(csv.DictReader(f))
    for linha in linhas:
        linha["updated_at"] = linha.get("atualizado_em") or linha.get("data_acordo")
        linha["id"] = linha.get("acordo_id")
    return sorted(linhas, key=lambda r: (r["updated_at"], r["id"]))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # silencia o log padrão
        pass

    def _json(self, status: int, corpo: dict, extra_headers: dict | None = None) -> None:
        dados = json.dumps(corpo, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(dados)))
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(dados)

    def do_GET(self) -> None:
        url = urlparse(self.path)
        if url.path != "/v1/acordos":
            return self._json(404, {"error": "not found"})
        if not self.headers.get("Authorization", "").startswith("Bearer ") or \
                len(self.headers.get("Authorization", "")) <= len("Bearer "):
            return self._json(401, {"error": "unauthorized"})

        CONTADOR["requisicoes"] += 1
        if CONTADOR["requisicoes"] % 10 == 0:
            return self._json(429, {"error": "rate limit"}, {"Retry-After": "1"})

        q = parse_qs(url.query)
        limite = min(int(q.get("limit", ["50"])[0]), 200)
        pagina = max(int(q.get("page", ["1"])[0]), 1)
        desde = q.get("updated_since", [None])[0]

        registros = REGISTROS
        if desde:
            try:
                datetime.fromisoformat(desde)
            except ValueError:
                return self._json(400, {"error": "updated_since inválido (use ISO 8601)"})
            registros = [r for r in registros if r["updated_at"] > desde]

        inicio = (pagina - 1) * limite
        fatia = registros[inicio:inicio + limite]
        self._json(200, {
            "data": fatia,
            "page": pagina,
            "limit": limite,
            "total": len(registros),
            "has_more": inicio + limite < len(registros),
        })


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--porta", type=int, default=8089)
    ap.add_argument("--arquivo", type=Path, default=RAIZ / "seeds" / "raw_acordos.csv")
    args = ap.parse_args()
    REGISTROS.extend(carregar(args.arquivo))
    servidor = ThreadingHTTPServer(("127.0.0.1", args.porta), Handler)
    print(f"mock API em http://127.0.0.1:{args.porta}/v1/acordos ({len(REGISTROS)} registros)", flush=True)
    try:
        servidor.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
