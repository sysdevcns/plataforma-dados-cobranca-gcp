"""
Gera o dataset sintético de uma operação de cobrança e grava em seeds/raw_*.csv.

Entidades (todas fictícias; CPFs, nomes, e-mails e telefones são gerados aleatoriamente):
  raw_clientes    devedores (PF) com dados cadastrais e de contato
  raw_contratos   contratos cedidos por credores fictícios (carteiras), com plano de parcelas
  raw_parcelas    parcelas originais de cada contrato (vencimento, valor, status no sistema do credor)
  raw_acordos     acordos de renegociação fechados pela operação (canal de origem, desconto, plano)
  raw_pagamentos  pagamentos de parcelas originais e de parcelas de acordo
  raw_contatos    tentativas de contato por discador, bot de WhatsApp, SMS, e-mail e URA, com resultado

O comportamento de pagamento de cada contrato segue um "perfil" (adimplente, atrasa e paga,
inadimplente a partir de uma parcela, errático) para que aging, régua e taxa de recuperação tenham
distribuições realistas. Alguns campos de origem são propositalmente "sujos" (status desatualizado no
CRM, CPF com máscara, e-mail em maiúsculas, UF em minúsculas) para dar trabalho às camadas Raw e Cleansed.

Uso:
    python scripts/gerar_dados_sinteticos.py            # grava em seeds/ com a semente padrão
    python scripts/gerar_dados_sinteticos.py --seed 7 --data-corte 2026-10-14 --clientes 600

Só usa a biblioteca padrão; roda em qualquer Python 3.10+.
"""
from __future__ import annotations

import argparse
import csv
import random
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
SEEDS = RAIZ / "seeds"

NOMES = ["Ana", "Bruno", "Carla", "Daniel", "Eduarda", "Felipe", "Gabriela", "Henrique", "Isabela",
         "João", "Karina", "Lucas", "Mariana", "Nicolas", "Olívia", "Paulo", "Rafaela", "Samuel",
         "Tatiane", "Vinícius", "William", "Yasmin", "André", "Beatriz", "Caio", "Débora", "Eric",
         "Fernanda", "Gustavo", "Helena", "Igor", "Juliana", "Leonardo", "Marcela", "Otávio", "Priscila"]
SOBRENOMES = ["Silva", "Santos", "Oliveira", "Souza", "Rodrigues", "Ferreira", "Alves", "Pereira", "Lima",
              "Gomes", "Costa", "Ribeiro", "Martins", "Carvalho", "Almeida", "Lopes", "Soares", "Fernandes",
              "Vieira", "Barbosa", "Rocha", "Dias", "Nascimento", "Andrade", "Moreira", "Nunes", "Marques"]
DOMINIOS = ["gmail.com", "hotmail.com", "outlook.com", "yahoo.com.br", "uol.com.br", "bol.com.br"]
UFS = (["SP"] * 30 + ["RJ"] * 12 + ["MG"] * 12 + ["PR"] * 7 + ["RS"] * 7 + ["BA"] * 6 + ["SC"] * 5
       + ["PE"] * 4 + ["CE"] * 4 + ["GO"] * 4 + ["DF"] * 3 + ["ES"] * 2 + ["PA"] * 2 + ["AM"] * 1 + ["MT"] * 1)
DDD_POR_UF = {"SP": [11, 12, 13, 15, 19], "RJ": [21, 22, 24], "MG": [31, 32, 34], "PR": [41, 43, 44],
              "RS": [51, 53, 54], "BA": [71, 73, 75], "SC": [47, 48, 49], "PE": [81, 87], "CE": [85, 88],
              "GO": [62, 64], "DF": [61], "ES": [27, 28], "PA": [91, 93], "AM": [92, 97], "MT": [65, 66]}

