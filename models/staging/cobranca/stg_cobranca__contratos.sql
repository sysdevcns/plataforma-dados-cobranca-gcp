-- Raw / Bronze: contratos cedidos pelos credores. Grão: 1 linha por contrato.
-- "credor" vira "carteira", o termo usado pela operação de cobrança.
with source as (

    select * from {{ ref('raw_contratos') }}

),

renamed as (

    select
        cast(contrato_id as string)             as contrato_id,
        cast(cliente_id as string)              as cliente_id,
        trim(credor)                            as carteira,
        lower(trim(produto))                    as produto,
        cast(valor_contratado as numeric)       as valor_contratado,
        cast(data_contratacao as date)          as data_contratacao,
        cast(data_cessao as date)               as data_cessao,
        cast(qtd_parcelas as int64)             as qtd_parcelas,
        cast(valor_parcela as numeric)          as valor_parcela,
        lower(trim(status_crm))                 as status_crm,
        cast(atualizado_em as timestamp)        as atualizado_em
    from source

)

select * from renamed
