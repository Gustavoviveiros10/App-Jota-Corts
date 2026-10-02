-- =====================================================================
-- Agenda para barbearias — banco de dados (Supabase / Postgres)
-- Cole este arquivo inteiro no SQL Editor do Supabase e clique em Run.
-- Pode rodar de novo sem perder dados.
-- =====================================================================

-- 1) Tabelas ----------------------------------------------------------

create table if not exists public.barbearias (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid not null references auth.users(id) on delete cascade,
  slug       text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$'),
  nome       text not null check (char_length(nome) between 2 and 80),
  criado_em  timestamptz not null default now()
);

-- Cada registro do painel (cliente, serviço, horário, mensalidade, bloqueio, configuração)
-- é um documento: col = tipo do registro, id = identificador, data = conteúdo.
create table if not exists public.docs (
  barbearia_id  uuid not null references public.barbearias(id) on delete cascade,
  col           text not null check (col in ('clientes','servicos','agendamentos','mensalidades','bloqueios','config')),
  id            text not null check (char_length(id) between 1 and 80),
  data          jsonb not null,
  atualizado_em timestamptz not null default now(),
  primary key (barbearia_id, col, id)
);

create index if not exists docs_por_data on public.docs (barbearia_id, col, ((data->>'data')));

-- 2) Regras de acesso (RLS) ------------------------------------------
-- O barbeiro só enxerga e altera a própria barbearia.
-- O cliente final (sem login) não lê nenhuma tabela: usa só as funções públicas abaixo.

alter table public.barbearias enable row level security;
alter table public.docs enable row level security;

drop policy if exists barbearias_dono_select on public.barbearias;
drop policy if exists barbearias_dono_insert on public.barbearias;
drop policy if exists barbearias_dono_update on public.barbearias;
create policy barbearias_dono_select on public.barbearias for select to authenticated using (owner = auth.uid());
create policy barbearias_dono_insert on public.barbearias for insert to authenticated with check (owner = auth.uid());
create policy barbearias_dono_update on public.barbearias for update to authenticated using (owner = auth.uid()) with check (owner = auth.uid());

drop policy if exists docs_dono on public.docs;
create policy docs_dono on public.docs for all to authenticated
  using (exists (select 1 from public.barbearias b where b.id = docs.barbearia_id and b.owner = auth.uid()))
  with check (exists (select 1 from public.barbearias b where b.id = docs.barbearia_id and b.owner = auth.uid()));

revoke all on public.barbearias from anon;
revoke all on public.docs from anon;
grant select, insert, update on public.barbearias to authenticated;
grant select, insert, update, delete on public.docs to authenticated;

-- 3) Funções auxiliares ----------------------------------------------

create or replace function public.hm_min(t text) returns int
language sql immutable as $$
  select case when t ~ '^\d{1,2}:\d{2}$'
    then split_part(t, ':', 1)::int * 60 + split_part(t, ':', 2)::int end
$$;

create or replace function public.tel_norm(t text) returns text
language sql immutable as $$
  select case when length(d) > 11 and left(d, 2) = '55' then substr(d, 3) else d end
  from (select regexp_replace(coalesce(t, ''), '\D', '', 'g') as d) x
$$;

-- 4) Funções públicas (página de agendamento do cliente) ---------------

-- Nome, horário de atendimento e tabela de serviços da barbearia.
create or replace function public.agenda_info(p_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'nome', b.nome,
    'config', coalesce((
      select jsonb_build_object(
        'abre', coalesce(d.data->>'abre', '09:00'),
        'fecha', coalesce(d.data->>'fecha', '19:00'),
        'almocoIni', coalesce(d.data->>'almocoIni', ''),
        'almocoFim', coalesce(d.data->>'almocoFim', ''),
        'folgas', coalesce(d.data->'folgas', '[]'::jsonb))
      from docs d where d.barbearia_id = b.id and d.col = 'config' and d.id = 'geral'),
      jsonb_build_object('abre', '09:00', 'fecha', '19:00', 'almocoIni', '', 'almocoFim', '', 'folgas', '[]'::jsonb)),
    'servicos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', d.id, 'nome', d.data->>'nome',
        'preco', coalesce((d.data->>'preco')::numeric, 0),
        'duracao', coalesce((d.data->>'duracao')::int, 30)) order by d.data->>'nome')
      from docs d where d.barbearia_id = b.id and d.col = 'servicos'), '[]'::jsonb),
    'hoje', to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD'),
    'agora', to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI'))
  from barbearias b where b.slug = lower(p_slug)
