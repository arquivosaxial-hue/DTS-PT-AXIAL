-- ============================================================================
-- Construtora Axial — rubrica de referência, hora da rubrica e foto
-- Rode DEPOIS do 04-efetivo.sql. É repetível.
--
-- ORDEM IMPORTA: rode este script ANTES de publicar a V10, pelo mesmo motivo
-- do 04 — a V10 manda campos novos dentro de p_colaboradores, e a função
-- antiga os ignoraria em silêncio. Na ordem certa não há janela de quebra:
-- a função nova aceita o formato da V9, que só não traz os campos novos.
--
-- PARA QUE SERVE
-- Dois problemas relatados pela Axial em 25/08/2026:
--
--   1. Um colaborador assina por todos, para ganhar tempo na frente.
--   2. Ninguém tem rubrica padrão — cada documento sai com um desenho
--      diferente, e aí nenhum perito grafotécnico consegue comparar nada.
--
-- Contra (1): hora de cada rubrica. Quatro rubricas em 25 segundos foi uma
-- pessoa só; quatro ao longo de seis minutos foi reunião de verdade. E a foto
-- do momento da rubrica, que obriga a aparecerem rostos diferentes.
--
-- Contra (2): uma rubrica de referência colhida uma vez, no escritório, que
-- serve de memória para o trabalhador e de padrão de comparação depois.
-- ============================================================================

begin;

-- ------------------------------------------------- rubrica de referência
-- Duas colunas de propósito, e a diferença entre elas é de segurança:
--
--   rubrica_ref  — qualidade cheia (320x120). NUNCA sai para o app de campo.
--                  Só o admin autenticado enxerga, para comparar e para perícia.
--   rubrica_mini — miniatura grosseira (~100x38). Vai para o celular, sem login,
--                  só para o trabalhador lembrar como ele mesmo assina.
--
-- Se a referência cheia fosse devolvida por listar_efetivo(), qualquer um com a
-- chave anon — que está publicada no HTML — baixaria o padrão de assinatura dos
-- 28. Seria entregar de bandeja justamente o que se quer proteger. A miniatura
-- serve de lembrete e é ruim demais para decalcar.
alter table public.colaboradores add column if not exists rubrica_ref  text;
alter table public.colaboradores add column if not exists rubrica_mini text;

-- ------------------------------------- o que cada rubrica passa a registrar
--
--   rubricado_em — relógio do aparelho. Serve para exibir, não para provar:
--                  dá para mudar a hora do celular.
--   t_rel_ms     — milissegundos desde a abertura do formulário, medidos por
--                  performance.now(), que NÃO acompanha o relógio. É daqui que
--                  sai o intervalo entre uma rubrica e a seguinte, e mexer na
--                  hora do aparelho não maquia isso.
--   foto_path    — caminho no bucket `rubricas`. Nulo quando não houve foto,
--                  que é situação legítima: recusa do trabalhador ou câmera
--                  negada. Ausência de foto nunca impede emitir o documento.
alter table public.dts_colaborador add column if not exists rubricado_em timestamptz;
alter table public.dts_colaborador add column if not exists t_rel_ms     integer;
alter table public.dts_colaborador add column if not exists foto_path    text;
alter table public.pt_colaborador  add column if not exists rubricado_em timestamptz;
alter table public.pt_colaborador  add column if not exists t_rel_ms     integer;
alter table public.pt_colaborador  add column if not exists foto_path    text;

commit;

-- ==========================================================================
-- listar_efetivo passa a levar a MINIATURA — nunca a referência cheia
-- ==========================================================================
drop function if exists public.listar_efetivo();

create or replace function public.listar_efetivo()
returns table (codigo text, nome text, funcao text, rubrica_mini text)
language sql stable security definer set search_path = public as $fn$
  select c.codigo, c.nome, c.funcao, c.rubrica_mini
    from public.colaboradores c
   where c.situacao = 'ativo'
   order by c.nome
$fn$;

grant execute on function public.listar_efetivo() to anon, authenticated;

-- ==========================================================================
-- As funções de registro guardam hora, tempo relativo e foto
-- ==========================================================================
-- Leitores tolerantes: item da V9 (sem os campos novos) devolve null em todos,
-- e o documento entra igual. É o que permite subir o script antes do app.
create or replace function public.colab_ts(p jsonb) returns timestamptz
language sql immutable as $fn$
  select case when jsonb_typeof(p) = 'object'
              then nullif(p->>'rubricado_em','')::timestamptz end
$fn$;

create or replace function public.colab_trel(p jsonb) returns integer
language sql immutable as $fn$
  select case when jsonb_typeof(p) = 'object'
              then nullif(p->>'t_rel_ms','')::integer end
