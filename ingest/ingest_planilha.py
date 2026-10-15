"""
Ingestão de planilha (CSV ou Excel) para o landing.

Caso típico em cobrança: o credor manda o arquivo de baixa de pagamentos ou a remessa de
novos contratos por SFTP/e-mail, em CSV ou Excel, com layout que muda sem aviso. Este script:

  1. lê o arquivo com pandas (CSV com detecção de separador, ou Excel por aba);
  2. normaliza só o que é seguro normalizar na borda: nomes de coluna em snake_case,
     remoção de linhas totalmente vazias, tudo como texto (tipagem é papel da camada Raw no dbt);
  3. acrescenta colunas de linhagem (_arquivo_origem, _linha_origem, _extraido_em, _hash_linha);
  4. grava CSV imutável no landing + manifesto com contagem e hash do arquivo original.

Nada é validado contra regras de negócio aqui: se o arquivo chegou, ele é preservado como chegou.
Validação acontece no dbt (testes de staging), onde a falha fica visível e rastreável.

Uso:
    python ingest/ingest_planilha.py seeds/raw_pagamentos.csv --sistema credor_banco_alfa --entidade pagamentos
    python ingest/ingest_planilha.py remessa.xlsx --aba Contratos --sistema credor_varejo_gama --entidade contratos
    LANDING_URI=gs://bucket/landing python ingest/ingest_planilha.py ...
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from landing import Landing  # noqa: E402


def snake_case(nome: str) -> str:
    sem_acento = unicodedata.normalize("NFKD", str(nome)).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "_", sem_acento.strip().lower()).strip("_") or "coluna_sem_nome"


def ler_planilha(caminho: Path, aba: str | int | None) -> pd.DataFrame:
    if caminho.suffix.lower() in (".xlsx", ".xlsm", ".xls"):
        return pd.read_excel(caminho, sheet_name=aba if aba is not None else 0, dtype=str)
    # sep=None + engine python detecta ; , ou tab (credor brasileiro costuma mandar ;)
    return pd.read_csv(caminho, sep=None, engine="python", dtype=str, encoding="utf-8-sig")


def preparar(df: pd.DataFrame, arquivo: str, extraido_em: datetime) -> pd.DataFrame:
    df = df.dropna(how="all").copy()
    df.columns = [snake_case(c) for c in df.columns]
    df = df.fillna("")
    df["_linha_origem"] = range(2, len(df) + 2)  # linha no arquivo (1 = cabeçalho)
    df["_arquivo_origem"] = arquivo
    df["_extraido_em"] = extraido_em.isoformat()
    df["_hash_linha"] = [
        hashlib.sha256("|".join(map(str, linha)).encode("utf-8")).hexdigest()[:16]
        for linha in df.drop(columns=["_linha_origem", "_arquivo_origem", "_extraido_em"]).itertuples(index=False)
    ]
    return df


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("arquivo", type=Path, help="CSV ou Excel de entrada")
    ap.add_argument("--sistema", required=True, help="sistema/credor de origem (vira pasta no landing)")
    ap.add_argument("--entidade", required=True, help="entidade do arquivo: contratos, pagamentos, ...")
    ap.add_argument("--aba", default=None, help="nome ou índice da aba (Excel)")
    ap.add_argument("--landing", default=None, help="raiz do landing (padrão: env LANDING_URI ou ./landing)")
    args = ap.parse_args()

    extraido_em = datetime.now(timezone.utc)
    bruto = args.arquivo.read_bytes()
    df = preparar(ler_planilha(args.arquivo, args.aba), args.arquivo.name, extraido_em)

    landing = Landing(args.landing)
    gravado = landing.gravar_csv(args.sistema, args.entidade, df, extraido_em)
    manifesto = landing.gravar_manifesto(args.sistema, args.entidade, {
        "tipo": "planilha",
        "arquivo_origem": args.arquivo.name,
        "aba": args.aba,
        "bytes_origem": len(bruto),
        "sha256_origem": hashlib.sha256(bruto).hexdigest(),
        "linhas": gravado.linhas,
        "colunas": [c for c in df.columns if not c.startswith("_")],
        "arquivo_landing": gravado.uri,
    }, extraido_em)
    print(f"landing: {gravado.uri} ({gravado.linhas:,} linhas, {gravado.bytes:,} bytes)")
    print(f"manifesto: {manifesto}")


if __name__ == "__main__":
    main()
