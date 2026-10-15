"""
Camada de landing: grava arquivos imutáveis em uma pasta local ou em um bucket do Cloud Storage.

Convenção de caminho (igual nos dois destinos):
    <raiz>/<sistema_origem>/<entidade>/dt=<AAAA-MM-DD>/<entidade>_<AAAAMMDDTHHMMSS>.<ext>

  * um arquivo por execução, nunca sobrescrito: reprocessar é reler o arquivo, não refazer a extração;
  * a partição dt= é a data da extração (não a data do negócio), o que simplifica auditoria e replay;
  * o mesmo código roda local (desenvolvimento, CI) e em produção (Cloud Run Job gravando em gs://).

Escolha do destino pela variável de ambiente LANDING_URI:
    LANDING_URI=./landing                       (padrão: pasta local)
    LANDING_URI=gs://meu-bucket-landing/cobranca (Cloud Storage; exige google-cloud-storage e credenciais)
"""
from __future__ import annotations

import io
import json
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class ArquivoGravado:
    uri: str
    linhas: int
    bytes: int


class Landing:
    def __init__(self, raiz: str | None = None) -> None:
        self.raiz = (raiz or os.environ.get("LANDING_URI") or "./landing").rstrip("/")
        self.is_gcs = self.raiz.startswith("gs://")
        if self.is_gcs:
            from google.cloud import storage  # importado só quando necessário

            bucket, _, prefixo = self.raiz[len("gs://"):].partition("/")
            self._bucket = storage.Client().bucket(bucket)
            self._prefixo = prefixo.strip("/")

    # ------------------------------------------------------------------ caminhos
    def caminho(self, sistema: str, entidade: str, extensao: str, quando: datetime | None = None) -> str:
        quando = quando or datetime.now(timezone.utc)
        return (f"{sistema}/{entidade}/dt={quando:%Y-%m-%d}/"
                f"{entidade}_{quando:%Y%m%dT%H%M%S}.{extensao}")

    # ------------------------------------------------------------------ gravação
    def gravar_bytes(self, caminho_relativo: str, conteudo: bytes, content_type: str) -> str:
        if self.is_gcs:
            nome = f"{self._prefixo}/{caminho_relativo}" if self._prefixo else caminho_relativo
            blob = self._bucket.blob(nome)
            blob.upload_from_string(conteudo, content_type=content_type, if_generation_match=0)
            return f"gs://{self._bucket.name}/{nome}"
        destino = Path(self.raiz) / caminho_relativo
        destino.parent.mkdir(parents=True, exist_ok=True)
        if destino.exists():
            raise FileExistsError(f"landing é imutável; já existe {destino}")
        destino.write_bytes(conteudo)
        return str(destino)

    def gravar_jsonl(self, sistema: str, entidade: str, registros: Iterable[dict],
                     quando: datetime | None = None) -> ArquivoGravado:
        """JSON Lines: uma linha por registro, formato que o BigQuery carrega direto (NEWLINE_DELIMITED_JSON)."""
        buffer = io.StringIO()
        linhas = 0
        for registro in registros:
            buffer.write(json.dumps(registro, ensure_ascii=False, default=str))
            buffer.write("\n")
            linhas += 1
        dados = buffer.getvalue().encode("utf-8")
        uri = self.gravar_bytes(self.caminho(sistema, entidade, "jsonl", quando), dados, "application/x-ndjson")
        return ArquivoGravado(uri, linhas, len(dados))

    def gravar_csv(self, sistema: str, entidade: str, dataframe, quando: datetime | None = None) -> ArquivoGravado:
        """CSV UTF-8 com cabeçalho, pronto para `bq load --autodetect` ou para seed/external table."""
        dados = dataframe.to_csv(index=False, lineterminator="\n").encode("utf-8")
        uri = self.gravar_bytes(self.caminho(sistema, entidade, "csv", quando), dados, "text/csv")
        return ArquivoGravado(uri, len(dataframe), len(dados))

    def gravar_manifesto(self, sistema: str, entidade: str, meta: dict, quando: datetime | None = None) -> str:
        """Manifesto ao lado do arquivo de dados: origem, janela extraída, contagem, hash. Base da auditoria."""
        meta = {"gravado_em": datetime.now(timezone.utc).isoformat(), **meta}
        return self.gravar_bytes(self.caminho(sistema, entidade, "manifest.json", quando),
                                 json.dumps(meta, ensure_ascii=False, indent=2, default=str).encode("utf-8"),
                                 "application/json")
