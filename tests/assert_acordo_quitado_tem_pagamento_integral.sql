-- Teste singular: acordo marcado como quitado precisa ter recebido o valor acordado
-- (tolerância de R$ 1,00 para arredondamento de parcelas).
select
    acordo_id,
    valor_acordo,
    valor_pago,
    parcelas_pagas,
    qtd_parcelas
from {{ ref('int_acordos__status') }}
where status_consolidado = 'quitado'
  and valor_pago < valor_acordo - 1
