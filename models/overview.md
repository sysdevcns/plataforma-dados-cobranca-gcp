{% docs __overview__ %}
# Plataforma de dados de cobrança no GCP (Raw / Cleansed / Curated)

Projeto dbt sobre um dataset sintético de operação de cobrança: contratos, parcelas, acordos,
pagamentos e contatos de discador/bot/SMS/e-mail/URA.

| Camada dbt    | Medallion | Pasta                 | Materialização | Papel |
|---------------|-----------|-----------------------|----------------|-------|
| seeds raw_*   | Bronze    | `seeds/`              | table          | Landing: dado como chega das origens |
| staging       | Bronze    | `models/staging`      | view           | Renomeia, tipa, padroniza |
| intermediate  | Silver    | `models/intermediate` | view           | Aging, régua, status consolidado, efetividade |
| marts         | Gold      | `models/marts`        | table / incremental | Fatos, dimensões (LGPD) e marts de recuperação |

Veja o README do repositório para a proposta de arquitetura completa e as instruções de execução.
{% enddocs %}
