-- ============================================================================
-- Construtora Axial — fechamento do banco + autenticação do administrador
-- Rode DEPOIS do 01-esquema-inicial.sql e DEPOIS de criar o usuário admin.
--
-- O QUE MUDA, e por quê:
--
-- Hoje a chave `anon` — que está publicada no HTML — pode ler, alterar e apagar
-- tudo. A senha do painel só esconde a TELA; quem usa a chave direto nem passa
-- por ela. Trocar a senha por login não resolve isso sozinho.
--
-- A partir daqui:
--   * anon NÃO tem privilégio nenhum nas tabelas. Nem select, nem insert.
--   * A emissão passa por uma FUNÇÃO que valida e grava. É o único caminho.
--   * Só o administrador autenticado lê e administra.
--
-- De quebra, a função resolve dois defeitos que o cliente não conseguia resolver
-- sozinho: documento e equipe entram na MESMA transação (nunca mais DTS órfã
-- sem equipe), e o número da revisão é calculado sob trava, não por palpite.
-- ============================================================================

begin;


-- ------------------------------------------------------- limites de entrada
-- A RPC e o unico caminho de escrita, e qualquer um com a chave publicada pode
-- chama-la em laco. Sem limite, da para encher o banco de documento falso ou
-- gigante. Estes tetos sao folgados para uso real e apertados para abuso.
create or replace function public.validar_documento(p_registro jsonb, p_colaboradores text[])
returns void
language plpgsql
immutable
as $val$
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
  -- data absurda costuma ser abuso ou relogio errado, nao uso real
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
  if coalesce(array_length(p_colaboradores, 1), 0) > 100 then
    raise exception 'colaboradores demais num documento so';
  end if;
  if length(p_registro::text) > 400000 then
    raise exception 'documento grande demais';
  end if;
end
$val$;