# Credores fictícios que cedem carteira para a operação de cobrança e seus produtos típicos.
CARTEIRAS = {
    "Banco Alfa":       {"produtos": ["cartao_credito", "emprestimo_pessoal", "cheque_especial"], "peso": 35,
                         "ticket": (800, 18000), "parcelas": (3, 36), "inadimplencia": 0.45},
    "Financeira Beta":  {"produtos": ["cdc_veiculo", "emprestimo_pessoal", "consignado"], "peso": 25,
                         "ticket": (3000, 60000), "parcelas": (12, 60), "inadimplencia": 0.35},
    "Varejo Gama":      {"produtos": ["crediario", "cartao_loja"], "peso": 25,
                         "ticket": (150, 4000), "parcelas": (2, 18), "inadimplencia": 0.55},
    "Telecom Delta":    {"produtos": ["fatura_telecom"], "peso": 15,
                         "ticket": (60, 900), "parcelas": (1, 6), "inadimplencia": 0.65},
}
MEIOS_PAGAMENTO = ["boleto"] * 45 + ["pix"] * 40 + ["debito_conta"] * 8 + ["cartao"] * 7

# Fornecedores fictícios de discador e bot (a operação costuma ter mais de um, e trocar ao longo do tempo).
FORNECEDORES = {
    "discador":     ["Dialer Nexus", "VoiceHub"],
    "ura":          ["Dialer Nexus"],
    "bot_whatsapp": ["ChatFlow", "ZapCobra"],
    "sms":          ["SMS Direct"],
    "email":        ["MailBlast"],
}

# Resultados possíveis por canal, com peso. Os códigos batem com seeds/resultado_contato.csv.
RESULTADOS = {
    "discador": [("nao_atende", 38), ("caixa_postal", 14), ("numero_invalido", 6), ("terceiro", 10),
                 ("cpc_recusa", 9), ("cpc_promessa", 15), ("cpc_acordo", 4), ("cpc_sem_condicao", 4)],
    "ura":      [("nao_atende", 45), ("caixa_postal", 20), ("numero_invalido", 5), ("ura_transferida", 20),
                 ("ura_abandonada", 10)],
    "bot_whatsapp": [("entregue", 40), ("lido", 28), ("respondido", 15), ("bot_promessa", 8),
                     ("bot_acordo", 4), ("opt_out", 3), ("falha_envio", 2)],
    "sms":      [("entregue", 85), ("falha_envio", 10), ("opt_out", 5)],
    "email":    [("enviado", 55), ("aberto", 25), ("clique", 12), ("bounce", 8)],
}
CUSTO_UNITARIO = {"discador": "0.35", "ura": "0.12", "bot_whatsapp": "0.08", "sms": "0.05", "email": "0.01"}


def digitos_cpf(rng: random.Random) -> str:
    base = [rng.randint(0, 9) for _ in range(9)]
    for pesos in (range(10, 1, -1), range(11, 1, -1)):
        soma = sum(d * p for d, p in zip(base, pesos))
        resto = (soma * 10) % 11
        base.append(0 if resto == 10 else resto)
    return "".join(map(str, base))


def soma_meses(d: date, meses: int) -> date:
    ano = d.year + (d.month - 1 + meses) // 12
    mes = (d.month - 1 + meses) % 12 + 1
    bissexto = ano % 4 == 0 and (ano % 100 != 0 or ano % 400 == 0)
    dias_mes = [31, 29 if bissexto else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mes - 1]
    return date(ano, mes, min(d.day, dias_mes))


def sorteia(rng: random.Random, pesos: list[tuple[str, int]]) -> str:
    return rng.choices([v for v, _ in pesos], weights=[p for _, p in pesos], k=1)[0]


def dinheiro(v: float) -> str:
    return f"{v:.2f}"


def fase_regua(atraso: int) -> str:
    if atraso <= 15:
        return "AMIG"
    if atraso <= 60:
        return "ADM"
    if atraso <= 180:
        return "REC"
    return "JUD"


@dataclass
class Parcela:
    parcela_id: str
    contrato_id: str
    numero: int
    vencimento: date
    valor: float
    data_pagamento: date | None = None
    valor_pago: float = 0.0
    em_acordo: bool = False


