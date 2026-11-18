-- ============================================================================
-- Construtora Axial — permissão de exclusão definitiva para o administrador
-- Rode DEPOIS do 05-rubrica-foto.sql. É repetível.
--
-- POR QUE ESTE SCRIPT EXISTE
-- A V13 acrescentou "Esvaziar lixeira" e a V15 acrescentou o apagar item a item.
-- As duas falhavam com "permission denied for table dts".
--
-- A causa é uma armadilha do Postgres que vale registrar: **a policy de RLS não
-- concede nada.** Ela só filtra o que um privilégio já concedido pode alcançar.
-- O `dts_admin_tudo ... for all to authenticated` dá a impressão de liberar tudo,
-- mas o GRANT de tabela do 02-autenticacao.sql era:
--
--     grant select, update on public.dts to authenticated;
--
-- Sem DELETE. O Postgres barra no GRANT, antes de olhar a policy — daí a mensagem
-- falar em "table", não em "row-level security".
--
-- Ao concluir que "o admin pode tudo porque a policy é `for all`", confira o GRANT.
-- ============================================================================

begin;

grant delete on public.dts to authenticated;
grant delete on public.pt  to authenticated;

-- Os filhos somem por `on delete cascade` (ver esquema-inicial.sql), e a ação
-- referencial roda com os privilégios do dono da tabela, sem passar por RLS.
-- Concedo mesmo assim: custa nada e tira a dúvida se um dia alguém apagar a
-- equipe sem apagar o documento.
grant delete on public.dts_colaborador to authenticated;
grant delete on public.pt_colaborador  to authenticated;

-- O anônimo continua sem NADA nestas tabelas — só as funções de registro.
revoke all on public.dts             from anon;
revoke all on public.pt              from anon;
revoke all on public.dts_colaborador from anon;
revoke all on public.pt_colaborador  from anon;

-- Privilégios que o Supabase concede sozinho e que RLS não cobre. TRUNCATE é o
-- perigoso: não passa por policy nenhuma, e a chave anon está publicada no HTML.
revoke truncate, trigger, references on public.dts             from anon, authenticated;
revoke truncate, trigger, references on public.pt              from anon, authenticated;
revoke truncate, trigger, references on public.dts_colaborador from anon, authenticated;
revoke truncate, trigger, references on public.pt_colaborador  from anon, authenticated;
revoke truncate, trigger, references on public.colaboradores   from anon, authenticated;

commit;

-- ---------------------------------------------------------------- conferência
-- Deve listar delete = true para authenticated e nada para anon.
select grantee, privilege_type
  from information_schema.role_table_grants
 where table_schema = 'public'
   and table_name in ('dts','pt','dts_colaborador','pt_colaborador')
   and grantee in ('anon','authenticated')
 order by table_name, grantee, privilege_type;
