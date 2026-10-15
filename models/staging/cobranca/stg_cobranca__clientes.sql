-- Raw / Bronze: cadastro de devedores como chega do CRM. Grão: 1 linha por cliente.
-- Só renomeia, tipa e padroniza: CPF sem máscara, e-mail em minúsculas, UF em maiúsculas.
-- O dado pessoal continua em claro nesta camada, que fica em dataset com acesso restrito;
-- o mascaramento acontece em dim_clientes (camada Curated).
with source as (

    select * from {{ ref('raw_clientes') }}

),

renamed as (

    select
        cast(cliente_id as string)                                  as cliente_id,
        trim(nome)                                                  as nome,
        regexp_replace(cast(cpf as string), r'[^0-9]', '')          as cpf,
        nullif(lower(trim(email)), '')                              as email,
        regexp_replace(cast(telefone as string), r'[^0-9]', '')     as telefone,
        cast(data_nascimento as date)                               as data_nascimento,
        upper(trim(uf))                                             as uf,
        cast(cep as string)                                         as cep,
        cast(renda_declarada as numeric)                            as renda_declarada,
        cast(data_cadastro as date)                                 as data_cadastro,
        cast(atualizado_em as timestamp)                            as atualizado_em
    from source

)

select * from renamed
