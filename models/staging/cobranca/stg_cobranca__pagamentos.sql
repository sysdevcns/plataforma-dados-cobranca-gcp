-- Raw / Bronze: pagamentos recebidos (baixa do credor e da plataforma de acordos).
-- Grão: 1 linha por pagamento. Um pagamento quita uma parcela original (parcela_id)
-- ou uma parcela de acordo (acordo_id + numero_parcela_acordo), nunca os dois.
with source as (

    select * from {{ ref('raw_pagamentos') }}

),

renamed as (

    select
        cast(pagamento_id as string)                    as pagamento_id,
        cast(contrato_id as string)                     as contrato_id,
        nullif(cast(parcela_id as string), '')          as parcela_id,
        nullif(cast(acordo_id as string), '')           as acordo_id,
        cast(numero_parcela_acordo as int64)            as numero_parcela_acordo,
        cast(data_pagamento as date)                    as data_pagamento,
        cast(valor_pago as numeric)                     as valor_pago,
        lower(trim(meio_pagamento))                     as meio_pagamento,
        lower(trim(origem))                             as origem,
        cast(recebido_em as timestamp)                  as recebido_em,
        case
            when nullif(cast(acordo_id as string), '') is not null then 'acordo'
            else 'parcela'
        end                                             as tipo_pagamento
    from source

)

select * from renamed
