-- Curated / Gold: dimensão de contratos com a posição atual na régua e os indicadores consolidados.
-- Grão: 1 linha por contrato. É a tabela que alimenta a fila de trabalho da operação
-- ("quem cobrar hoje, por qual canal, com até quanto de desconto") e as features de propensão.
{{
    config(
        materialized='table',
        cluster_by=['carteira', 'fase_regua', 'status_consolidado']
    )
}}

select
    contrato_id,
    cliente_id,
    carteira,
    produto,
    valor_contratado,
    data_contratacao,
    data_cessao,
    qtd_parcelas,
    valor_parcela,
    status_crm,
    status_consolidado,
    status_crm != status_consolidado                as status_crm_divergente,

    parcelas_carregadas,
    parcelas_pagas,
    parcelas_vencidas,
    parcelas_renegociadas,
    parcelas_a_vencer,
    valor_pago,
    saldo_vencido,
    saldo_aberto_total,
    dias_atraso_max,
    aging_bucket,
    fase_regua,
    canal_prioritario_regua,
    desconto_maximo_pct,
    data_primeiro_vencimento_aberto,
    data_ultimo_pagamento,
    media_dias_atraso_pagas,

    qtd_acordos,
    qtd_acordos_quebrados,
    acordo_vigente_id,
    status_acordo_vigente,
    data_ultimo_acordo,

    qtd_contatos,
    qtd_contatos_efetivos,
    qtd_promessas,
    possui_opt_out,
    data_ultimo_contato,
    data_ultimo_contato_efetivo,
    custo_contatos,
    safe_divide(qtd_contatos_efetivos, qtd_contatos) as taxa_contato_efetivo
from {{ ref('int_contratos__regua') }}