$fn$;

create or replace function public.colab_foto(p jsonb) returns text
language sql immutable as $fn$
  select case when jsonb_typeof(p) = 'object' then nullif(p->>'foto_path','') end
$fn$;

create or replace function public.registrar_dts(
  p_registro jsonb, p_colaboradores jsonb default '[]'::jsonb, p_pdf_path text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cliente_id text := nullif(p_registro->>'cliente_id','');
  v_os_base    text := nullif(p_registro->>'numero_os_base','');
  v_data       date := nullif(p_registro->>'data_atividade','')::date;
  v_rev        integer := 0;
  v_id         uuid;
  v_numero_os  text;
  v_ja         record;
begin
  perform public.validar_documento(p_registro, p_colaboradores);

  if v_cliente_id is not null then
    select id, numero_os, revisao into v_ja from public.dts where cliente_id = v_cliente_id;
    if found then
      return jsonb_build_object('id', v_ja.id, 'numero_os', v_ja.numero_os,
                                'revisao', v_ja.revisao, 'ja_existia', true);
    end if;
  end if;

  if v_os_base is not null and v_data is not null then
    perform pg_advisory_xact_lock(hashtext('dts:' || v_os_base || ':' || v_data::text));
    select coalesce(max(revisao) + 1, 0) into v_rev
      from public.dts where numero_os_base = v_os_base and data_atividade = v_data;
  end if;

  v_numero_os := coalesce(v_os_base, p_registro->>'numero_os');
  if v_rev > 0 then
    v_numero_os := v_numero_os || ' Rev.' || lpad(v_rev::text, 2, '0');
  end if;

  insert into public.dts (
    cliente_id, numero_os, numero_os_base, revisao, data_atividade, horario_emissao,
    elaborador, lider_frente, area_setor, atividade, localizacao,
    tipo_equipe, empresa, atividades_criticas, riscos, epis,
    barreiras_controle, barreiras_protecao, barreiras_suporte, outros, status, pdf_path
  ) values (
    v_cliente_id, v_numero_os, v_os_base, v_rev, v_data,
    nullif(p_registro->>'horario_emissao','')::time,
    p_registro->>'elaborador', p_registro->>'lider_frente', p_registro->>'area_setor',
    p_registro->>'atividade', p_registro->>'localizacao',
    p_registro->>'tipo_equipe', p_registro->>'empresa',
    coalesce(p_registro->'atividades_criticas', '[]'::jsonb),
    coalesce(p_registro->'riscos',              '[]'::jsonb),
    coalesce(p_registro->'epis',                '[]'::jsonb),
    coalesce(p_registro->'barreiras_controle',  '[]'::jsonb),
    coalesce(p_registro->'barreiras_protecao',  '[]'::jsonb),
    coalesce(p_registro->'barreiras_suporte',   '[]'::jsonb),
    coalesce(p_registro->'outros',              '{}'::jsonb),
    coalesce(nullif(p_registro->>'status',''), 'finalizada'),
    p_pdf_path
  ) returning id into v_id;

  if jsonb_typeof(p_colaboradores) = 'array' then
    insert into public.dts_colaborador (dts_id, codigo, nome, ordem, rubricado_em, t_rel_ms, foto_path)
    select v_id, public.colab_codigo(e.valor), public.colab_nome(e.valor), e.ord - 1,
           public.colab_ts(e.valor), public.colab_trel(e.valor), public.colab_foto(e.valor)
      from jsonb_array_elements(p_colaboradores) with ordinality as e(valor, ord)
     where nullif(trim(coalesce(public.colab_nome(e.valor),'')), '') is not null;
  end if;

  return jsonb_build_object('id', v_id, 'numero_os', v_numero_os,
                            'revisao', v_rev, 'ja_existia', false);
end;
$$;

create or replace function public.registrar_pt(
  p_registro jsonb, p_colaboradores jsonb default '[]'::jsonb, p_pdf_path text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cliente_id text := nullif(p_registro->>'cliente_id','');
  v_tipo       text := nullif(p_registro->>'tipo','');
  v_os_base    text := nullif(p_registro->>'numero_os_base','');
  v_data       date := nullif(p_registro->>'data_atividade','')::date;
  v_rev        integer := 0;
  v_id         uuid;
  v_numero_os  text;
  v_ja         record;
begin
  perform public.validar_documento(p_registro, p_colaboradores);

  if v_tipo is null then
    raise exception 'tipo da PT é obrigatório';
  end if;

  if v_cliente_id is not null then
    select id, numero_os, revisao into v_ja from public.pt where cliente_id = v_cliente_id;
    if found then
      return jsonb_build_object('id', v_ja.id, 'numero_os', v_ja.numero_os,
                                'revisao', v_ja.revisao, 'ja_existia', true);
    end if;
  end if;

  if v_os_base is not null and v_data is not null then
    perform pg_advisory_xact_lock(hashtext('pt:' || v_tipo || ':' || v_os_base || ':' || v_data::text));
    select coalesce(max(revisao) + 1, 0) into v_rev
      from public.pt
     where tipo = v_tipo and numero_os_base = v_os_base and data_atividade = v_data;
  end if;

  v_numero_os := coalesce(v_os_base, p_registro->>'numero_os');
  if v_rev > 0 then
    v_numero_os := v_numero_os || ' Rev.' || lpad(v_rev::text, 2, '0');
  end if;

  insert into public.pt (
    cliente_id, tipo, numero_os, numero_os_base, revisao, data_atividade, horario_emissao,
    turno, tipo_equipe, empresa, setor, local_trabalho, lider_atividade, descricao_trabalho,
    avaliacao, atividade_segura, ciente, especificos,
    emissor_nome, emissor_area, verificador_nome, verificador_area, status, pdf_path
  ) values (
    v_cliente_id, v_tipo, v_numero_os, v_os_base, v_rev, v_data,
    nullif(p_registro->>'horario_emissao','')::time,
    p_registro->>'turno', p_registro->>'tipo_equipe', p_registro->>'empresa',
    p_registro->>'setor', p_registro->>'local_trabalho', p_registro->>'lider_atividade',
    p_registro->>'descricao_trabalho',
    coalesce(p_registro->'avaliacao',   '[]'::jsonb),
    p_registro->>'atividade_segura',
    coalesce((p_registro->>'ciente')::boolean, false),
    coalesce(p_registro->'especificos', '{}'::jsonb),
    p_registro->>'emissor_nome', p_registro->>'emissor_area',
    p_registro->>'verificador_nome', p_registro->>'verificador_area',
    coalesce(nullif(p_registro->>'status',''), 'finalizada'),
    p_pdf_path
  ) returning id into v_id;

  if jsonb_typeof(p_colaboradores) = 'array' then
    insert into public.pt_colaborador (pt_id, codigo, nome, ordem, rubricado_em, t_rel_ms, foto_path)
    select v_id, public.colab_codigo(e.valor), public.colab_nome(e.valor), e.ord - 1,
           public.colab_ts(e.valor), public.colab_trel(e.valor), public.colab_foto(e.valor)
      from jsonb_array_elements(p_colaboradores) with ordinality as e(valor, ord)
     where nullif(trim(coalesce(public.colab_nome(e.valor),'')), '') is not null;
  end if;

  return jsonb_build_object('id', v_id, 'numero_os', v_numero_os,
                            'revisao', v_rev, 'ja_existia', false);
end;
$$;

grant execute on function public.registrar_dts(jsonb, jsonb, text) to anon, authenticated;
grant execute on function public.registrar_pt(jsonb, jsonb, text)  to anon, authenticated;

-- ==========================================================================
-- Bucket das fotos — mais fechado que o dos PDFs
-- ==========================================================================
-- O `dts-pdfs` precisa dar SELECT ao anon porque o QR do fiscal exige link
-- assinado gerado sem login (ver 02-autenticacao.sql). Nada disso vale aqui:
-- foto de rosto nunca é compartilhada por QR. Então ao anon sobra INSERT e
-- mais nada — ele grava e nunca lê de volta. Quem lê é o admin autenticado.
--
-- O limite de MIME é o que impede o bucket virar depósito de arquivo qualquer,
-- e 2 MB já é folgado para uma foto que o app manda em 640x480.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('rubricas', 'rubricas', false, 2097152, array['image/jpeg'])
on conflict (id) do update
  set public = false, file_size_limit = 2097152, allowed_mime_types = array['image/jpeg'];

drop policy if exists "rubricas anon gravar" on storage.objects;
create policy "rubricas anon gravar" on storage.objects
  for insert to anon with check (bucket_id = 'rubricas');

-- sem policy de select/update/delete para anon: o que ele grava, ele não relê.
-- (o revoke global de delete e update em storage.objects já vale para este bucket)

drop policy if exists "rubricas admin ler"    on storage.objects;
drop policy if exists "rubricas admin gravar" on storage.objects;
drop policy if exists "rubricas admin apagar" on storage.objects;
create policy "rubricas admin ler"    on storage.objects for select to authenticated using (bucket_id = 'rubricas');
create policy "rubricas admin gravar" on storage.objects for insert to authenticated with check (bucket_id = 'rubricas');
create policy "rubricas admin apagar" on storage.objects for delete to authenticated using (bucket_id = 'rubricas');
