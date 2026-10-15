-- Curated / Gold: fechamento diário da recuperação por carteira, pronto para o MIS e para o BI.
-- Grão: 1 linha por (data_referencia, carteira).
--
-- Para cada dia D a tabela responde: quanto havia vencido no início do dia (por faixa de aging),
-- quanto entrou de pagamento em atraso e de acordo no dia, quantos acordos foram fechados e qual
-- foi a taxa de recuperação. O "quanto havia vencido" é reconstruído a partir da fato de parcelas
-- (vencimento, pagamento e acordo), então a tabela pode ser recriada do zero a qualquer momento
-- sem depender de snapshot do sistema de origem.
--
-- Simplificação documentada: parcela coberta por acordo que depois quebrou volta ao aging desde o
-- início; parcela coberta por acordo ativo ou quitado sai do aging a partir da data do acordo.
--
-- Fora do sandbox: particionada por data_referencia (dia) e clusterizada por carteira.
{{
    config(
        materialized='table',
        partition_by=(none if is_sandbox() else {
            'field': 'data_referencia',
            'data_type': 'date',
            'granularity': 'day'
        }),
        cluster_by=['carteira']
    )
}}

with parcelas as (

    select * from {{ ref('fct_parcelas') }}

),

pagamentos as (

    select
        pagamentos.contrato_id,
        pagamentos.parcela_id,
        pagamentos.data_pagamento,
        pagamentos.valor_pago,
        pagamentos.tipo_pagamento,
        contratos.carteira
    from {{ ref('stg_cobranca__pagamentos') }} as pagamentos
    inner join {{ ref('stg_cobranca__contratos') }} as contratos
        on pagamentos.contrato_id = contratos.contrato_id

),

acordos as (

    select
        acordos.contrato_id,
        acordos.data_acordo,
        acordos.valor_divida,
        acordos.valor_acordo,
        acordos.canal_origem,
        contratos.carteira
    from {{ ref('stg_cobranca__acordos') }} as acordos
    inner join {{ ref('stg_cobranca__contratos') }} as contratos
        on acordos.contrato_id = contratos.contrato_id

),

limites as (

    -- do primeiro vencimento (ou primeiro pagamento, se antecipado) até a data de referência
    select
        least(min(parcelas.data_vencimento), min(pagamentos.data_pagamento))  as data_inicio,
        max(parcelas.data_referencia)                                         as data_fim
    from parcelas
    cross join pagamentos

),

dias as (

    -- um dia por linha, do primeiro vencimento até a data de referência (nativo do BigQuery)
    select data_referencia
    from limites
    cross join unnest(generate_date_array(limites.data_inicio, limites.data_fim)) as data_referencia

),

carteiras as (

    select distinct carteira from parcelas

),

spine as (

    select
        dias.data_referencia,
        carteiras.carteira
    from dias
    cross join carteiras

),

-- Saldo vencido no início de cada dia D: parcela vencida antes de D que em D ainda não tinha
-- sido paga (valor integral) ou que foi paga só parcialmente (saldo restante), e que não estava
-- coberta por acordo vigente em D.
parcelas_por_dia as (

    select
        spine.data_referencia,
        spine.carteira,
        parcelas.parcela_id,
        parcelas.contrato_id,
        date_diff(spine.data_referencia, parcelas.data_vencimento, day)     as dias_atraso_em_d,
        case
            when parcelas.data_pagamento is null or parcelas.data_pagamento >= spine.data_referencia
                then parcelas.valor_parcela
            else parcelas.saldo_aberto
        end                                                                 as saldo_em_d
    from spine
    inner join parcelas
        on spine.carteira = parcelas.carteira
        and parcelas.data_vencimento < spine.data_referencia
        and (parcelas.data_pagamento is null
             or parcelas.data_pagamento >= spine.data_referencia
             or parcelas.saldo_aberto > 0)
        and not (parcelas.is_renegociada and parcelas.data_acordo < spine.data_referencia)

),

aging_diario as (

    select
        spine.data_referencia,
        spine.carteira,
        count(parcelas_por_dia.parcela_id)                                      as parcelas_vencidas,
        count(distinct parcelas_por_dia.contrato_id)                            as contratos_vencidos,
        sum(parcelas_por_dia.saldo_em_d)                                        as saldo_vencido,
        sum(case when parcelas_por_dia.dias_atraso_em_d <= 30
                 then parcelas_por_dia.saldo_em_d else 0 end)                   as saldo_vencido_01_30,
        sum(case when parcelas_por_dia.dias_atraso_em_d between 31 and 60
                 then parcelas_por_dia.saldo_em_d else 0 end)                   as saldo_vencido_31_60,
        sum(case when parcelas_por_dia.dias_atraso_em_d between 61 and 90
                 then parcelas_por_dia.saldo_em_d else 0 end)                   as saldo_vencido_61_90,
        sum(case when parcelas_por_dia.dias_atraso_em_d between 91 and 180
                 then parcelas_por_dia.saldo_em_d else 0 end)                   as saldo_vencido_91_180,
        sum(case when parcelas_por_dia.dias_atraso_em_d between 181 and 360
                 then parcelas_por_dia.saldo_em_d else 0 end)                   as saldo_vencido_181_360,
        sum(case when parcelas_por_dia.dias_atraso_em_d > 360
                 then parcelas_por_dia.saldo_em_d else 0 end)                   as saldo_vencido_360_mais
    from spine
    left join parcelas_por_dia
        on spine.data_referencia = parcelas_por_dia.data_referencia
        and spine.carteira = parcelas_por_dia.carteira
    group by spine.data_referencia, spine.carteira

),

