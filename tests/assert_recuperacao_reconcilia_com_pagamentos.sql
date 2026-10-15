-- Teste singular: reconciliação financeira entre camadas.
-- O total recuperado no mart diário (pagamentos de parcelas em atraso + pagamentos de acordo)
-- tem que bater com a soma dos mesmos pagamentos na camada Raw. Se divergir (filtro perdido,
-- join duplicando linhas num refactor), o teste falha e o deploy para.
with mart as (

    select
        sum(valor_recuperado)   as valor_recuperado,
        sum(valor_pago_total)   as valor_pago_total
    from {{ ref('mart_recuperacao_diaria') }}

),

raw as (

    select
        sum(case
                when pagamentos.tipo_pagamento = 'acordo' then pagamentos.valor_pago
                when parcelas.dias_atraso > 0 then pagamentos.valor_pago
                else 0
            end)                    as valor_recuperado,
        sum(pagamentos.valor_pago)  as valor_pago_total
    from {{ ref('stg_cobranca__pagamentos') }} as pagamentos
    left join {{ ref('int_parcelas__aging') }} as parcelas
        on pagamentos.parcela_id = parcelas.parcela_id

)

select
    mart.valor_recuperado       as mart_valor_recuperado,
    raw.valor_recuperado        as raw_valor_recuperado,
    mart.valor_pago_total       as mart_valor_pago_total,
    raw.valor_pago_total        as raw_valor_pago_total
from mart
cross join raw
where abs(coalesce(mart.valor_recuperado, 0) - coalesce(raw.valor_recuperado, 0)) > 0.01
   or abs(coalesce(mart.valor_pago_total, 0) - coalesce(raw.valor_pago_total, 0)) > 0.01
