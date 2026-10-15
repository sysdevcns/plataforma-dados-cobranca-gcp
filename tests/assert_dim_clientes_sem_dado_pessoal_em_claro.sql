-- Teste singular (LGPD): nenhuma coluna da dimensão de clientes pode expor dado pessoal direto.
-- Verifica pelo catálogo do BigQuery que não existe coluna chamada cpf, email, nome ou telefone
-- e que as colunas mascaradas não contêm um CPF (11 dígitos) nem um e-mail (@).
{% set relation = ref('dim_clientes') %}

with colunas_proibidas as (

    select column_name as problema
    from `{{ relation.database }}.{{ relation.schema }}.INFORMATION_SCHEMA.COLUMNS`
    where table_name = '{{ relation.identifier }}'
      and lower(column_name) in ('cpf', 'email', 'e_mail', 'nome', 'nome_completo', 'telefone', 'celular', 'data_nascimento')

),

valores_em_claro as (

    select concat('cliente ', cliente_id, ' com valor em claro') as problema
    from {{ relation }}
    where regexp_contains(cpf_hash, r'^[0-9]{11}$')
       or regexp_contains(coalesce(email_hash, ''), '@')
       or regexp_contains(coalesce(nome_iniciais, ''), r'[A-Za-zÀ-ÿ]{3,}')

)

select * from colunas_proibidas
union all
select * from valores_em_claro
