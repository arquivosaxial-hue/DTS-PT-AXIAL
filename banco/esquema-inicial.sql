-- ============================================================================
-- Construtora Axial — esquema inicial do Supabase
-- Rode UMA vez, num projeto Supabase novo e vazio, ANTES de publicar o app.
--
-- Este script já nasce com tudo que foi aprendido na auditoria do app do Grupo
-- Solution. Não repita aqui os erros que lá tiveram de ser corrigidos depois:
--   * cliente_id com índice único       -> reenvio não duplica documento
--   * revisao com índice único          -> dois aparelhos não geram o mesmo "Rev.01"
--   * anon SEM leitura nos _colaborador -> nome de trabalhador não é legível
--   * bucket PRIVADO desde o início     -> nenhuma URL pública jamais existe
-- ============================================================================

begin;

-- ------------------------------------------------------------------- DTS
create table if not exists public.dts (
  id                  uuid primary key default gen_random_uuid(),
  created_at          timestamptz not null default now(),
  cliente_id          text,                  -- gerado no aparelho, uma vez por documento
  numero_os           text,                  -- versão efetiva, com sufixo Rev.NN
  numero_os_base      text,                  -- a OS original, sem sufixo
  revisao             integer,               -- 0 = original; 1 = Rev.01; ...
  data_atividade      date,
  horario_emissao     time,
  unidade             text,
  empresa             text,
  tipo_equipe         text,
  elaborador          text,
  lider_frente        text,
  area_setor          text,
  atividade           text,
  localizacao         text,
  atividades_criticas jsonb not null default '[]'::jsonb,
  -- os três níveis de barreira vivem aqui dentro, por risco:
  -- { passo, nome, nivel, controle, protecao, suporte, alerta_sem_controle }
  riscos              jsonb not null default '[]'::jsonb,
  epis                jsonb not null default '[]'::jsonb,
  barreiras_controle  jsonb not null default '[]'::jsonb,
  barreiras_protecao  jsonb not null default '[]'::jsonb,
  barreiras_suporte   jsonb not null default '[]'::jsonb,
  outros              jsonb not null default '{}'::jsonb,
  aprovador_pt        text,
  pdf_path            text,
  status              text not null default 'finalizada',
  excluido_em         timestamptz,           -- soft delete: preserva rastreabilidade
  excluido_por        text
);

create table if not exists public.dts_colaborador (
  id         uuid primary key default gen_random_uuid(),
  dts_id     uuid not null references public.dts(id) on delete cascade,
  nome       text not null,
  ordem      integer not null default 0,
  created_at timestamptz not null default now()
);

-- -------------------------------------------------------------------- PT
create table if not exists public.pt (
  id                 uuid primary key default gen_random_uuid(),
  created_at         timestamptz not null default now(),
  cliente_id         text,
  tipo               text not null,          -- quente | eletricidade | altura | ...
  numero_os          text,
  numero_os_base     text,
  revisao            integer,
  data_atividade     date,
  horario_emissao    time,
  turno              text,
  unidade            text,
  empresa            text,
  tipo_equipe        text,
  setor              text,
  local_trabalho     text,
  lider_atividade    text,
  descricao_trabalho text,
  avaliacao          jsonb not null default '[]'::jsonb,
  atividade_segura   text,
  ciente             boolean not null default false,
  especificos        jsonb not null default '{}'::jsonb,
  emissor_nome       text,
  emissor_area       text,
  verificador_nome   text,
  verificador_area   text,
  pdf_path           text,
  status             text not null default 'finalizada',
  excluido_em        timestamptz,
  excluido_por       text
);

create table if not exists public.pt_colaborador (
  id         uuid primary key default gen_random_uuid(),
  pt_id      uuid not null references public.pt(id) on delete cascade,
  nome       text not null,
  ordem      integer not null default 0,
  created_at timestamptz not null default now()
);

-- --------------------------------------------------- idempotência e revisão
-- Sem isto, uma escrita que chega ao servidor com a resposta perdida vira
-- documento duplicado na retentativa da fila. Índice parcial porque cliente_id
-- é nulo em qualquer linha criada fora do app.
create unique index if not exists dts_cliente_id_uk
  on public.dts(cliente_id) where cliente_id is not null;
create unique index if not exists pt_cliente_id_uk
  on public.pt(cliente_id)  where cliente_id is not null;

-- Quem decide o número da revisão é o BANCO, não o cliente: o app propõe e,
-- se for recusado, incrementa e tenta de novo.
create unique index if not exists dts_os_dia_rev_uk
  on public.dts(numero_os_base, data_atividade, revisao)
  where numero_os_base is not null and data_atividade is not null and revisao is not null;

-- na PT entra o tipo: a mesma OS pode ter Altura e Escavação no mesmo dia
create unique index if not exists pt_os_dia_rev_uk
  on public.pt(tipo, numero_os_base, data_atividade, revisao)
  where numero_os_base is not null and data_atividade is not null and revisao is not null;

