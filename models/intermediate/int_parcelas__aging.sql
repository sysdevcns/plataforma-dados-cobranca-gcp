-- Cleansed / Silver: parcela com pagamento, atraso, faixa de aging, status consolidado e fase da régua.
-- Grão: 1 linha por parcela original.
--
-- Regras de negócio centralizadas aqui (e só aqui):
--   * status consolidado vem do fato (pagamentos e acordos), não do status_origem do credor;
--   * parcela coberta por acordo vigente (ativo ou quitado) sai do aging: a dívida passou para o acordo;
--     se o acordo quebrou, a parcela volta a contar como vencida;
--   * dias_atraso é medido na data de referência para parcelas em aberto e na data do pagamento
--     para parcelas pagas (quantos dias de atraso o devedor levou para pagar);
--   * a fase da régua vem da tabela de referência regua_cobranca, nunca de um CASE escondido no mart.
with parcelas as (

    select * from {{ ref('stg_cobranca__parcelas') }}

),

pagamentos as (

    select
        parcela_id,
        sum(valor_pago)         as valor_pago,
        min(data_pagamento)     as data_primeiro_pagamento,
        max(data_pagamento)     as data_ultimo_pagamento,
        count(*)                as qtd_pagamentos
    from {{ ref('stg_cobranca__pagamentos') }}
    where tipo_pagamento = 'parcela'
    group by parcela_id

),

acordos_vigentes as (

    -- último acordo não quebrado/cancelado de cada contrato
    select
        contrato_id,
        acordo_id,
        data_acordo,
        status_consolidado as status_acordo
    from {{ ref('int_acordos__status') }}
    where status_consolidado in ('ativo', 'quitado')
    qualify row_number() over (partition by contrato_id order by data_acordo desc) = 1

),

regua as (

    select * from {{ ref('regua_cobranca') }}

),

enriquecida as (

    select
        parcelas.parcela_id,
        parcelas.contrato_id,
        parcelas.numero_parcela,
        parcelas.data_vencimento,
        parcelas.valor_parcela,
        parcelas.status_origem,

        coalesce(pagamentos.valor_pago, 0)                              as valor_pago,
        pagamentos.data_primeiro_pagamento                              as data_pagamento,
        coalesce(pagamentos.qtd_pagamentos, 0)                          as qtd_pagamentos,

        acordos_vigentes.acordo_id,
        acordos_vigentes.data_acordo,
        acordos_vigentes.status_acordo,

        -- a parcela entrou no acordo se já estava vencida e em aberto na data do acordo
        acordos_vigentes.acordo_id is not null
            and parcelas.data_vencimento < acordos_vigentes.data_acordo
            and (pagamentos.data_primeiro_pagamento is null
                 or pagamentos.data_primeiro_pagamento > acordos_vigentes.data_acordo) as is_renegociada,

        coalesce(pagamentos.valor_pago, 0) >= parcelas.valor_parcela - 0.01   as is_paga,
        {{ data_referencia() }}                                                as data_referencia
    from parcelas
    left join pagamentos
        on parcelas.parcela_id = pagamentos.parcela_id
    left join acordos_vigentes
        on parcelas.contrato_id = acordos_vigentes.contrato_id

),

classificada as (

    select
        *,
        case
            when is_paga then 'paga'
            when is_renegociada then 'renegociada'
            when valor_pago > 0 and data_vencimento < data_referencia then 'paga_parcial'
            when data_vencimento < data_referencia then 'vencida'
            else 'a_vencer'
        end                                                             as status_consolidado,

        case
            when is_paga then date_diff(data_pagamento, data_vencimento, day)
            else date_diff(data_referencia, data_vencimento, day)
        end                                                             as dias_atraso,

        case
            when is_paga or is_renegociada then 0
            else valor_parcela - valor_pago
        end                                                             as saldo_aberto
    from enriquecida

),

final as (

    select
        classificada.* except (is_paga),

        case
            when status_consolidado in ('paga', 'renegociada') then status_consolidado
            else {{ aging_bucket('dias_atraso') }}
        end                                                             as aging_bucket,

        -- fase da régua só faz sentido para parcela com saldo em aberto
        case
            when saldo_aberto > 0 then regua.fase
        end                                                             as fase_regua,
        case
            when saldo_aberto > 0 then regua.canal_prioritario
        end                                                             as canal_prioritario_regua,

        -- status informado pelo credor bate com o consolidado? (indicador de qualidade da origem)
        status_origem != status_consolidado                             as status_origem_divergente
    from classificada
    left join regua
        on classificada.dias_atraso between regua.dias_atraso_inicio and regua.dias_atraso_fim

)

select * from final
