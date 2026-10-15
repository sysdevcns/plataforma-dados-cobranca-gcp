-- Cleansed / Silver: status consolidado de cada acordo, recalculado a partir dos pagamentos.
-- Grão: 1 linha por acordo.
--
-- O CRM informa status_crm, mas ele depende de alguém atualizar a tela. Aqui o status é derivado
-- do fato (pagamentos recebidos x plano do acordo), que é a regra que o MIS da cobrança precisa:
--   quitado    todas as parcelas do acordo pagas
--   ativo      em dia (próxima parcela ainda dentro da tolerância)
--   quebrado   pagou a entrada mas deixou uma parcela vencer além da tolerância (30 dias)
--   cancelado  nunca pagou a entrada e já passaram 10 dias do fechamento
with acordos as (

    select * from {{ ref('stg_cobranca__acordos') }}

),

pagamentos as (

    select
        acordo_id,
        count(*)                        as parcelas_pagas,
        sum(valor_pago)                 as valor_pago,
        min(data_pagamento)             as data_primeiro_pagamento,
        max(data_pagamento)             as data_ultimo_pagamento
    from {{ ref('stg_cobranca__pagamentos') }}
    where tipo_pagamento = 'acordo'
    group by acordo_id

),

final as (

    select
        acordos.acordo_id,
        acordos.contrato_id,
        acordos.cliente_id,
        acordos.data_acordo,
        acordos.canal_origem,
        acordos.valor_divida,
        acordos.desconto_pct,
        acordos.valor_acordo,
        acordos.valor_entrada,
        acordos.qtd_parcelas,
        acordos.status_crm,

        coalesce(pagamentos.parcelas_pagas, 0)          as parcelas_pagas,
        coalesce(pagamentos.valor_pago, 0)              as valor_pago,
        acordos.valor_acordo - coalesce(pagamentos.valor_pago, 0) as saldo_acordo,
        pagamentos.data_primeiro_pagamento,
        pagamentos.data_ultimo_pagamento,

        -- vencimento esperado da próxima parcela do acordo (entrada no dia do acordo, demais mensais)
        date_add(acordos.data_acordo, interval coalesce(pagamentos.parcelas_pagas, 0) month) as proximo_vencimento_esperado,

        case
            when coalesce(pagamentos.parcelas_pagas, 0) >= acordos.qtd_parcelas
                 or coalesce(pagamentos.valor_pago, 0) >= acordos.valor_acordo - 0.01
                then 'quitado'
            when coalesce(pagamentos.parcelas_pagas, 0) = 0
                 and date_diff({{ data_referencia() }}, acordos.data_acordo, day) > 10
                then 'cancelado'
            when date_diff(
                    {{ data_referencia() }},
                    date_add(acordos.data_acordo, interval coalesce(pagamentos.parcelas_pagas, 0) month),
                    day
                 ) > 30
                then 'quebrado'
            else 'ativo'
        end                                             as status_consolidado,

        -- divergência entre o que o CRM diz e o que os pagamentos mostram (indicador de qualidade)
        acordos.status_crm != case
            when coalesce(pagamentos.parcelas_pagas, 0) >= acordos.qtd_parcelas
                 or coalesce(pagamentos.valor_pago, 0) >= acordos.valor_acordo - 0.01 then 'quitado'
            when coalesce(pagamentos.parcelas_pagas, 0) = 0
                 and date_diff({{ data_referencia() }}, acordos.data_acordo, day) > 10 then 'cancelado'
            when date_diff({{ data_referencia() }},
                    date_add(acordos.data_acordo, interval coalesce(pagamentos.parcelas_pagas, 0) month),
                    day) > 30 then 'quebrado'
            else 'ativo'
        end                                             as status_crm_divergente,

        acordos.atualizado_em
    from acordos
    left join pagamentos
        on acordos.acordo_id = pagamentos.acordo_id

)

select * from final
