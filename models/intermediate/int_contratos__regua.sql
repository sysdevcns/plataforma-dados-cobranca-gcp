-- Cleansed / Silver: visão consolidada do contrato para a operação de cobrança.
-- Grão: 1 linha por contrato.
--
-- Agrega as parcelas (saldo vencido, parcelas pagas, atraso máximo), o acordo vigente e os contatos,
-- e posiciona o contrato na régua pelo atraso da parcela em aberto mais antiga, que é como a
-- operação enxerga o devedor: "esse contrato está em que fase?".
with contratos as (

    select * from {{ ref('stg_cobranca__contratos') }}

),

parcelas as (

    select
        contrato_id,
        count(*)                                                        as parcelas_carregadas,
        countif(status_consolidado = 'paga')                            as parcelas_pagas,
        countif(status_consolidado = 'vencida')                         as parcelas_vencidas,
        countif(status_consolidado = 'renegociada')                     as parcelas_renegociadas,
        countif(status_consolidado = 'a_vencer')                        as parcelas_a_vencer,
        sum(valor_pago)                                                 as valor_pago,
        sum(case when status_consolidado in ('vencida', 'paga_parcial') then saldo_aberto else 0 end)
                                                                        as saldo_vencido,
        sum(saldo_aberto)                                               as saldo_aberto_total,
        max(case when status_consolidado in ('vencida', 'paga_parcial') then dias_atraso end)
                                                                        as dias_atraso_max,
        min(case when status_consolidado in ('vencida', 'paga_parcial') then data_vencimento end)
                                                                        as data_primeiro_vencimento_aberto,
        max(data_pagamento)                                             as data_ultimo_pagamento,
        -- atraso médio com que o devedor pagou as parcelas já quitadas (comportamento histórico)
        avg(case when status_consolidado = 'paga' then dias_atraso end) as media_dias_atraso_pagas
    from {{ ref('int_parcelas__aging') }}
    group by contrato_id

),

acordos as (

    select
        contrato_id,
        count(*)                                                        as qtd_acordos,
        countif(status_consolidado = 'quebrado')                        as qtd_acordos_quebrados,
        max(case when status_consolidado in ('ativo', 'quitado') then acordo_id end)
                                                                        as acordo_vigente_id,
        max(case when status_consolidado in ('ativo', 'quitado') then status_consolidado end)
                                                                        as status_acordo_vigente,
        max(data_acordo)                                                as data_ultimo_acordo
    from {{ ref('int_acordos__status') }}
    group by contrato_id

),

contatos as (

    select
        contrato_id,
        count(*)                                                        as qtd_contatos,
        countif(is_contato_efetivo)                                     as qtd_contatos_efetivos,
        countif(is_promessa)                                            as qtd_promessas,
        countif(is_opt_out)                                             as qtd_opt_out,
        max(data_contato)                                               as data_ultimo_contato,
        max(case when is_contato_efetivo then data_contato end)         as data_ultimo_contato_efetivo,
        sum(custo_unitario)                                             as custo_contatos
    from {{ ref('int_contatos__classificados') }}
    group by contrato_id

),

regua as (

    select * from {{ ref('regua_cobranca') }}

),

final as (

    select
        contratos.contrato_id,
        contratos.cliente_id,
        contratos.carteira,
        contratos.produto,
        contratos.valor_contratado,
        contratos.data_contratacao,
        contratos.data_cessao,
        contratos.qtd_parcelas,
        contratos.valor_parcela,
        contratos.status_crm,

        coalesce(parcelas.parcelas_carregadas, 0)       as parcelas_carregadas,
        coalesce(parcelas.parcelas_pagas, 0)            as parcelas_pagas,
        coalesce(parcelas.parcelas_vencidas, 0)         as parcelas_vencidas,
        coalesce(parcelas.parcelas_renegociadas, 0)     as parcelas_renegociadas,
        coalesce(parcelas.parcelas_a_vencer, 0)         as parcelas_a_vencer,
        coalesce(parcelas.valor_pago, 0)                as valor_pago,
        coalesce(parcelas.saldo_vencido, 0)             as saldo_vencido,
        coalesce(parcelas.saldo_aberto_total, 0)        as saldo_aberto_total,
        parcelas.dias_atraso_max,
        parcelas.data_primeiro_vencimento_aberto,
        parcelas.data_ultimo_pagamento,
        parcelas.media_dias_atraso_pagas,

        coalesce(acordos.qtd_acordos, 0)                as qtd_acordos,
        coalesce(acordos.qtd_acordos_quebrados, 0)      as qtd_acordos_quebrados,
        acordos.acordo_vigente_id,
        acordos.status_acordo_vigente,
        acordos.data_ultimo_acordo,

        coalesce(contatos.qtd_contatos, 0)              as qtd_contatos,
        coalesce(contatos.qtd_contatos_efetivos, 0)     as qtd_contatos_efetivos,
        coalesce(contatos.qtd_promessas, 0)             as qtd_promessas,
        coalesce(contatos.qtd_opt_out, 0) > 0           as possui_opt_out,
        contatos.data_ultimo_contato,
        contatos.data_ultimo_contato_efetivo,
        coalesce(contatos.custo_contatos, 0)            as custo_contatos,

        case
            when coalesce(parcelas.parcelas_pagas, 0) >= contratos.qtd_parcelas       then 'quitado'
            when acordos.status_acordo_vigente = 'ativo'                              then 'em_acordo'
            when coalesce(parcelas.saldo_vencido, 0) > 0                              then 'inadimplente'
            else 'em_dia'
        end                                             as status_consolidado,

        {{ aging_bucket('parcelas.dias_atraso_max') }}  as aging_bucket,
        regua.fase                                      as fase_regua,
        regua.canal_prioritario                         as canal_prioritario_regua,
        regua.desconto_maximo_pct                       as desconto_maximo_pct
    from contratos
    left join parcelas
        on contratos.contrato_id = parcelas.contrato_id
    left join acordos
        on contratos.contrato_id = acordos.contrato_id
    left join contatos
        on contratos.contrato_id = contatos.contrato_id
    left join regua
        on parcelas.dias_atraso_max between regua.dias_atraso_inicio and regua.dias_atraso_fim

)

select * from final