@dataclass
class Contrato:
    contrato_id: str
    cliente_id: str
    carteira: str
    produto: str
    valor_contratado: float
    data_contratacao: date
    qtd_parcelas: int
    valor_parcela: float
    perfil: str
    parcelas: list[Parcela] = field(default_factory=list)


def gerar(seed: int, data_corte: date, n_clientes: int) -> dict[str, list[dict]]:
    rng = random.Random(seed)
    inicio_janela = date(data_corte.year - 2, 1, 1)

    # ---------------------------------------------------------------- clientes
    clientes = []
    for i in range(1, n_clientes + 1):
        uf = rng.choice(UFS)
        nome = f"{rng.choice(NOMES)} {rng.choice(SOBRENOMES)} {rng.choice(SOBRENOMES)}"
        cpf = digitos_cpf(rng)
        if rng.random() < 0.3:  # parte dos CPFs chega com máscara (sujeira típica de planilha)
            cpf = f"{cpf[:3]}.{cpf[3:6]}.{cpf[6:9]}-{cpf[9:]}"
        email = f"{nome.split()[0]}.{nome.split()[1]}{rng.randint(1, 999)}@{rng.choice(DOMINIOS)}".lower()
        if rng.random() < 0.15:
            email = email.upper()
        if rng.random() < 0.06:
            email = ""  # sem e-mail cadastrado
        ddd = rng.choice(DDD_POR_UF[uf])
        telefone = f"{ddd}9{rng.randint(10000000, 99999999)}"
        nascimento = date(rng.randint(1950, 2004), rng.randint(1, 12), rng.randint(1, 28))
        cadastro = inicio_janela + timedelta(days=rng.randint(0, 540))
        clientes.append({
            "cliente_id": f"CLI{i:06d}",
            "nome": nome,
            "cpf": cpf,
            "email": email,
            "telefone": telefone,
            "data_nascimento": nascimento.isoformat(),
            "uf": uf if rng.random() > 0.1 else uf.lower(),
            "cep": f"{rng.randint(1000, 99999):05d}{rng.randint(0, 999):03d}",
            "renda_declarada": rng.choice([1500, 2200, 3000, 4500, 6000, 8500, 12000, ""]),
            "data_cadastro": cadastro.isoformat(),
            "atualizado_em": (cadastro + timedelta(days=rng.randint(0, 400))).isoformat() + "T10:00:00",
        })

    # ---------------------------------------------------------------- contratos e parcelas
    contratos: list[Contrato] = []
    nomes_carteira = list(CARTEIRAS)
    pesos_carteira = [CARTEIRAS[c]["peso"] for c in nomes_carteira]
    n_contratos = int(n_clientes * 1.5)
    seq_parcela = 0
    for i in range(1, n_contratos + 1):
        cli = rng.choice(clientes)
        carteira = rng.choices(nomes_carteira, weights=pesos_carteira, k=1)[0]
        cfg = CARTEIRAS[carteira]
        produto = rng.choice(cfg["produtos"])
        qtd = rng.randint(*cfg["parcelas"])
        valor = round(rng.uniform(*cfg["ticket"]), 2)
        contratacao = inicio_janela + timedelta(days=rng.randint(0, (data_corte - inicio_janela).days - 60))
        valor_parcela = round(valor * (1 + 0.025 * qtd) / qtd, 2)

        r = rng.random()
        if r < 1 - cfg["inadimplencia"]:
            perfil = "adimplente" if rng.random() < 0.7 else "atrasa_e_paga"
        elif r < 1 - cfg["inadimplencia"] * 0.35:
            perfil = "inadimplente"
        else:
            perfil = "erratico"

        c = Contrato(f"CTR{i:07d}", cli["cliente_id"], carteira, produto, valor, contratacao, qtd,
                     valor_parcela, perfil)
        parou_em = rng.randint(1, max(1, qtd)) if perfil == "inadimplente" else None
        for n in range(1, qtd + 1):
            venc = soma_meses(contratacao, n)
            if venc > soma_meses(data_corte, 3):
                break  # parcelas muito futuras ainda não interessam
            seq_parcela += 1
            p = Parcela(f"PAR{seq_parcela:08d}", c.contrato_id, n, venc, valor_parcela)
            if venc <= data_corte:
                if perfil == "adimplente":
                    atraso = rng.choice([-2, -1, 0, 0, 0, 1, 2, 3])
                    p.data_pagamento = venc + timedelta(days=atraso)
                elif perfil == "atrasa_e_paga":
                    atraso = rng.randint(3, 75)
                    if venc + timedelta(days=atraso) <= data_corte:
                        p.data_pagamento = venc + timedelta(days=atraso)
                elif perfil == "inadimplente":
                    if n < parou_em:
                        p.data_pagamento = venc + timedelta(days=rng.randint(-1, 20))
                elif perfil == "erratico":
                    if rng.random() < 0.5:
                        p.data_pagamento = venc + timedelta(days=rng.randint(0, 120))
                        if p.data_pagamento > data_corte:
                            p.data_pagamento = None
                if p.data_pagamento is not None:
                    p.valor_pago = valor_parcela if rng.random() > 0.04 else round(valor_parcela * 0.5, 2)
            c.parcelas.append(p)
        contratos.append(c)

    # ---------------------------------------------------------------- contatos e acordos
    contatos, acordos, pagamentos = [], [], []
    seq_contato = seq_acordo = seq_pag = 0

    def registra_pagamento(contrato_id, parcela_id, acordo_id, num_acordo, dia, valor, origem):
        nonlocal seq_pag
        seq_pag += 1
        pagamentos.append({
            "pagamento_id": f"PAG{seq_pag:08d}",
            "contrato_id": contrato_id,
            "parcela_id": parcela_id or "",
            "acordo_id": acordo_id or "",
            "numero_parcela_acordo": num_acordo if num_acordo is not None else "",
            "data_pagamento": dia.isoformat(),
            "valor_pago": dinheiro(valor),
            "meio_pagamento": rng.choice(MEIOS_PAGAMENTO),
            "origem": origem,
            "recebido_em": (datetime.combine(dia, datetime.min.time())
                            + timedelta(hours=rng.randint(8, 22), minutes=rng.randint(0, 59))).isoformat(),
        })

    for c in contratos:
        for p in c.parcelas:
            if p.data_pagamento is not None:
                registra_pagamento(c.contrato_id, p.parcela_id, None, None, p.data_pagamento, p.valor_pago,
                                   "sistema_credor")

        vencidas = [p for p in c.parcelas if p.data_pagamento is None and p.vencimento < data_corte]
        if not vencidas:
            continue
        primeira = min(p.vencimento for p in vencidas)
        acordo_fechado = False
        # Parte da carteira nunca negocia (inalcançável, sem condição ou contestando a dívida):
        # para esses contratos, um resultado de "acordo" vira promessa ou interação sem fechamento.
        negocia = rng.random() < 0.5

        # Tentativas de contato seguindo a régua: cada faixa de atraso tem seus canais prioritários.
        dia = primeira + timedelta(days=1)
        while dia <= data_corte and not acordo_fechado:
            atraso = (dia - primeira).days
            if atraso <= 15:
                canais, tentativas = ["sms", "bot_whatsapp"], rng.randint(1, 2)
            elif atraso <= 60:
                canais, tentativas = ["discador", "bot_whatsapp", "sms"], rng.randint(2, 4)
            elif atraso <= 180:
                canais, tentativas = ["discador", "email", "ura"], rng.randint(1, 3)
            else:
                canais, tentativas = ["discador", "email"], rng.randint(0, 1)
            for _ in range(tentativas):
                canal = rng.choice(canais)
                resultado = sorteia(rng, RESULTADOS[canal])
                if not negocia and resultado in ("cpc_acordo", "bot_acordo"):
                    resultado = "cpc_promessa" if canal == "discador" else "respondido"
                seq_contato += 1
                hora = datetime.combine(dia, datetime.min.time()) + timedelta(hours=rng.randint(8, 20),
                                                                              minutes=rng.randint(0, 59))
                if resultado.startswith("cpc"):
                    duracao = rng.randint(20, 600)
                elif canal in ("discador", "ura"):
                    duracao = rng.randint(0, 25)
                else:
                    duracao = ""
                contatos.append({
                    "contato_id": f"CTT{seq_contato:08d}",
                    "contrato_id": c.contrato_id,
                    "cliente_id": c.cliente_id,
                    "data_hora_contato": hora.isoformat(),
                    "canal": canal,
                    "fornecedor": rng.choice(FORNECEDORES[canal]),
                    "resultado": resultado,
                    "duracao_seg": duracao,
                    "operador_id": f"OP{rng.randint(1, 60):03d}" if resultado.startswith("cpc") else "",
                    "campanha": f"{c.carteira.split()[0].upper()}-{fase_regua(atraso)}",
                    "custo_unitario": CUSTO_UNITARIO[canal],
                })
                if resultado in ("cpc_acordo", "bot_acordo") and not acordo_fechado:
                    acordo_fechado = True
                    seq_acordo += 1
                    divida = round(sum(p.valor for p in vencidas) * (1 + 0.0033 * atraso), 2)
                    desconto = rng.choice([0, 5, 10, 15, 20, 30, 40, 50]) if atraso > 30 else rng.choice([0, 0, 5])
                    valor_acordo = round(divida * (1 - desconto / 100), 2)
                    qtd_acordo = rng.choice([1, 1, 2, 3, 4, 6, 10, 12])
                    entrada = round(valor_acordo * (0.2 if qtd_acordo > 1 else 1.0), 2)
                    restante = round(valor_acordo - entrada, 2)
                    valor_parc_acordo = round(restante / (qtd_acordo - 1), 2) if qtd_acordo > 1 else 0.0
                    acordo_id = f"ACD{seq_acordo:06d}"
                    # comportamento do acordo: cumpre, quebra depois de algumas parcelas, ou nem paga a entrada
                    destino = rng.choices(["cumpre", "quebra", "nao_paga_entrada"], weights=[62, 30, 8], k=1)[0]
                    pagas = 0
                    if destino != "nao_paga_entrada":
                        d_ent = dia + timedelta(days=rng.randint(0, 3))
                        if d_ent <= data_corte:
                            registra_pagamento(c.contrato_id, None, acordo_id, 1, d_ent, entrada, "plataforma_acordo")
                            pagas = 1
                        quebra_em = rng.randint(2, max(2, qtd_acordo)) if destino == "quebra" else None
                        for k in range(2, qtd_acordo + 1):
                            if quebra_em and k >= quebra_em:
                                break
                            d_k = soma_meses(dia, k - 1) + timedelta(days=rng.randint(-2, 8))
                            if d_k <= data_corte:
                                registra_pagamento(c.contrato_id, None, acordo_id, k, d_k, valor_parc_acordo,
                                                   "plataforma_acordo")
                                pagas += 1
                    status_crm = "quitado" if pagas == qtd_acordo else "ativo"
                    if destino == "nao_paga_entrada" and (data_corte - dia).days > 10:
                        status_crm = "cancelado"
                    acordos.append({
                        "acordo_id": acordo_id,
                        "contrato_id": c.contrato_id,
                        "cliente_id": c.cliente_id,
                        "data_acordo": dia.isoformat(),
                        "canal_origem": canal,
                        "valor_divida": dinheiro(divida),
                        "desconto_pct": f"{desconto:.2f}",
                        "valor_acordo": dinheiro(valor_acordo),
                        "valor_entrada": dinheiro(entrada),
                        "qtd_parcelas": qtd_acordo,
                        "status_crm": status_crm,  # status como está no CRM, nem sempre atualizado
                        "atualizado_em": (dia + timedelta(days=rng.randint(0, 30))).isoformat() + "T18:00:00",
                    })
                    for p in vencidas:
                        p.em_acordo = True
            # a intensidade cai com o tempo: contratos antigos recebem menos tentativas por mês
            dia += timedelta(days=rng.randint(2, 9) if atraso <= 60 else rng.randint(6, 14) if atraso <= 180
                             else rng.randint(12, 30))

    # ---------------------------------------------------------------- serialização
    linhas_contratos, linhas_parcelas = [], []
    for c in contratos:
        tem_atraso = any(p.data_pagamento is None and p.vencimento < data_corte for p in c.parcelas)
        todas_pagas = bool(c.parcelas) and all(p.data_pagamento is not None for p in c.parcelas) \
            and c.parcelas[-1].numero == c.qtd_parcelas
        if todas_pagas:
            status = "quitado"
        elif any(p.em_acordo for p in c.parcelas):
            status = "em_acordo"
        elif tem_atraso:
            status = "inadimplente"
        else:
            status = "ativo"
        if rng.random() < 0.08:  # CRM desatualizado: status antigo
            status = "ativo"
        linhas_contratos.append({
            "contrato_id": c.contrato_id,
            "cliente_id": c.cliente_id,
            "credor": c.carteira,
            "produto": c.produto,
            "valor_contratado": dinheiro(c.valor_contratado),
            "data_contratacao": c.data_contratacao.isoformat(),
            "qtd_parcelas": c.qtd_parcelas,
            "valor_parcela": dinheiro(c.valor_parcela),
            "status_crm": status,
            "data_cessao": (c.data_contratacao + timedelta(days=rng.randint(30, 120))).isoformat(),
            "atualizado_em": (data_corte - timedelta(days=rng.randint(0, 90))).isoformat() + "T06:00:00",
        })
        for p in c.parcelas:
            if p.data_pagamento is not None and p.valor_pago >= p.valor:
                st = "paga"
            elif p.data_pagamento is not None:
                st = "paga_parcial"
            elif p.em_acordo:
                st = "renegociada"
            elif p.vencimento < data_corte:
                st = "vencida" if rng.random() > 0.05 else "aberta"  # 5% de status desatualizado
            else:
                st = "aberta"
            linhas_parcelas.append({
                "parcela_id": p.parcela_id,
                "contrato_id": p.contrato_id,
                "numero_parcela": p.numero,
                "data_vencimento": p.vencimento.isoformat(),
                "valor_parcela": dinheiro(p.valor),
                "status_origem": st,
            })

    return {
        "raw_clientes": clientes,
        "raw_contratos": linhas_contratos,
        "raw_parcelas": linhas_parcelas,
        "raw_acordos": acordos,
        "raw_pagamentos": pagamentos,
        "raw_contatos": contatos,
    }


def gravar(tabelas: dict[str, list[dict]], destino: Path) -> None:
    destino.mkdir(parents=True, exist_ok=True)
    for nome, linhas in tabelas.items():
        caminho = destino / f"{nome}.csv"
        with caminho.open("w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=list(linhas[0].keys()), lineterminator="\n")
            w.writeheader()
            w.writerows(linhas)
        print(f"{caminho.name}: {len(linhas):,} linhas")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=int, default=2026, help="semente do gerador (padrão 2026)")
    ap.add_argument("--data-corte", default=date.today().isoformat(), help="último dia com dados (AAAA-MM-DD)")
    ap.add_argument("--clientes", type=int, default=600, help="quantidade de clientes (padrão 600)")
    ap.add_argument("--destino", default=str(SEEDS), help="pasta de saída (padrão seeds/)")
    args = ap.parse_args()
    data_corte = date.fromisoformat(args.data_corte)
    gravar(gerar(args.seed, data_corte, args.clientes), Path(args.destino))


if __name__ == "__main__":
    main()
