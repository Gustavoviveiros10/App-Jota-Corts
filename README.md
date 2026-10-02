# Agenda da barbearia — Jota Corts

Painel do barbeiro (agenda, clientes, mensalistas, faturamento, bloqueios) e página pública para o cliente marcar horário pelo link.

| Arquivo | O que é |
|---|---|
| `index.html` | Painel do barbeiro (com login) |
| `agendar.html` | Página pública de agendamento (`agendar.html?b=jota-corts`) |
| `config.js` | Endereço e chave pública do Supabase |
| `supabase/schema.sql` | Script do banco: tabelas, regras de acesso e funções de agendamento |

## Colocar no ar

1. **Banco:** no Supabase, abra **SQL Editor**, cole todo o conteúdo de `supabase/schema.sql` e clique em **Run**.
2. **Login do barbeiro:** em **Authentication > Users > Add user > Create new user**, informe e-mail e senha e marque **Auto Confirm User**.
3. **Site:** no GitHub, em **Settings > Pages**, escolha **Deploy from a branch**, branch `main`, pasta `/ (root)` e salve.
4. **Primeiro acesso:** abra `https://SEU-USUARIO.github.io/jota-corts-agenda/`, entre com o e-mail e a senha e confirme o nome e o link da barbearia.
5. **Ajustes:** cadastre serviços, horário de atendimento, almoço e folgas. O link de agendamento aparece na aba Ajustes.

## Nova barbearia

Cada barbearia é um login. Crie um novo usuário no Supabase (passo 2); no primeiro acesso ele escolhe o nome e o link próprio. Os dados de uma barbearia não aparecem para outra.

## Segurança

- A chave em `config.js` é a **publishable**, feita para ficar no navegador.
- Nunca coloque no repositório a chave **secret** nem a senha do banco.
- O cliente final não lê nenhuma tabela: só consulta horários ocupados (sem nomes) e grava o próprio horário por funções do banco.
