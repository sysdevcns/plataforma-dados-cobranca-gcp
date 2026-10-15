-- Raw / Bronze: tentativas de contato dos fornecedores de discador, bot, SMS, e-mail e URA.
-- Grão: 1 linha por tentativa. Em produção cada fornecedor chega por um webhook/arquivo próprio
-- e esta view é o ponto em que os layouts diferentes viram um único esquema.
with source as (

    select * from {{ ref('raw_contatos') }}

),

renamed as (

    select
        cast(contato_id as string)                          as contato_id,
        cast(contrato_id as string)                         as contrato_id,
        cast(cliente_id as string)                          as cliente_id,
        cast(data_hora_contato as timestamp)                as data_hora_contato,
        date(cast(data_hora_contato as timestamp))          as data_contato,
        lower(trim(canal))                                  as canal,
        trim(fornecedor)                                    as fornecedor,
        lower(trim(resultado))                              as resultado,
        cast(duracao_seg as int64)                          as duracao_seg,
        nullif(cast(operador_id as string), '')             as operador_id,
        upper(trim(campanha))                               as campanha,
        cast(custo_unitario as numeric)                     as custo_unitario
    from source

)

select * from renamed