recuperado_diario as (

    select
        pagamentos.data_pagamento                                               as data_referencia,
        pagamentos.carteira,
        sum(case when pagamentos.tipo_pagamento = 'acordo' then pagamentos.valor_pago else 0 end)
                                                                                as valor_recuperado_acordos,
        sum(case when pagamentos.tipo_pagamento = 'parcela' and parcelas.dias_atraso > 0
                 then pagamentos.valor_pago else 0 end)                         as valor_recuperado_parcelas,
        sum(case when pagamentos.tipo_pagamento = 'parcela' and parcelas.dias_atraso <= 0
                 then pagamentos.valor_pago else 0 end)                         as valor_pago_em_dia,
        sum(pagamentos.valor_pago)                                              as valor_pago_total
    from pagamentos
    left join parcelas
        on pagamentos.parcela_id = parcelas.parcela_id
    group by 1, 2

),

acordos_diario as (

    select
        data_acordo                                                             as data_referencia,
        carteira,
        count(*)                                                                as acordos_fechados,
        sum(valor_divida)                                                       as valor_divida_negociada,
        sum(valor_acordo)                                                       as valor_acordos_fechados,
        countif(canal_origem = 'bot_whatsapp')                                  as acordos_via_bot,
        countif(canal_origem = 'discador')                                      as acordos_via_discador
    from acordos
    group by 1, 2

),

final as (

    select
        aging_diario.data_referencia,
        aging_diario.carteira,

        aging_diario.parcelas_vencidas,
        aging_diario.contratos_vencidos,
        coalesce(aging_diario.saldo_vencido, 0)                     as saldo_vencido_inicio_dia,
        coalesce(aging_diario.saldo_vencido_01_30, 0)               as saldo_vencido_01_30,
        coalesce(aging_diario.saldo_vencido_31_60, 0)               as saldo_vencido_31_60,
        coalesce(aging_diario.saldo_vencido_61_90, 0)               as saldo_vencido_61_90,
        coalesce(aging_diario.saldo_vencido_91_180, 0)              as saldo_vencido_91_180,
        coalesce(aging_diario.saldo_vencido_181_360, 0)             as saldo_vencido_181_360,
        coalesce(aging_diario.saldo_vencido_360_mais, 0)            as saldo_vencido_360_mais,

        coalesce(recuperado_diario.valor_recuperado_parcelas, 0)    as valor_recuperado_parcelas,
        coalesce(recuperado_diario.valor_recuperado_acordos, 0)     as valor_recuperado_acordos,
        coalesce(recuperado_diario.valor_recuperado_parcelas, 0)
            + coalesce(recuperado_diario.valor_recuperado_acordos, 0) as valor_recuperado,
        coalesce(recuperado_diario.valor_pago_em_dia, 0)            as valor_pago_em_dia,
        coalesce(recuperado_diario.valor_pago_total, 0)             as valor_pago_total,

        coalesce(acordos_diario.acordos_fechados, 0)                as acordos_fechados,
        coalesce(acordos_diario.valor_divida_negociada, 0)          as valor_divida_negociada,
        coalesce(acordos_diario.valor_acordos_fechados, 0)          as valor_acordos_fechados,
        coalesce(acordos_diario.acordos_via_bot, 0)                 as acordos_via_bot,
        coalesce(acordos_diario.acordos_via_discador, 0)            as acordos_via_discador,

        -- taxa de recuperação do dia: quanto do saldo vencido no início do dia virou dinheiro
        safe_divide(
            coalesce(recuperado_diario.valor_recuperado_parcelas, 0)
                + coalesce(recuperado_diario.valor_recuperado_acordos, 0),
            aging_diario.saldo_vencido
        )                                                           as taxa_recuperacao_dia,
        safe_divide(
            coalesce(acordos_diario.valor_acordos_fechados, 0),
            acordos_diario.valor_divida_negociada
        )                                                           as indice_desconto_medio
    from aging_diario
    left join recuperado_diario
        on aging_diario.data_referencia = recuperado_diario.data_referencia
        and aging_diario.carteira = recuperado_diario.carteira
    left join acordos_diario
        on aging_diario.data_referencia = acordos_diario.data_referencia
        and aging_diario.carteira = acordos_diario.carteira

)

select
    {{ dbt_utils.generate_surrogate_key(['data_referencia', 'carteira']) }} as recuperacao_diaria_key,
    *
from final
