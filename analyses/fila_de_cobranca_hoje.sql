-- Consulta de exemplo (dbt compile): fila de trabalho do dia para a operação.
-- Contratos com saldo vencido, sem opt-out e sem contato efetivo nos últimos 3 dias,
-- ordenados por saldo, com o canal e o desconto máximo que a régua permite.
select
    contrato_id,
    carteira,
    produto,
    fase_regua,
    canal_prioritario_regua,
    desconto_maximo_pct,
    dias_atraso_max,
    saldo_vencido,
    data_ultimo_contato_efetivo
from {{ ref('dim_contratos') }}
where saldo_vencido > 0
  and not possui_opt_out
  and (data_ultimo_contato_efetivo is null
       or data_ultimo_contato_efetivo < date_sub({{ data_referencia() }}, interval 3 day))
order by saldo_vencido desc
limit 500
