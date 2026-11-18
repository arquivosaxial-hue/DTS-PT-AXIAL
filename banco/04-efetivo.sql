-- ============================================================================
-- Construtora Axial — efetivo e rastreabilidade por colaborador
-- Rode DEPOIS do 03-endurecimento.sql. É repetível.
--
-- ORDEM IMPORTA: rode este script ANTES de publicar a V6.
-- A V6 manda a equipe como jsonb com matrícula; a função antiga só aceita text[].
-- Publicar primeiro deixaria o app sem conseguir salvar documento em campo.
-- Na ordem certa não há janela de quebra: a função nova aceita as duas formas,
-- então a V5 que ainda estiver nos celulares continua salvando normalmente.
--
-- PARA QUE SERVE
-- Ações trabalhistas em que se alega ter executado atividade que não se executou.
-- A defesa depende de responder, anos depois: "que serviços o colaborador 001104
-- assinou, em que datas, em quais OS?". Isso exige que atividade e pessoa sejam
-- dado CONSULTÁVEL, não texto livre.
--
-- Texto livre vira "Reaterro", "reaterro", "Reat." — três coisas para o banco.
-- Nome digitado vira "João da Silva", "Joao Silva", "J. da Silva" — três pessoas.
-- Com matrícula e lista fechada de serviços, vira consulta.
-- ============================================================================

begin;

-- ------------------------------------------------------------------ efetivo
-- A matrícula é TEXT de propósito: '001104' com zeros à esquerda. Como número,
-- viraria 1104 e o vínculo com a planilha do RH quebraria.
create table if not exists public.colaboradores (
  codigo        text primary key,
  nome          text not null,
  funcao        text,
  -- ativo | afastado | desligado. NUNCA apagar linha: quem processa a empresa
  -- costuma ser ex-funcionário, e é justamente dele que se precisa do histórico.
  situacao      text not null default 'ativo',
  atualizado_em timestamptz not null default now()
);

create index if not exists colaboradores_nome_idx on public.colaboradores (lower(nome));

alter table public.colaboradores enable row level security;

-- só o admin cadastra e altera
drop policy if exists colab_admin on public.colaboradores;
create policy colab_admin on public.colaboradores for all to authenticated
  using (public.e_admin()) with check (public.e_admin());

grant select, insert, update, delete on public.colaboradores to authenticated;
revoke all on public.colaboradores from anon;
revoke truncate, trigger, references on public.colaboradores from anon, authenticated;

-- O encarregado NÃO tem login, mas precisa da lista para escolher a equipe — e
-- precisa dela OFFLINE, o que obriga o app a baixar e guardar no aparelho.
-- Esta função devolve só quem está ativo e só três campos. Nada de CPF, salário,
-- férias ou ASO: esses ficam no Controle de Obra, que é outro sistema.
--
-- RISCO ACEITO: a lista de ativos é legível por quem tiver a chave publicada.
-- Como ela é baixada para o aparelho de qualquer forma (exigência do offline),
-- restringir aqui não mudaria o resultado prático.
create or replace function public.listar_efetivo()
returns table (codigo text, nome text, funcao text)
language sql stable security definer set search_path = public as $fn$
  select c.codigo, c.nome, c.funcao
    from public.colaboradores c
   where c.situacao = 'ativo'
   order by c.nome
$fn$;

grant execute on function public.listar_efetivo() to anon, authenticated;

-- ------------------------------------------- a DTS passa a guardar a matrícula
-- Sem isto o filtro por pessoa não existe: hoje só há o nome digitado.
alter table public.dts_colaborador add column if not exists codigo text;
alter table public.pt_colaborador  add column if not exists codigo text;

create index if not exists dts_colab_codigo_idx on public.dts_colaborador (codigo);
create index if not exists pt_colab_codigo_idx  on public.pt_colaborador (codigo);

-- Busca por nome também precisa de índice: colaborador de fora do efetivo entra
-- digitado à mão e não tem matrícula, mas ainda assim é o que se procura.
create index if not exists dts_colab_nome_idx on public.dts_colaborador (lower(nome));
create index if not exists pt_colab_nome_idx  on public.pt_colaborador  (lower(nome));

