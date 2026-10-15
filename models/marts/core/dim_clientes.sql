-- Curated / Gold: dimensão de devedores com mascaramento LGPD e indicadores de carteira.
-- Grão: 1 linha por cliente.
--
-- LGPD: esta camada é a que BI, MIS e cientistas de dados acessam, então nenhum dado pessoal
-- direto sai daqui em claro:
--   * cpf e e-mail viram hash SHA-256 com sal (macro hash_pii): continuam servindo para join e
--     deduplicação entre sistemas, mas não identificam a pessoa;
--   * nome vira iniciais; telefone vira só o DDD; nascimento vira faixa etária;
--   * quem precisa do dado em claro (operação, jurídico) consulta a camada Raw, em dataset com
--     IAM restrito e policy tags, e esse acesso fica auditado.
-- possui_opt_out materializa o pedido de "não me contate" para que régua e discador o respeitem.
{{
    config(
        materialized='table',
        cluster_by=['uf', 'fase_regua_pior']
    )
}}

with clientes as (

    select * from {{ ref('stg_cobranca__clientes') }}

),

contratos as (

    select
        cliente_id,
        count(*)                                                as qtd_contratos,
        countif(status_consolidado = 'inadimplente')            as qtd_contratos_inadimplentes,
        countif(status_consolidado = 'em_acordo')               as qtd_contratos_em_acordo,
        countif(status_consolidado = 'quitado')                 as qtd_contratos_quitados,
        sum(valor_contratado)                                   as valor_contratado_total,
        sum(saldo_vencido)                                      as saldo_vencido_total,
        sum(saldo_aberto_total)                                 as saldo_aberto_total,
        max(dias_atraso_max)                                    as dias_atraso_max,
        sum(qtd_contatos)                                       as qtd_contatos,
        sum(qtd_contatos_efetivos)                              as qtd_contatos_efetivos,
        sum(qtd_acordos)                                        as qtd_acordos,
        sum(qtd_acordos_quebrados)                              as qtd_acordos_quebrados,
        logical_or(possui_opt_out)                              as possui_opt_out,
        max(data_ultimo_pagamento)                              as data_ultimo_pagamento,
        max(data_ultimo_contato_efetivo)                        as data_ultimo_contato_efetivo,
        string_agg(distinct carteira order by carteira)         as carteiras
    from {{ ref('int_contratos__regua') }}
    group by cliente_id

),

regua as (

    select * from {{ ref('regua_cobranca') }}

),

final as (

    select
        clientes.cliente_id,

        -- identificadores mascarados (LGPD)
        {{ hash_pii('clientes.cpf') }}                          as cpf_hash,
        {{ hash_pii('clientes.email') }}                        as email_hash,
        split(clientes.email, '@')[safe_offset(1)]              as email_dominio,
        regexp_replace(clientes.nome, r'(\S)\S*', r'\1.')       as nome_iniciais,
        substr(clientes.telefone, 1, 2)                         as telefone_ddd,
        clientes.uf,
        substr(clientes.cep, 1, 5)                              as cep_prefixo,

        -- atributos derivados, sem identificar a pessoa
        case
            when clientes.data_nascimento is null then 'nao_informada'
            when date_diff({{ data_referencia() }}, clientes.data_nascimento, year) < 25 then 'ate_24'
            when date_diff({{ data_referencia() }}, clientes.data_nascimento, year) < 35 then '25_34'
            when date_diff({{ data_referencia() }}, clientes.data_nascimento, year) < 45 then '35_44'
            when date_diff({{ data_referencia() }}, clientes.data_nascimento, year) < 60 then '45_59'
            else '60_mais'
        end                                                     as faixa_etaria,
        case
            when clientes.renda_declarada is null then 'nao_informada'
            when clientes.renda_declarada < 2500 then 'ate_2500'
            when clientes.renda_declarada < 6000 then '2500_6000'
            else 'acima_6000'
        end                                                     as faixa_renda,
        clientes.email is not null                              as possui_email,
        clientes.data_cadastro,

        -- indicadores de carteira
        coalesce(contratos.qtd_contratos, 0)                    as qtd_contratos,
        coalesce(contratos.qtd_contratos_inadimplentes, 0)      as qtd_contratos_inadimplentes,
        coalesce(contratos.qtd_contratos_em_acordo, 0)          as qtd_contratos_em_acordo,
        coalesce(contratos.qtd_contratos_quitados, 0)           as qtd_contratos_quitados,
        coalesce(contratos.valor_contratado_total, 0)           as valor_contratado_total,
        coalesce(contratos.saldo_vencido_total, 0)              as saldo_vencido_total,
        coalesce(contratos.saldo_aberto_total, 0)               as saldo_aberto_total,
        contratos.dias_atraso_max,
        {{ aging_bucket('contratos.dias_atraso_max') }}         as aging_bucket_pior,
        coalesce(regua.fase, 'sem_atraso')                      as fase_regua_pior,
        coalesce(contratos.qtd_contatos, 0)                     as qtd_contatos,
        coalesce(contratos.qtd_contatos_efetivos, 0)            as qtd_contatos_efetivos,
        coalesce(contratos.qtd_acordos, 0)                      as qtd_acordos,
        coalesce(contratos.qtd_acordos_quebrados, 0)            as qtd_acordos_quebrados,
        coalesce(contratos.possui_opt_out, false)               as possui_opt_out,
        contratos.data_ultimo_pagamento,
        contratos.data_ultimo_contato_efetivo,
        contratos.carteiras,

        case
            when contratos.qtd_contratos is null                       then 'sem_contrato'
            when coalesce(contratos.saldo_vencido_total, 0) = 0
                 and coalesce(contratos.qtd_contratos_em_acordo, 0) = 0 then 'adimplente'
            when coalesce(contratos.qtd_acordos_quebrados, 0) > 0      then 'reincidente'
            when coalesce(contratos.qtd_contratos_em_acordo, 0) > 0    then 'em_negociacao'
            else 'inadimplente'
        end                                                     as segmento_cobranca
    from clientes
    left join contratos
        on clientes.cliente_id = contratos.cliente_id
    left join regua
        on contratos.dias_atraso_max between regua.dias_atraso_inicio and regua.dias_atraso_fim

)

select * from final
