{#-
  Teste genérico customizado: garante que a coluna testada nunca é anterior a outra coluna
  da mesma linha (ex.: delivered_at não pode ser antes de shipped_at).
  Linhas com qualquer um dos dois valores nulos são ignoradas.

  Uso no YAML:
      - name: delivered_at
        data_tests:
          - date_not_before:
              compared_to: shipped_at
-#}
{% test date_not_before(model, column_name, compared_to) %}

select
    {{ column_name }} as tested_value,
    {{ compared_to }} as compared_value
from {{ model }}
where {{ column_name }} is not null
  and {{ compared_to }} is not null
  and {{ column_name }} < {{ compared_to }}

{% endtest %}