$$;

-- Períodos ocupados (horários marcados e bloqueios), sem nenhum dado de cliente.
create or replace function public.agenda_ocupados(p_slug text, p_de date, p_ate date) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('data', x.data, 'ini', x.ini, 'fim', x.fim)), '[]'::jsonb)
  from (
    select d.data->>'data' as data,
           hm_min(d.data->>'hora') as ini,
           hm_min(d.data->>'hora') + coalesce((d.data->>'duracao')::int, 30) as fim
    from docs d join barbearias b on b.id = d.barbearia_id
    where b.slug = lower(p_slug) and d.col = 'agendamentos'
      and coalesce(d.data->>'status', '') <> 'faltou'
      and d.data->>'data' between p_de::text and least(p_ate, p_de + 62)::text
    union all
    select d.data->>'data',
           case when coalesce((d.data->>'diaTodo')::boolean, false) then 0 else hm_min(d.data->>'inicio') end,
           case when coalesce((d.data->>'diaTodo')::boolean, false) then 1440 else hm_min(d.data->>'fim') end
    from docs d join barbearias b on b.id = d.barbearia_id
    where b.slug = lower(p_slug) and d.col = 'bloqueios'
      and d.data->>'data' between p_de::text and least(p_ate, p_de + 62)::text
  ) x
  where x.ini is not null and x.fim is not null
$$;

