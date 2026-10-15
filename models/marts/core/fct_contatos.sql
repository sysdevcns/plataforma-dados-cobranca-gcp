-- Curated / Gold: fato de tentativas de contato, base para efetividade por canal/fornecedor
-- e para as features de "melhor canal / melhor horário" dos modelos de propensão.
-- Grão: 1 linha por tentativa de contato.
--
-- Fora do sandbox: incremental por partição diária (insert_overwrite + copy_partitions, sem DML),
-- reprocessando os últimos incremental_lookback_days dias, porque webhooks de discador e bot
-- chegam com atraso e correções. No sandbox vira tabela completa sem particionamento.
{{
    config(
        materialized=('table' if is_sandbox() else 'incremental'),
        incremental_strategy='insert_overwrite',
        partition_by=(none if is_sandbox() else {
            'field': 'data_contato',
            'data_type': 'date',
            'granularity': 'day',
            'copy_partitions': true
        }),
        cluster_by=['canal', 'fornecedor'],
        on_schema_change='append_new_columns'
    )
}}

with contatos as (

    select * from {{ ref('int_contatos__classificados') }}
    {% if is_incremental() %}
    where data_contato >= date_sub({{ data_referencia() }}, interval {{ var('incremental_lookback_days') }} day)
    {% endif %}

)

select
    contato_id,
    contrato_id,
    cliente_id,
    carteira,
    produto,
    data_hora_contato,
    data_contato,
    hora_contato,
    canal,
    fornecedor,
    campanha,
    operador_id,
    resultado,
    duracao_seg,
    custo_unitario,
    is_contato_efetivo,
    is_promessa,
    is_acordo,
    is_opt_out,
    is_convertido_7d,
    acordo_convertido_id,
    dias_atraso_no_contato,
    {{ aging_bucket('dias_atraso_no_contato') }}   as aging_bucket_no_contato,
    fase_regua_no_contato,
    is_canal_prioritario
from contatos
