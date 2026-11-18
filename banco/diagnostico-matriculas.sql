-- ============================================================================
-- DIAGNÓSTICO — matrículas duplicadas por perda de zero à esquerda
-- SOMENTE LEITURA. Não altera nada. Pode rodar à vontade.
--
-- Responde: o duplicado nasceu da importação de hoje, ou a pessoa já assinou
-- documento sob as duas matrículas?
-- ============================================================================

-- ---------------------------------------------------------------- CONSULTA 1
-- Todos os pares "sem zero" x "com zero" do cadastro — a extensão real do problema.
select
  a.codigo       as sem_zero,
  b.codigo       as com_zero,
  a.nome,
  a.situacao     as situacao_sem_zero,
  b.situacao     as situacao_com_zero,
  a.atualizado_em as quando_sem_zero,
  b.atualizado_em as quando_com_zero
from public.colaboradores a
join public.colaboradores b
  on b.codigo = lpad(a.codigo, 6, '0')
 and b.codigo <> a.codigo
where a.codigo ~ '^[0-9]+$'          -- só matrícula numérica; ignora IBISA01 e afins
order by a.nome;

-- ---------------------------------------------------------------- CONSULTA 2
-- A pergunta principal: quantos documentos existem sob CADA matrícula, e quando.
-- Se uma das colunas vier zerada, o duplicado é só cadastro — ninguém assinou por ela.
with alvos as (
  select a.codigo as sem_zero, lpad(a.codigo, 6, '0') as com_zero, a.nome
    from public.colaboradores a
   where a.codigo ~ '^[0-9]+$'
     and exists (select 1 from public.colaboradores b
                  where b.codigo = lpad(a.codigo, 6, '0') and b.codigo <> a.codigo)
)
select
  t.nome,
  t.codigo,
  (select count(*) from public.dts_colaborador dc where dc.codigo = t.codigo)                      as dts,
  (select count(*) from public.pt_colaborador  pc where pc.codigo = t.codigo)                      as pt,
  (select min(d.data_atividade) from public.dts_colaborador dc
      join public.dts d on d.id = dc.dts_id where dc.codigo = t.codigo)                            as primeira_dts,
  (select max(d.data_atividade) from public.dts_colaborador dc
      join public.dts d on d.id = dc.dts_id where dc.codigo = t.codigo)                            as ultima_dts
from (
  select nome, sem_zero  as codigo from alvos
  union all
  select nome, com_zero  as codigo from alvos
) t
order by t.nome, t.codigo;

-- ---------------------------------------------------------------- CONSULTA 3
-- Quem assinou SEM matrícula nenhuma (registros anteriores à V18, quando o nome
-- digitado à mão ainda era aceito). Eles não aparecem no filtro por pessoa.
select coalesce(nome,'(sem nome)') as nome, count(*) as documentos,
       min(created_at::date) as primeiro, max(created_at::date) as ultimo
  from public.dts_colaborador
 where codigo is null
 group by nome
 order by documentos desc;
