# Ingestão de exemplo: planilhas e API REST para o landing

Dois scripts pequenos que mostram como eu trataria a **borda** da plataforma: tirar o dado de onde ele
está (arquivo do credor, API do CRM ou da plataforma de acordos) e depositá-lo **imutável** no landing,
com linhagem e manifesto, sem nenhuma regra de negócio. O mesmo código roda local, no CI e em um
Cloud Run Job gravando em `gs://`.

| Script | Fonte | Saída no landing | O que demonstra |
|---|---|---|---|
| `ingest_planilha.py` | CSV (detecta `;` `,` tab) ou Excel (por aba) | CSV + `manifest.json` | normalização mínima de colunas, linhagem por linha (`_arquivo_origem`, `_linha_origem`, `_hash_linha`), hash do arquivo original |
| `ingest_api_rest.py` | API REST paginada com `updated_since` | JSON Lines + `manifest.json` + estado | extração incremental por marca d'água com sobreposição, paginação, retry com backoff em 429/5xx, token só por variável de ambiente |
| `mock_api.py` | (simula a API) | - | endpoint `GET /v1/acordos` com paginação, filtro incremental, autenticação Bearer e 429 periódico |
| `landing.py` | - | - | convenção de caminho `sistema/entidade/dt=AAAA-MM-DD/arquivo`, escrita local ou GCS (`if_generation_match=0` garante imutabilidade) |

## Rodar localmente

```bash
pip install pandas openpyxl requests
```

Planilha (CSV ou Excel):

```bash
python ingest/ingest_planilha.py seeds/raw_pagamentos.csv --sistema credor_banco_alfa --entidade pagamentos
```

```bash
python ingest/ingest_planilha.py remessa.xlsx --aba Contratos --sistema credor_varejo_gama --entidade contratos
```

API REST simulada (dois terminais, ou `&` no Linux):

```bash
python ingest/mock_api.py --porta 8089
```

```bash
API_TOKEN=teste python ingest/ingest_api_rest.py --url http://127.0.0.1:8089/v1/acordos --sistema plataforma_acordos --entidade acordos
```

Rode a segunda vez: só vem o que mudou depois da marca d'água salva em `landing/_estado/`.

Para gravar no Cloud Storage em vez da pasta local:

```bash
LANDING_URI=gs://meu-bucket-landing/cobranca python ingest/ingest_planilha.py ...
```

## Resultado de uma execução

```
landing/
├── credor_banco_alfa/pagamentos/dt=2026-10-15/
│   ├── pagamentos_20261015T002400.csv              (7.874 linhas)
│   └── pagamentos_20261015T002400.manifest.json
├── plataforma_acordos/acordos/dt=2026-10-15/
│   ├── acordos_20261015T002415.jsonl               (131 registros, 7 páginas: carga inicial)
│   ├── acordos_20261015T002415.manifest.json
│   ├── acordos_20261015T002417.jsonl               (1 registro: incremental)
│   └── acordos_20261015T002417.manifest.json
└── _estado/plataforma_acordos_acordos.json         (marca d'água)
```

## Do landing para o BigQuery

Na proposta de arquitetura (README da raiz), o passo seguinte é um `LOAD DATA` / `bq load` por
partição `dt=` para a tabela Raw correspondente (ou uma tabela externa sobre o prefixo, quando o
volume é pequeno), disparado pelo mesmo orquestrador que depois chama o `dbt build`. Neste
repositório, por rodar no sandbox gratuito, as tabelas Raw são carregadas como **seeds** do dbt a
partir dos mesmos CSVs.

## O que mudaria em produção

- **Segredos**: `API_TOKEN` vem do Secret Manager injetado no Cloud Run Job; nunca em arquivo.
- **Agendamento**: Cloud Scheduler -> Cloud Run Job (um job por fonte), ou um DAG no Composer quando
  houver dependência entre fontes.
- **Webhooks** (discador, bot, assinatura eletrônica): Cloud Run service recebendo o POST, validando a
  assinatura do fornecedor e publicando no Pub/Sub; um subscriber grava no landing em micro-lotes.
- **Oracle legado**: mesmo padrão, com `python-oracledb` e janela incremental por coluna de auditoria,
  negociada com o DBA (ver tabela de decisões no README).
- **Observabilidade**: cada manifesto vira uma linha em uma tabela de auditoria no BigQuery
  (`dbt source freshness` lê o `_extraido_em` mais recente de cada fonte).
