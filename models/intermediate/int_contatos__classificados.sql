-- Cleansed / Silver: tentativa de contato classificada pelo catálogo de resultados e posicionada
-- na régua no momento em que aconteceu. Grão: 1 linha por tentativa de contato.
--
-- É aqui que "efetividade" ganha definição única para todos os canais e fornecedores:
--   * is_contato_efetivo / is_promessa / is_acordo / is_opt_out vêm do seed resultado_contato;
--   * dias_atraso_no_contato é o atraso da parcela em aberto mais antiga naquele dia;
--   * is_convertido_7d marca o contato seguido de acordo no mesmo contrato em até 7 dias
--     (atribuição simples, "último toque"; suficiente para comparar canais).
with contatos as (

    select * from {{ ref('stg_cobranca__contatos') }}

),

catalogo as (

    select * from {{ ref('resultado_contato') }}

),

contratos as (

    select contrato_id, carteira, produto from {{ ref('stg_cobranca__contratos') }}

),

parcelas as (

    select
        contrato_id,
        data_vencimento,
        data_pagamento
    from {{ ref('int_parcelas__aging') }}

),

acordos as (

    select contrato_id, acordo_id, data_acordo from {{ ref('stg_cobranca__acordos') }}

),

regua as (

    select * from {{ ref('regua_cobranca') }}

),

atraso_no_contato as (

    -- parcela em aberto mais antiga na data do contato
    select
        contatos.contato_id,
        min(parcelas.data_vencimento) as primeiro_vencimento_aberto
    from contatos
    inner join parcelas
        on contatos.contrato_id = parcelas.contrato_id
        and parcelas.data_vencimento < contatos.data_contato
        and (parcelas.data_pagamento is null or parcelas.data_pagamento >= contatos.data_contato)
    group by contatos.contato_id

),

conversao as (

    -- acordo fechado no contrato em até 7 dias após o contato
    select
        contatos.contato_id,
        min(acordos.acordo_id)   as acordo_convertido_id,
        min(acordos.data_acordo) as data_acordo_convertido
    from contatos
    inner join acordos
        on contatos.contrato_id = acordos.contrato_id
        and acordos.data_acordo between contatos.data_contato and date_add(contatos.data_contato, interval 7 day)
    group by contatos.contato_id

),

final as (

    select
        contatos.contato_id,
        contatos.contrato_id,
        contatos.cliente_id,
        contratos.carteira,
        contratos.produto,
        contatos.data_hora_contato,
        contatos.data_contato,
        extract(hour from contatos.data_hora_contato)   as hora_contato,
        contatos.canal,
        contatos.fornecedor,
        contatos.resultado,
        contatos.duracao_seg,
        contatos.operador_id,
        contatos.campanha,
        contatos.custo_unitario,

        coalesce(catalogo.is_contato_efetivo, false)    as is_contato_efetivo,
        coalesce(catalogo.is_promessa, false)           as is_promessa,
        coalesce(catalogo.is_acordo, false)             as is_acordo,
        coalesce(catalogo.is_opt_out, false)            as is_opt_out,
        catalogo.resultado is null                      as resultado_fora_do_catalogo,

        date_diff(contatos.data_contato, atraso_no_contato.primeiro_vencimento_aberto, day) as dias_atraso_no_contato,
        regua.fase                                      as fase_regua_no_contato,
        contatos.canal = regua.canal_prioritario        as is_canal_prioritario,

        conversao.acordo_convertido_id is not null      as is_convertido_7d,
        conversao.acordo_convertido_id,
        conversao.data_acordo_convertido
    from contatos
    left join catalogo
        on contatos.canal = catalogo.canal
        and contatos.resultado = catalogo.resultado
    left join contratos
        on contatos.contrato_id = contratos.contrato_id
    left join atraso_no_contato
        on contatos.contato_id = atraso_no_contato.contato_id
    left join conversao
        on contatos.contato_id = conversao.contato_id
    left join regua
        on date_diff(contatos.data_contato, atraso_no_contato.primeiro_vencimento_aberto, day)
            between regua.dias_atraso_inicio and regua.dias_atraso_fim

)

select * from final