-- consultas do painel administrativo, que sempre filtram por período
create index if not exists dts_data_idx on public.dts(data_atividade desc);
create index if not exists pt_data_idx  on public.pt(data_atividade desc);

-- --------------------------------------------------------------------- RLS
-- O app roda inteiro como 'anon': o encarregado de frente emite documento sem
-- login, de propósito — ele trabalha em campo, sem sinal, e token de sessão
-- expira. Então as permissões são o mínimo que o app precisa, nada além.
alter table public.dts             enable row level security;
alter table public.dts_colaborador enable row level security;
alter table public.pt              enable row level security;
alter table public.pt_colaborador  enable row level security;

-- dts e pt: o app lê (insert().select() e painel), insere, atualiza (soft delete,
-- anexar PDF, restaurar da lixeira) e apaga (desfazer documento órfão).
create policy dts_anon_ler       on public.dts for select to anon using (true);
create policy dts_anon_inserir   on public.dts for insert to anon with check (true);
create policy dts_anon_atualizar on public.dts for update to anon using (true) with check (true);
create policy dts_anon_apagar    on public.dts for delete to anon using (true);

create policy pt_anon_ler        on public.pt for select to anon using (true);
create policy pt_anon_inserir    on public.pt for insert to anon with check (true);
create policy pt_anon_atualizar  on public.pt for update to anon using (true) with check (true);
create policy pt_anon_apagar     on public.pt for delete to anon using (true);

-- Colaboradores: SOMENTE inserção. Nenhuma tela lê estas tabelas, e é aqui que
-- estão os nomes dos trabalhadores. Sem policy de select, ninguém com a URL do
-- app consegue listá-los. O insert é `.insert(rows)` puro, sem .select(),
-- então não precisa de permissão de leitura para funcionar.
create policy dts_colab_anon_inserir on public.dts_colaborador for insert to anon with check (true);
create policy pt_colab_anon_inserir  on public.pt_colaborador  for insert to anon with check (true);


-- ------------------------------------------------------------------ GRANTS
-- O projeto foi criado com "Automatically expose new tables" DESLIGADO, que e a
-- postura recomendada: nenhuma tabela nova fica exposta na API por acidente.
-- Em troca, o privilegio de cada tabela precisa ser dado aqui, na mao.
--
-- Isto NAO substitui o RLS, e o RLS nao substitui isto: o Postgres so consulta a
-- policy depois de confirmar que o papel tem privilegio na tabela. Faltando o
-- grant, o app recebe "permission denied" mesmo com a policy correta.
grant usage on schema public to anon;

grant select, insert, update, delete on public.dts to anon;
grant select, insert, update, delete on public.pt  to anon;

-- colaboradores: SOMENTE inserir. E onde estao os nomes dos trabalhadores, e
-- nenhuma tela le estas tabelas.
grant insert on public.dts_colaborador to anon;
grant insert on public.pt_colaborador  to anon;


-- O Supabase concede TRUNCATE, TRIGGER e REFERENCES por padrao ao papel anon.
-- Nenhum dos tres e usado pelo app, e o primeiro e perigoso:
--   TRUNCATE NAO passa por RLS. Com esse privilegio, a chave anon (que e publica
--   por natureza) esvazia a tabela inteira de uma vez e nenhuma policy impede.
-- Por isso o revoke vem logo depois do grant, e nao antes: privilegio padrao novo
-- pode ser reaplicado pelo Supabase ao criar tabela, entao rode isto de novo se
-- algum dia acrescentar tabela ao esquema.
revoke truncate, trigger, references on public.dts             from anon;
revoke truncate, trigger, references on public.pt              from anon;
revoke truncate, trigger, references on public.dts_colaborador from anon;
revoke truncate, trigger, references on public.pt_colaborador  from anon;

commit;

-- ----------------------------------------------------------------- STORAGE
-- Bucket PRIVADO: os PDFs trazem nome, matrícula, função e rubrica de cada
-- trabalhador. O acesso é sempre por link assinado e temporário.
insert into storage.buckets (id, name, public)
values ('dts-pdfs', 'dts-pdfs', false)
on conflict (id) do nothing;

-- O select existe porque createSignedUrl exige permissão de leitura; a proteção
-- vem de o bucket ser fechado — sem o token, a URL não serve para nada.
-- O update existe porque o upload do PDF usa upsert:true.
create policy "dts-pdfs anon inserir"   on storage.objects for insert to anon with check (bucket_id = 'dts-pdfs');
create policy "dts-pdfs anon ler"       on storage.objects for select to anon using      (bucket_id = 'dts-pdfs');
create policy "dts-pdfs anon atualizar" on storage.objects for update to anon using      (bucket_id = 'dts-pdfs') with check (bucket_id = 'dts-pdfs');
create policy "dts-pdfs anon apagar"    on storage.objects for delete to anon using      (bucket_id = 'dts-pdfs');
