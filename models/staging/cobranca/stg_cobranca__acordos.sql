-- Raw / Bronze: acordos de renegociação registrados na plataforma de negociação / CRM.
-- Grão: 1 linha por acordo. status_crm é o status informado pela origem (nem sempre atualizado);
-- o status consolidado é recalculado a partir dos pagamentos em int_acordos__status.
with source as (

    select * from {{ ref('raw_acordos') }}

),

renamed as (

    select
        cast(acordo_id as string)               as acordo_id,
        cast(contrato_id as string)             as contrato_id,
        cast(cliente_id as string)              as cliente_id,
        cast(data_acordo as date)               as data_acordo,
        lower(trim(canal_origem))               as canal_origem,
        cast(valor_divida as numeric)           as valor_divida,
        cast(desconto_pct as numeric)           as desconto_pct,
        cast(valor_acordo as numeric)           as valor_acordo,
        cast(valor_entrada as numeric)          as valor_entrada,
        cast(qtd_parcelas as int64)             as qtd_parcelas,
        lower(trim(status_crm))                 as status_crm,
        cast(atualizado_em as timestamp)        as atualizado_em
    from source

)

select * from renamed
