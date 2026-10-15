{#-
  Faixas de atraso (aging) padronizadas para toda a plataforma.
  Centralizar aqui evita que cada mart invente a própria faixa e os números do MIS deixem de bater.
-#}
{% macro aging_bucket(dias_atraso) -%}
    case
        when {{ dias_atraso }} is null then 'sem_vencimento'
        when {{ dias_atraso }} <= 0   then 'a_vencer'
        when {{ dias_atraso }} <= 30  then '01-30'
        when {{ dias_atraso }} <= 60  then '31-60'
        when {{ dias_atraso }} <= 90  then '61-90'
        when {{ dias_atraso }} <= 180 then '91-180'
        when {{ dias_atraso }} <= 360 then '181-360'
        else '360+'
    end
{%- endmacro %}
