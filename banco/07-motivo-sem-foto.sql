-- ============================================================================
-- Construtora Axial — por que este colaborador ficou sem foto
-- Rode DEPOIS do 06-exclusao-definitiva.sql. É repetível.
--
-- POR QUE EXISTE
-- Primeiro teste em campo (01/09/2026): numa DTS de 4 pessoas, 3 saíram com foto
-- e 1 sem. O "Sem foto" era um toque só, sem atrito e sem rastro — e no relatório
-- virava uma moldura vazia que não dizia nada. Ausência ambígua não serve de prova
-- nem de gestão: não dá para saber se o trabalhador recusou (direito dele) ou se
-- o encarregado pulou a etapa.
--
-- POR QUE NÃO SE TRAVA A EMISSÃO
-- Duas razões, e as duas pesam mais que a conveniência de travar:
--
--   1. A cláusula 10 do termo assinado pelo trabalhador diz que recusar a foto
--      "não gera qualquer sanção" e que "o documento de segurança continua sendo
--      emitido". App que trava contradiz o documento assinado — e consentimento
--      que não pode ser recusado não é consentimento livre (art. 11 da LGPD).
--      O tiro sai pela culatra: derruba o valor de TODAS as fotos, não só da que
--      faltou.
--   2. Câmera negada pelo sistema ou lente quebrada impediriam emitir documento
--      de segurança em campo — ver 2.4.
--
-- Então o caminho é o mesmo da regra 2.3 (risco Alto sem barreira de Controle):
-- avisa, exige confirmação explícita, registra. Nunca bloqueia.
-- ============================================================================

begin;

-- null   = tem foto
-- 'recusou'      = o trabalhador não autorizou (direito dele, previsto no termo)
-- 'indisponivel' = câmera negada, quebrada ou ausente no aparelho
alter table public.dts_colaborador add column if not exists foto_motivo text;
alter table public.pt_colaborador  add column if not exists foto_motivo text;

commit;

-- ==========================================================================
-- As funções de registro passam a gravar o motivo
-- ==========================================================================
create or replace function public.colab_motivo(p jsonb) returns text
language sql immutable as $fn$
  select case when jsonb_typeof(p) = 'object' then nullif(p->>'foto_motivo','') end
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
    insert into public.dts_colaborador (dts_id, codigo, nome, ordem, rubricado_em, t_rel_ms, foto_path, foto_motivo)
    select v_id, public.colab_codigo(e.valor), public.colab_nome(e.valor), e.ord - 1,
           public.colab_ts(e.valor), public.colab_trel(e.valor), public.colab_foto(e.valor),
           public.colab_motivo(e.valor)
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
    insert into public.pt_colaborador (pt_id, codigo, nome, ordem, rubricado_em, t_rel_ms, foto_path, foto_motivo)
    select v_id, public.colab_codigo(e.valor), public.colab_nome(e.valor), e.ord - 1,
           public.colab_ts(e.valor), public.colab_trel(e.valor), public.colab_foto(e.valor),
           public.colab_motivo(e.valor)
      from jsonb_array_elements(p_colaboradores) with ordinality as e(valor, ord)
     where nullif(trim(coalesce(public.colab_nome(e.valor),'')), '') is not null;
  end if;

  return jsonb_build_object('id', v_id, 'numero_os', v_numero_os,
                            'revisao', v_rev, 'ja_existia', false);
end;
$$;

grant execute on function public.registrar_dts(jsonb, jsonb, text) to anon, authenticated;
grant execute on function public.registrar_pt(jsonb, jsonb, text)  to anon, authenticated;
