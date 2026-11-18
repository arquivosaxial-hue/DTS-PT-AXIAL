-- ============================================================================
-- Construtora Axial — endurecimento pós-varredura (20/08/2026)
-- Rode DEPOIS do 02-autenticacao.sql. É repetível: pode rodar quantas vezes quiser.
--
-- Fecha três coisas que sobraram depois de blindar as tabelas:
--   A2 — o PDF podia ser SOBRESCRITO com a chave publicada (falsificação)
--   A3 — qualquer conta autenticada era administrador total
--   A4 — nada limitava quem chama a função de emissão
-- ============================================================================

begin;

-- ==========================================================================
-- A3 — papel de verdade, em vez de "todo autenticado é admin"
-- ==========================================================================
create table if not exists public.perfis (
  usuario_id uuid primary key references auth.users(id) on delete cascade,
  nome       text not null,
  papel      text not null check (papel in ('admin')),
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);

alter table public.perfis enable row level security;

drop policy if exists perfis_proprio on public.perfis;
create policy perfis_proprio on public.perfis
  for select to authenticated using (usuario_id = auth.uid());

grant usage on schema public to authenticated;
grant select on public.perfis to authenticated;
revoke truncate, trigger, references on public.perfis from anon, authenticated;

-- SECURITY DEFINER evita recursão: a policy de uma tabela consultaria outra
-- tabela protegida por policy, e o Postgres entraria em laço.
create or replace function public.e_admin() returns boolean
  language sql stable security definer set search_path = public as $fn$
  select exists (
    select 1 from public.perfis
     where usuario_id = auth.uid() and papel = 'admin' and ativo
  )
$fn$;

-- Cadastra o administrador atual. Falha ALTO se o usuário não existir — melhor
-- parar aqui do que aplicar as policies novas e te deixar sem acesso ao painel.
do $seed$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = 'benedito@construtoraaxial.com.br';
  if v_id is null then
    raise exception 'O usuario benedito@construtoraaxial.com.br nao existe em auth.users. Crie-o em Authentication > Users (com Auto Confirm) ANTES de rodar este script, senao voce fica sem acesso ao painel.';
  end if;
  insert into public.perfis (usuario_id, nome, papel)
  values (v_id, 'Benedito', 'admin')
  on conflict (usuario_id) do update set papel = 'admin', ativo = true;
end
$seed$;

-- as policies passam a checar o papel, não só "estar logado"
drop policy if exists dts_admin_tudo  on public.dts;
drop policy if exists pt_admin_tudo   on public.pt;
drop policy if exists dts_colab_admin on public.dts_colaborador;
drop policy if exists pt_colab_admin  on public.pt_colaborador;

create policy dts_admin_tudo  on public.dts for all to authenticated
  using (public.e_admin()) with check (public.e_admin());
create policy pt_admin_tudo   on public.pt  for all to authenticated
  using (public.e_admin()) with check (public.e_admin());
create policy dts_colab_admin on public.dts_colaborador for select to authenticated
  using (public.e_admin());
create policy pt_colab_admin  on public.pt_colaborador  for select to authenticated
  using (public.e_admin());

-- A4 (limites de entrada) foi para o 02-autenticacao.sql, dentro das proprias
-- funcoes de registro: la e onde o corpo delas vive, e duplicar aqui criaria
-- duas versoes da mesma logica.

commit;

-- ==========================================================================
-- A2 — o PDF não pode mais ser sobrescrito nem substituído
-- ==========================================================================
-- Fechamos o banco, mas o bucket seguia aberto para escrita: com a chave do HTML
-- dava para SUBSTITUIR o PDF de uma DTS real mantendo o mesmo caminho. O registro
-- continuaria íntegro apontando para um arquivo trocado — falsificação de
-- documento assinado, sem tocar no banco.
--
-- Tirando o UPDATE, o upload passa a ser só criação. O cliente foi ajustado para
-- upsert:false na mesma leva; como o nome do arquivo leva Date.now(), colisão é
-- improvável, e se houver o envio falha em vez de sobrescrever.
revoke update on storage.objects from anon;
drop policy if exists "dts-pdfs anon atualizar" on storage.objects;

-- NOTA: falta um passo que só dá para fazer no painel do Supabase —
-- Storage > dts-pdfs > Settings:
--   * Allowed MIME types: application/pdf
--   * File size limit:    10 MB
-- Sem isso, a chave publicada ainda consegue subir arquivo de qualquer tipo e
-- tamanho e encher a cota. O SQL nao alcanca essa configuracao.