-- ------------------------------------------------------------------ DTS
create or replace function public.registrar_dts(
  p_registro      jsonb,
  p_colaboradores text[] default '{}',
  p_pdf_path      text   default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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

  -- Idempotência: a mesma tentativa reenviada devolve o que já existe em vez de
  -- criar uma segunda cópia. É o caso comum em obra — a escrita chega e a
  -- resposta se perde.
  if v_cliente_id is not null then
    select id, numero_os, revisao into v_ja from public.dts where cliente_id = v_cliente_id;
    if found then
      return jsonb_build_object('id', v_ja.id, 'numero_os', v_ja.numero_os,
                                'revisao', v_ja.revisao, 'ja_existia', true);
    end if;
  end if;

  -- Trava por OS+dia: sem isto, dois aparelhos reconectando juntos calculam a
  -- mesma revisão. A trava cai sozinha no fim da transação.
  if v_os_base is not null and v_data is not null then
    perform pg_advisory_xact_lock(hashtext('dts:' || v_os_base || ':' || v_data::text));
    select coalesce(max(revisao) + 1, 0) into v_rev
      from public.dts where numero_os_base = v_os_base and data_atividade = v_data;
  end if;

  v_numero_os := coalesce(v_os_base, p_registro->>'numero_os');
  if v_rev > 0 then
    v_numero_os := v_numero_os || ' Rev.' || lpad(v_rev::text, 2, '0');
  end if;

  -- Os campos aceitos são listados um a um DE PROPÓSITO. Esta função é a
  -- fronteira de segurança: nada que não esteja aqui entra na tabela.
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

  -- Mesma transação: uma DTS nunca fica gravada sem a equipe que participou.
  if array_length(p_colaboradores, 1) is not null then
    insert into public.dts_colaborador (dts_id, nome, ordem)
    select v_id, t.nome, t.ord - 1
      from unnest(p_colaboradores) with ordinality as t(nome, ord)
     where nullif(trim(t.nome), '') is not null;
  end if;

  return jsonb_build_object('id', v_id, 'numero_os', v_numero_os,
                            'revisao', v_rev, 'ja_existia', false);
end;
$$;

-- ------------------------------------------------------------------- PT
create or replace function public.registrar_pt(
  p_registro      jsonb,
  p_colaboradores text[] default '{}',
  p_pdf_path      text   default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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

  -- a mesma OS pode ter Altura e Escavação no mesmo dia: o tipo entra na trava
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

  if array_length(p_colaboradores, 1) is not null then
    insert into public.pt_colaborador (pt_id, nome, ordem)
    select v_id, t.nome, t.ord - 1
      from unnest(p_colaboradores) with ordinality as t(nome, ord)
     where nullif(trim(t.nome), '') is not null;
  end if;

  return jsonb_build_object('id', v_id, 'numero_os', v_numero_os,
                            'revisao', v_rev, 'ja_existia', false);
end;
$$;


-- ------------------------------------------------- previsao da revisao
-- O PDF e gerado ANTES do envio, entao precisa saber que numero vai sair. Com o
-- anon sem leitura nas tabelas, esta funcao expoe SO esse inteiro — nenhum dado
-- de documento, nenhum nome. E palpite: quem decide de verdade continua sendo a
-- funcao de registro, sob trava.
create or replace function public.proxima_revisao(
  p_doc     text,          -- dts ou pt
  p_os_base text,
  p_data    date,
  p_tipo    text default null
) returns integer
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare v_rev integer;
begin
  if p_os_base is null or p_data is null then return 0; end if;
  if p_doc = 'pt' then
    select coalesce(max(revisao) + 1, 0) into v_rev from public.pt
     where tipo = p_tipo and numero_os_base = p_os_base and data_atividade = p_data;
  else
    select coalesce(max(revisao) + 1, 0) into v_rev from public.dts
     where numero_os_base = p_os_base and data_atividade = p_data;
  end if;
  return coalesce(v_rev, 0);
end;
$fn$;

grant execute on function public.proxima_revisao(text, text, date, text) to anon, authenticated;

-- ------------------------------------------------- fecha o acesso anônimo
-- A partir daqui a chave publicada no HTML não serve para ler, alterar nem
-- apagar nada. Só para chamar as duas funções acima.
drop policy if exists dts_anon_ler       on public.dts;
drop policy if exists dts_anon_inserir   on public.dts;
drop policy if exists dts_anon_atualizar on public.dts;
drop policy if exists dts_anon_apagar    on public.dts;
drop policy if exists pt_anon_ler        on public.pt;
drop policy if exists pt_anon_inserir    on public.pt;
drop policy if exists pt_anon_atualizar  on public.pt;
drop policy if exists pt_anon_apagar     on public.pt;
drop policy if exists dts_colab_anon_inserir on public.dts_colaborador;
drop policy if exists pt_colab_anon_inserir  on public.pt_colaborador;

revoke all on public.dts             from anon;
revoke all on public.pt              from anon;
revoke all on public.dts_colaborador from anon;
revoke all on public.pt_colaborador  from anon;

-- o único direito que sobra ao anônimo
grant execute on function public.registrar_dts(jsonb, text[], text) to anon;
grant execute on function public.registrar_pt(jsonb, text[], text)  to anon;

-- ------------------------------------------------------ o administrador
-- Qualquer usuário autenticado é administrador neste app: só existe esse papel,
-- e as contas são criadas à mão no painel do Supabase. Se um dia houver mais de
-- um papel, troque o `using (true)` por uma checagem de perfil.
grant usage on schema public to authenticated;
grant select, update on public.dts to authenticated;
grant select, update on public.pt  to authenticated;
grant select on public.dts_colaborador to authenticated;
grant select on public.pt_colaborador  to authenticated;

-- privilégios perigosos que o Supabase concede sozinho (TRUNCATE ignora RLS)
revoke truncate, trigger, references on public.dts             from anon, authenticated;
revoke truncate, trigger, references on public.pt              from anon, authenticated;
revoke truncate, trigger, references on public.dts_colaborador from anon, authenticated;
revoke truncate, trigger, references on public.pt_colaborador  from anon, authenticated;

drop policy if exists dts_admin_tudo on public.dts;
create policy dts_admin_tudo   on public.dts for all to authenticated using (true) with check (true);
drop policy if exists pt_admin_tudo on public.pt;
create policy pt_admin_tudo    on public.pt  for all to authenticated using (true) with check (true);
drop policy if exists dts_colab_admin on public.dts_colaborador;
create policy dts_colab_admin  on public.dts_colaborador for select to authenticated using (true);
drop policy if exists pt_colab_admin on public.pt_colaborador;
create policy pt_colab_admin   on public.pt_colaborador  for select to authenticated using (true);

commit;

-- ----------------------------------------------------------------- STORAGE
-- DECISAO CONSCIENTE (20/08/2026): o QR code para o fiscal fica na tela do
-- operador, que nao tem login. Para gerar link assinado o papel anon precisa de
-- SELECT no bucket — e SELECT permite LISTAR.
--
-- RISCO RESIDUAL ACEITO: quem copiar a chave anon do HTML consegue enumerar e
-- baixar todos os PDFs ja emitidos, que trazem nome, matricula e rubrica.
-- E o principal buraco de LGPD que sobra depois de tudo o mais fechado.
-- Para fechar, seria preciso tirar o QR da tela do operador (ou exigir login
-- dele, o que esbarra no uso sem sinal).
--
-- O que DA para tirar sem custo: o direito de APAGAR. Sem ele, ninguem esvazia
-- o acervo de PDFs com a chave publicada. Em troca, um PDF orfao pode sobrar
-- quando o registro falha depois do upload — desperdicio, nao perda.
drop policy if exists "dts-pdfs anon apagar" on storage.objects;
revoke delete on storage.objects from anon;

-- o admin autenticado tem acesso completo ao bucket
drop policy if exists "dts-pdfs admin ler" on storage.objects;
create policy "dts-pdfs admin ler"    on storage.objects for select to authenticated using (bucket_id = 'dts-pdfs');
drop policy if exists "dts-pdfs admin gravar" on storage.objects;
create policy "dts-pdfs admin gravar" on storage.objects for insert to authenticated with check (bucket_id = 'dts-pdfs');
drop policy if exists "dts-pdfs admin mudar" on storage.objects;
create policy "dts-pdfs admin mudar"  on storage.objects for update to authenticated using (bucket_id = 'dts-pdfs') with check (bucket_id = 'dts-pdfs');
drop policy if exists "dts-pdfs admin apagar" on storage.objects;
create policy "dts-pdfs admin apagar" on storage.objects for delete to authenticated using (bucket_id = 'dts-pdfs');
