{#-
  Mascaramento de dado pessoal (LGPD) por hash SHA-256 com sal.

  O hash preserva a capacidade de join/deduplicação entre tabelas (o mesmo CPF gera o mesmo hash)
  sem expor o valor original na camada Curated. O sal vem da var pii_salt, que em produção é
  injetada a partir do Secret Manager; sem sal, um CPF (11 dígitos) é trivialmente reversível
  por força bruta.

  Uso:  {{ hash_pii('cpf') }} as cpf_hash
-#}
{% macro hash_pii(column_name) -%}
    case
        when {{ column_name }} is null then null
        else to_hex(sha256(concat(cast({{ column_name }} as string), '{{ var("pii_salt") }}')))
    end
{%- endmacro %}