-- Marca o horário. Confere tudo de novo no servidor para ninguém marcar em cima de outro.
create or replace function public.agenda_marcar(
  p_slug text, p_servico text, p_data date, p_hora text, p_nome text, p_telefone text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  b        barbearias;
  s        jsonb;
  cfg      jsonb;
  cli      jsonb;
  cid      text;
  aid      text;
  tel      text := tel_norm(p_telefone);
  nome     text := btrim(regexp_replace(coalesce(p_nome, ''), '\s+', ' ', 'g'));
  agora    timestamp := now() at time zone 'America/Sao_Paulo';
  ini      int := hm_min(p_hora);
  fim      int;
  dur      int;
  valor    numeric;
begin
  select * into b from barbearias where slug = lower(p_slug);
  if not found then raise exception 'Barbearia não encontrada.'; end if;
  if char_length(nome) < 2 or char_length(nome) > 80 then raise exception 'Informe seu nome.'; end if;
  if length(tel) < 10 or length(tel) > 11 then raise exception 'Informe um WhatsApp com DDD.'; end if;
  if ini is null or ini >= 1440 then raise exception 'Horário inválido.'; end if;

  select d.data into s from docs d where d.barbearia_id = b.id and d.col = 'servicos' and d.id = p_servico;
  if not found then raise exception 'Serviço não encontrado.'; end if;
  select d.data into cfg from docs d where d.barbearia_id = b.id and d.col = 'config' and d.id = 'geral';
  cfg := coalesce(cfg, '{}'::jsonb);

  dur := coalesce((s->>'duracao')::int, 30);
  fim := ini + dur;

  if p_data < agora::date or (p_data = agora::date and ini <= extract(hour from agora) * 60 + extract(minute from agora)) then
    raise exception 'Esse horário já passou.';
  end if;
  if p_data > agora::date + 60 then raise exception 'Data muito distante.'; end if;
  if ini < hm_min(coalesce(nullif(cfg->>'abre', ''), '09:00')) or fim > hm_min(coalesce(nullif(cfg->>'fecha', ''), '19:00')) then
    raise exception 'Fora do horário de atendimento.';
  end if;
  if coalesce(cfg->'folgas', '[]'::jsonb) @> to_jsonb(extract(dow from p_data)::int) then
    raise exception 'A barbearia não atende nesse dia.';
  end if;
  if coalesce(cfg->>'almocoIni', '') <> '' and coalesce(cfg->>'almocoFim', '') <> ''
     and ini < hm_min(cfg->>'almocoFim') and fim > hm_min(cfg->>'almocoIni') then
    raise exception 'Esse horário não está disponível.';
  end if;

  -- trava por barbearia + dia: dois clientes não gravam o mesmo horário ao mesmo tempo
  perform pg_advisory_xact_lock(hashtext(b.id::text || p_data::text));

  if exists (
    select 1 from docs d where d.barbearia_id = b.id and d.col = 'agendamentos'
      and d.data->>'data' = p_data::text and coalesce(d.data->>'status', '') <> 'faltou'
      and hm_min(d.data->>'hora') < fim
      and hm_min(d.data->>'hora') + coalesce((d.data->>'duracao')::int, 30) > ini
  ) then raise exception 'Esse horário acabou de ser ocupado. Escolha outro.'; end if;

  if exists (
    select 1 from docs d where d.barbearia_id = b.id and d.col = 'bloqueios'
      and d.data->>'data' = p_data::text
      and (coalesce((d.data->>'diaTodo')::boolean, false)
           or (hm_min(d.data->>'inicio') < fim and hm_min(d.data->>'fim') > ini))
  ) then raise exception 'Esse horário não está disponível.'; end if;

  -- cliente: reaproveita a ficha pelo telefone ou cria uma nova
  select d.id, d.data into cid, cli from docs d
   where d.barbearia_id = b.id and d.col = 'clientes' and tel_norm(d.data->>'telefone') = tel
   order by d.atualizado_em limit 1;

  if cid is not null and (
    select count(*) from docs d where d.barbearia_id = b.id and d.col = 'agendamentos'
      and d.data->>'clienteId' = cid and d.data->>'status' = 'agendado'
      and d.data->>'data' >= agora::date::text
  ) >= 3 then
    raise exception 'Você já tem 3 horários marcados. Fale com a barbearia para marcar mais.';
  end if;

  if cid is null then
    cid := 'c' || replace(gen_random_uuid()::text, '-', '');
    cli := jsonb_build_object('nome', nome, 'telefone', p_telefone, 'obs', '',
                              'criadoEm', agora::date::text, 'origem', 'link');
    insert into docs (barbearia_id, col, id, data) values (b.id, 'clientes', cid, cli);
  end if;

  valor := case when coalesce((cli->>'mensalista')::boolean, false) then 0
                else coalesce((s->>'preco')::numeric, 0) end;

  aid := 'a' || replace(gen_random_uuid()::text, '-', '');
  insert into docs (barbearia_id, col, id, data) values (b.id, 'agendamentos', aid, jsonb_build_object(
    'data', p_data::text, 'hora', lpad(split_part(p_hora, ':', 1), 2, '0') || ':' || split_part(p_hora, ':', 2),
    'clienteId', cid, 'clienteNome', coalesce(cli->>'nome', nome),
    'servicoId', p_servico, 'servicoNome', s->>'nome',
    'duracao', dur, 'valor', valor, 'status', 'agendado', 'pagamento', '', 'origem', 'link'));

  return jsonb_build_object('ok', true, 'id', aid);
end
$$;

revoke all on function public.agenda_info(text) from public;
revoke all on function public.agenda_ocupados(text, date, date) from public;
revoke all on function public.agenda_marcar(text, text, date, text, text, text) from public;
grant execute on function public.agenda_info(text) to anon, authenticated;
grant execute on function public.agenda_ocupados(text, date, date) to anon, authenticated;
grant execute on function public.agenda_marcar(text, text, date, text, text, text) to anon, authenticated;

-- 5) Atualização em tempo real no painel -------------------------------
-- (quando um cliente marca pelo link, o horário aparece no painel sem recarregar)
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'docs') then
    alter publication supabase_realtime add table public.docs;
  end if;
end $$;
