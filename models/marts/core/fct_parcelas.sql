-- Curated / Gold: fato de parcelas, a fonte única de saldo, atraso e recuperação por parcela.
-- Grão: 1 linha por parcela original.
--
-- Modelagem física (fora do sandbox):
--   * particionada por data_vencimento (mês): o MIS filtra por safra de vencimento e por
--     "carteira vencida até a data X"; granularidade mensal evita partições minúsculas;
--   * clusterizada por carteira e status_consolidado, os filtros mais comuns dos dashboards;
--   * no sandbox do BigQuery (macro is_sandbox) fica sem particionamento, por causa da
--     expiração de 60 dias por partição que apagaria o histórico.
{{
    config(
        materialized='table',
        partition_by=(none if is_sandbox() else {
            'field': 'data_vencimento',
            'data_type': 'date',
            'granularity': 'month'
        }),
        cluster_by=['carteira', 'status_consolidado']
    )
}}

with parcelas as (

    select * from {{ ref('int_parcelas__aging') }}

),

contratos as (

    select
        contrato_id,
        cliente_id,
        carteira,
        produto,
        data_contratacao
    from {{ ref('stg_cobranca__contratos') }}

),

final as (

    select
        parcelas.parcela_id,
        parcelas.contrato_id,
        contratos.cliente_id,
        contratos.carteira,
        contratos.produto,
        contratos.data_contratacao,

        parcelas.numero_parcela,
        parcelas.data_vencimento,
        date_trunc(parcelas.data_vencimento, month)     as mes_vencimento,
        parcelas.valor_parcela,
        parcelas.valor_pago,
        parcelas.saldo_aberto,
        parcelas.data_pagamento,
        parcelas.qtd_pagamentos,

        parcelas.status_origem,
        parcelas.status_consolidado,
        parcelas.status_origem_divergente,
        parcelas.dias_atraso,
        parcelas.aging_bucket,
        parcelas.fase_regua,
        parcelas.canal_prioritario_regua,

        parcelas.acordo_id,
        parcelas.data_acordo,
        parcelas.status_acordo,
        parcelas.is_renegociada,

        -- flags de recuperação: pagamento recebido depois do vencimento é dinheiro "recuperado"
        parcelas.status_consolidado = 'paga' and parcelas.dias_atraso > 0  as is_recuperada,
        parcelas.status_consolidado = 'paga' and parcelas.dias_atraso <= 0 as is_paga_em_dia,

        parcelas.data_referencia
    from parcelas
    inner join contratos
        on parcelas.contrato_id = contratos.contrato_id

)

select * from final
