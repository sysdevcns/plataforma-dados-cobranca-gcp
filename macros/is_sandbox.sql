{#-
  Indica se o alvo atual é o sandbox gratuito do BigQuery.

  Por que existe: no sandbox todo dataset nasce com expiração de partição de 60 dias
  e isso não pode ser alterado sem ativar faturamento. Em uma tabela particionada por
  data, as partições mais antigas que 60 dias são descartadas no momento da gravação,
  o que quebra o histórico (e os testes de integridade referencial entre fato e dimensão).

  Em modo sandbox os marts são materializados como tabela sem particionamento (apenas
  clustering). Fora do sandbox (prod, ou dev com --vars '{bigquery_sandbox: false}'),
  valem particionamento e incremental conforme documentado em cada modelo.

  Uso em config():
      partition_by = none if is_sandbox() else {...}
      materialized = 'table' if is_sandbox() else 'incremental'
-#}
{% macro is_sandbox() %}
    {{ return(var('bigquery_sandbox', target.name == 'dev')) }}
{% endmacro %}
