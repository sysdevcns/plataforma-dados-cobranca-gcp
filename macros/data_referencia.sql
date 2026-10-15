{#-
  Data de corte para cálculo de atraso, aging e régua.

  Por padrão é a data atual em America/Sao_Paulo (fechamento diário da operação). Pode ser
  fixada via var para reprocessar uma "foto" do passado ou para tornar testes determinísticos:
      dbt build --vars '{data_referencia: "2026-09-30"}'
-#}
{% macro data_referencia() -%}
    {%- if var('data_referencia', none) -%}
        date('{{ var("data_referencia") }}')
    {%- else -%}
        current_date('America/Sao_Paulo')
    {%- endif -%}
{%- endmacro %}