-- índices dos filtros novos do painel
create index if not exists dts_os_idx        on public.dts (numero_os_base);
create index if not exists dts_atividade_idx on public.dts (atividade);

commit;

-- ==========================================================================
-- As funções de registro passam a aceitar matrícula junto do nome
-- ==========================================================================
-- p_colaboradores muda de text[] para jsonb, aceitando DUAS formas:
--
--   ["Fulano","Ciclano"]                          <- app antigo, ainda na fila
--   [{"codigo":"001104","nome":"Anderson"}, ...]  <- app novo
--
-- A primeira forma continua funcionando de propósito: pode haver DTS presa na
-- fila offline de um aparelho que ainda não atualizou, e ela precisa subir.
-- Nesse caso entra sem matrícula — o que é honesto, porque de fato não havia.
--
-- Colaborador digitado à mão (terceirizado, contratado naquela manhã) também
-- entra sem matrícula. Aparece no PDF e na equipe, mas não no filtro por pessoa.

drop function if exists public.registrar_dts(jsonb, text[], text);
drop function if exists public.registrar_pt(jsonb, text[], text);
drop function if exists public.validar_documento(jsonb, text[]);

create or replace function public.validar_documento(p_registro jsonb, p_colaboradores jsonb)
returns void language plpgsql immutable as $val$
declare
  v_data date := nullif(p_registro->>'data_atividade','')::date;
begin
  if length(coalesce(p_registro->>'numero_os_base', p_registro->>'numero_os', '')) > 40 then
    raise exception 'numero da OS longo demais';
  end if;
  if length(coalesce(p_registro->>'atividade','')) > 500
     or length(coalesce(p_registro->>'localizacao','')) > 500
     or length(coalesce(p_registro->>'descricao_trabalho','')) > 2000 then
    raise exception 'texto longo demais';
  end if;
  if v_data is not null and (v_data < current_date - interval '2 years'
                          or v_data > current_date + interval '30 days') then
    raise exception 'data da atividade fora do intervalo aceito';
  end if;
  if jsonb_typeof(p_registro->'riscos') = 'array'
     and jsonb_array_length(p_registro->'riscos') > 300 then
    raise exception 'riscos demais num documento so';
  end if;
  if jsonb_typeof(p_registro->'avaliacao') = 'array'
     and jsonb_array_length(p_registro->'avaliacao') > 300 then
    raise exception 'itens de avaliacao demais';
  end if;
  if jsonb_typeof(p_colaboradores) = 'array'
     and jsonb_array_length(p_colaboradores) > 100 then
    raise exception 'colaboradores demais num documento so';
  end if;
  if length(p_registro::text) > 400000 then
    raise exception 'documento grande demais';
  end if;
end
$val$;

-- extrai nome e matrícula de um elemento, seja ele texto puro ou objeto
create or replace function public.colab_nome(p jsonb) returns text
language sql immutable as $fn$
  select case when jsonb_typeof(p) = 'object' then p->>'nome' else p #>> '{}' end
$fn$;

create or replace function public.colab_codigo(p jsonb) returns text
language sql immutable as $fn$
  select case when jsonb_typeof(p) = 'object' then nullif(p->>'codigo','') else null end
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
    insert into public.dts_colaborador (dts_id, codigo, nome, ordem)
    select v_id, public.colab_codigo(e.valor), public.colab_nome(e.valor), e.ord - 1
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
    insert into public.pt_colaborador (pt_id, codigo, nome, ordem)
    select v_id, public.colab_codigo(e.valor), public.colab_nome(e.valor), e.ord - 1
      from jsonb_array_elements(p_colaboradores) with ordinality as e(valor, ord)
     where nullif(trim(coalesce(public.colab_nome(e.valor),'')), '') is not null;
  end if;

  return jsonb_build_object('id', v_id, 'numero_os', v_numero_os,
                            'revisao', v_rev, 'ja_existia', false);
end;
$$;

grant execute on function public.registrar_dts(jsonb, jsonb, text) to anon, authenticated;
grant execute on function public.registrar_pt(jsonb, jsonb, text)  to anon, authenticated;
revoke all on function public.validar_documento(jsonb, jsonb) from public;
