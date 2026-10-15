-- Raw / Bronze: parcelas originais dos contratos. Grão: 1 linha por parcela.
with source as (

    select * from {{ ref('raw_parcelas') }}

),

renamed as (

    select
        cast(parcela_id as string)          as parcela_id,
        cast(contrato_id as string)         as contrato_id,
        cast(numero_parcela as int64)       as numero_parcela,
        cast(data_vencimento as date)       as data_vencimento,
        cast(valor_parcela as numeric)      as valor_parcela,
        lower(trim(status_origem))          as status_origem
    from source

)

select * from renamed
