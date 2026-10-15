-- Curated / Gold: efetividade de contato por dia, carteira, canal e fornecedor.
-- Grão: 1 linha por (data_contato, carteira, canal, fornecedor).
--
-- Responde às perguntas que a operação faz ao comparar discador, bot e mensageria:
-- taxa de contato efetivo (CPC), promessas, acordos, conversão em 7 dias, opt-out,
-- custo por contato efetivo e custo por acordo. Como a definição de "efetivo" vem do
-- catálogo resultado_contato, trocar de fornecedor não muda a métrica.
{{
    config(
        materialized='table',
        partition_by=(none if is_sandbox() else {
            'field': 'data_contato',
            'data_type': 'date',
            'granularity': 'day'
        }),
        cluster_by=['canal', 'fornecedor', 'carteira']
    )
}}

with contatos as (

    select * from {{ ref('fct_contatos') }}

),

diario as (

    select
        data_contato,
        carteira,
        canal,
        fornecedor,

        count(*)                                                as tentativas,
        count(distinct contrato_id)                             as contratos_acionados,
        countif(is_contato_efetivo)                             as contatos_efetivos,
        countif(is_promessa)                                    as promessas,
        countif(is_acordo)                                      as acordos_no_contato,
        countif(is_convertido_7d)                               as convertidos_7d,
        countif(is_opt_out)                                     as opt_outs,
        countif(is_canal_prioritario)                           as tentativas_no_canal_da_regua,
        sum(custo_unitario)                                     as custo_total,
        sum(case when is_contato_efetivo then duracao_seg end)  as segundos_em_contato_efetivo,

        safe_divide(countif(is_contato_efetivo), count(*))      as taxa_contato_efetivo,
        safe_divide(countif(is_promessa), countif(is_contato_efetivo)) as taxa_promessa_por_efetivo,
        safe_divide(countif(is_convertido_7d), count(*))        as taxa_conversao_7d,
        safe_divide(sum(custo_unitario), nullif(countif(is_contato_efetivo), 0)) as custo_por_contato_efetivo,
        safe_divide(sum(custo_unitario), nullif(countif(is_acordo), 0))          as custo_por_acordo
    from contatos
    group by data_contato, carteira, canal, fornecedor

)

select
    {{ dbt_utils.generate_surrogate_key(['data_contato', 'carteira', 'canal', 'fornecedor']) }} as efetividade_key,
    *
from diario
