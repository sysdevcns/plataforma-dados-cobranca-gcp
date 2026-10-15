"""
Ingestão incremental de uma API REST paginada (CRM, plataforma de acordos, assinatura eletrônica)
para o landing, em JSON Lines.

O que este cliente faz, e que vale para qualquer API de fornecedor:

  * extração incremental por cursor de tempo (updated_since): a última marca d'água fica em um
    arquivo de estado (local ou no próprio bucket), e cada execução pede só o que mudou desde então,
    com uma sobreposição de segurança (--sobreposicao-min) para não perder registros atualizados
    no limite da janela;
  * paginação até has_more = false, com limite de páginas por execução como trava de segurança;
  * retry com backoff exponencial em 429/5xx e respeito ao header Retry-After;
  * token lido de variável de ambiente (API_TOKEN), nunca de argumento nem de arquivo versionado;
  * payload gravado como veio (JSON cru por registro) + metadados de linhagem por linha
    (_extraido_em, _pagina, _fonte). Achatar/tipar é papel do dbt na camada Raw.

Uso (com o mock local):
    python ingest/mock_api.py --porta 8089          # em outro terminal
    API_TOKEN=teste python ingest/ingest_api_rest.py --url http://127.0.0.1:8089/v1/acordos \
        --sistema plataforma_acordos --entidade acordos
    # segunda execução: só traz o que mudou depois da marca d'água salva em landing/_estado/
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests

sys.path.insert(0, str(Path(__file__).resolve().parent))
from landing import Landing  # noqa: E402


class ClienteApi:
    def __init__(self, url: str, token: str, timeout: int = 30, max_tentativas: int = 5) -> None:
        self.url = url
        self.sessao = requests.Session()
        self.sessao.headers.update({"Authorization": f"Bearer {token}", "Accept": "application/json"})
        self.timeout = timeout
        self.max_tentativas = max_tentativas

    def get(self, params: dict) -> dict:
        espera = 1.0
        for tentativa in range(1, self.max_tentativas + 1):
            resposta = self.sessao.get(self.url, params=params, timeout=self.timeout)
            if resposta.status_code == 200:
                return resposta.json()
            if resposta.status_code in (429, 500, 502, 503, 504) and tentativa < self.max_tentativas:
                pausa = float(resposta.headers.get("Retry-After", espera))
                print(f"  HTTP {resposta.status_code} na página {params.get('page')}; "
                      f"tentativa {tentativa}/{self.max_tentativas}, aguardando {pausa:.0f}s", flush=True)
                time.sleep(pausa)
                espera = min(espera * 2, 30)
                continue
            resposta.raise_for_status()
        raise RuntimeError(f"API indisponível após {self.max_tentativas} tentativas")

    def paginar(self, updated_since: str | None, limite: int, max_paginas: int):
        pagina = 1
        while pagina <= max_paginas:
            params = {"page": pagina, "limit": limite}
            if updated_since:
                params["updated_since"] = updated_since
            corpo = self.get(params)
            registros = corpo.get("data", [])
            yield pagina, registros
            if not corpo.get("has_more") or not registros:
                return
            pagina += 1
        raise RuntimeError(f"limite de {max_paginas} páginas atingido; aumente --max-paginas ou reduza a janela")


def ler_estado(caminho: Path) -> dict:
    return json.loads(caminho.read_text(encoding="utf-8")) if caminho.exists() else {}


def gravar_estado(caminho: Path, estado: dict) -> None:
    caminho.parent.mkdir(parents=True, exist_ok=True)
    caminho.write_text(json.dumps(estado, indent=2, ensure_ascii=False), encoding="utf-8")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", required=True, help="endpoint de listagem, ex.: https://api.exemplo.com/v1/acordos")
    ap.add_argument("--sistema", required=True, help="sistema de origem (vira pasta no landing)")
    ap.add_argument("--entidade", required=True, help="entidade extraída: acordos, deals, envelopes, ...")
    ap.add_argument("--landing", default=None, help="raiz do landing (padrão: env LANDING_URI ou ./landing)")
    ap.add_argument("--estado", default=None, help="arquivo de estado da marca d'água (padrão: <landing>/_estado/<sistema>_<entidade>.json)")
    ap.add_argument("--desde", default=None, help="força a marca d'água inicial (ISO 8601); ignora o estado salvo")
    ap.add_argument("--sobreposicao-min", type=int, default=30, help="minutos de sobreposição sobre a marca d'água")
    ap.add_argument("--limite", type=int, default=100, help="registros por página")
    ap.add_argument("--max-paginas", type=int, default=1000)
    args = ap.parse_args()

    token = os.environ.get("API_TOKEN")
    if not token:
        sys.exit("defina API_TOKEN no ambiente (em produção: Secret Manager -> variável do Cloud Run Job)")

    landing = Landing(args.landing)
    raiz_local = Path(landing.raiz if not landing.is_gcs else "./landing")
    caminho_estado = Path(args.estado) if args.estado else raiz_local / "_estado" / f"{args.sistema}_{args.entidade}.json"
    estado = ler_estado(caminho_estado)

    if args.desde:
        updated_since = args.desde
    elif estado.get("marca_dagua"):
        marca = datetime.fromisoformat(estado["marca_dagua"])
        updated_since = (marca - timedelta(minutes=args.sobreposicao_min)).isoformat()
    else:
        updated_since = None  # carga inicial completa

    extraido_em = datetime.now(timezone.utc)
    cliente = ClienteApi(args.url, token)
    registros, maior_updated, paginas = [], estado.get("marca_dagua"), 0
    print(f"extraindo {args.url} updated_since={updated_since or '(carga inicial)'}", flush=True)
    for pagina, lote in cliente.paginar(updated_since, args.limite, args.max_paginas):
        paginas = pagina
        for r in lote:
            registros.append({**r, "_extraido_em": extraido_em.isoformat(), "_pagina": pagina, "_fonte": args.url})
            if r.get("updated_at") and (maior_updated is None or r["updated_at"] > maior_updated):
                maior_updated = r["updated_at"]
        print(f"  página {pagina}: {len(lote)} registros", flush=True)

    if not registros:
        print("nada novo desde a última execução; landing não alterado")
        return

    gravado = landing.gravar_jsonl(args.sistema, args.entidade, registros, extraido_em)
    manifesto = landing.gravar_manifesto(args.sistema, args.entidade, {
        "tipo": "api_rest",
        "url": args.url,
        "updated_since": updated_since,
        "paginas": paginas,
        "linhas": gravado.linhas,
        "marca_dagua_nova": maior_updated,
        "arquivo_landing": gravado.uri,
    }, extraido_em)
    gravar_estado(caminho_estado, {"marca_dagua": maior_updated, "ultima_execucao": extraido_em.isoformat(),
                                   "ultimo_arquivo": gravado.uri})
    print(f"landing: {gravado.uri} ({gravado.linhas:,} registros em {paginas} páginas)")
    print(f"manifesto: {manifesto}")
    print(f"estado: {caminho_estado} (marca d'água = {maior_updated})")


if __name__ == "__main__":
    main()
