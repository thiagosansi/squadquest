# SquadQuest

SquadQuest é um team building multiplayer em formato de missão, para 1 Game Master e até 6 jogadores:

**Lobby → “Quem é?” → sorteio dos times e papéis → missão colaborativa → carta de caos → pitches → votação anônima → reveal → reconhecimento e reflexão final.**

O host é uma das 7 pessoas totais, mas fica fora dos times. A voz continua no Meet/Teams/Discord; o navegador sincroniza as etapas, os boards dos times e a condução do Game Master. Não há placar individual nem avaliação de desempenho.

## Rodar localmente

Requisitos: Node.js 20+.

```bash
npm install
npm run dev
```

Abra http://localhost:3000. Se `.env.local` não existir, a aplicação entra automaticamente em **Modo demo local**. Crie uma partida e abra o mesmo endereço em outra aba para testar a entrada de jogadores e a sincronização do lobby. O transporte local usa `BroadcastChannel`, `localStorage` e heartbeat de presença; ele é apenas um fallback de desenvolvimento.

Para validar antes de publicar:

```bash
npm run typecheck
npm run lint
npm run build
```

## Conectar Supabase

1. O projeto escolhido é `vayfcbkwxteecvqemjks` (`https://vayfcbkwxteecvqemjks.supabase.co`).
2. No SQL Editor, execute as migrations em ordem: [`0001_squadquest_milestone_1.sql`](supabase/migrations/0001_squadquest_milestone_1.sql), [`0002_isolate_squadquest_schema.sql`](supabase/migrations/0002_isolate_squadquest_schema.sql), [`0003_least_privilege_squadquest.sql`](supabase/migrations/0003_least_privilege_squadquest.sql), [`0004_who_is_identity_game.sql`](supabase/migrations/0004_who_is_identity_game.sql), [`0005_isolate_anonymous_sessions_from_public.sql`](supabase/migrations/0005_isolate_anonymous_sessions_from_public.sql), [`0006_allow_players_to_read_their_own_row.sql`](supabase/migrations/0006_allow_players_to_read_their_own_row.sql), [`0007_squadquest_full_game.sql`](supabase/migrations/0007_squadquest_full_game.sql), [`0008_canvas_sketches.sql`](supabase/migrations/0008_canvas_sketches.sql), [`0009_power_moments.sql`](supabase/migrations/0009_power_moments.sql), [`0010_power_challenges.sql`](supabase/migrations/0010_power_challenges.sql) e [`0011_chosen_reply.sql`](supabase/migrations/0011_chosen_reply.sql). As migrations 0001–0007 foram aplicadas ao projeto `vayfcbkwxteecvqemjks` pelo SQL Editor em 2026-09-22 e as 0008, 0009 e 0010 em 2026-09-23. A migration 0008 recria `update_squadquest_solution` para guardar, no mesmo campo `solution`, um desenho (path SVG só com `M`, `L`, dígitos e espaços, até 60000 caracteres) para cada um dos três passos do storyboard; valores inválidos viram string vazia sem falhar o salvamento. A migration 0009 foi aplicada ao projeto `vayfcbkwxteecvqemjks` pelo SQL Editor em 2026-09-23: ela recria `use_squadquest_role_power`, `advance_squadquest_mission` e `get_squadquest_game_state` para que cada poder secreto só valha na sua etapa, cada uso some 1 minuto ao tempo sugerido da etapa e a missão só conclua com todos os poderes usados ou após o tempo estourar. A migration 0010 foi aplicada ao projeto `vayfcbkwxteecvqemjks` pelo SQL Editor em 2026-09-23: ela cria `gameplay_power_challenges` e `gameplay_power_replies` e faz cada uso de poder abrir um desafio de 90 segundos que os demais integrantes respondem individualmente, que o detentor aprova ou estende por mais 60 segundos, que bloqueia o canvas de quem ainda deve resposta e o avanço do time enquanto está aberto, e cujo resultado (aprovado ou sem resposta) aparece em `get_squadquest_game_state`. A migration 0011 ainda **não** foi aplicada ao projeto `vayfcbkwxteecvqemjks`: ela adiciona `chosen_reply_id` em `gameplay_power_challenges`, recria `resolve_squadquest_power_challenge` com um quarto parâmetro `chosen_reply_id` (a assinatura antiga de três parâmetros é removida) para que aprovar exija escolher uma resposta da rodada atual do próprio desafio, e faz `get_squadquest_game_state` expor o `id` de cada resposta do desafio aberto e a `chosen_reply` (`{name, content}`, ou `null` quando o desafio venceu pelo tempo ou ficou sem resposta) em `power_outcomes`.
3. Em Integrations → Data API → Settings, adicione `squadquest` em Exposed schemas e habilite apenas `squadquest.rooms` e `squadquest.players` em Exposed tables. Isso já foi configurado no projeto `vayfcbkwxteecvqemjks`. O cliente do app consulta explicitamente esse schema.
4. `.env.local` está configurado neste workspace com a chave pública `publishable` em Settings → API Keys. Para outra máquina, copie [`.env.example`](.env.example) para `.env.local` e preencha a chave pública. O cliente ainda aceita `NEXT_PUBLIC_SUPABASE_ANON_KEY` legado.
5. A migration 0005 adiciona uma política restritiva às tabelas públicas que já usam RLS e um pre-request do PostgREST: sessões Supabase anônimas acessam somente o schema `squadquest`. As políticas permissivas existentes continuam valendo para usuários autenticados comuns e para clientes que usam o papel `anon` sem uma sessão Auth. Se a Lista de Compras usar sessões Supabase anônimas, elas deixarão de ler/escrever as tabelas `public` e o Realtime delas enquanto essa proteção estiver ativa.
6. **Anonymous Sign-Ins está habilitado** em Authentication → Providers no projeto `vayfcbkwxteecvqemjks`. Reinicie o servidor Next.js após alterar variáveis locais.

Com as variáveis presentes, o app usa `signInAnonymously()`, tabelas `squadquest.rooms`/`squadquest.players`, Realtime Postgres Changes e Realtime Presence. Respostas e votos da fase “Quem é?” são acessados exclusivamente por funções verificadas no banco; as tabelas sensíveis não dão acesso direto ao navegador. Nenhuma chave secreta é enviada ao navegador; o cliente usa somente a chave pública `publishable` (ou a chave legada `anon`).

### Milestone 2 — “Quem é?”

- Cada jogador envia três histórias; não há respostas do Game Master.
- São necessários pelo menos dois jogadores (além do Game Master) para iniciar a fase.
- A sala vê apenas a contagem geral, nunca quem ainda falta nem o conteúdo enviado.
- O sorteio escolhe até três histórias de pessoas diferentes; os palpites são anônimos e não geram pontuação.
- O Game Master controla o sorteio e a revelação. O app não exibe métricas individuais.
- Sem configuração Supabase, o fluxo pode ser testado em várias abas do mesmo navegador. Esse modo de demonstração grava o estado no armazenamento local e **não oferece privacidade real**; não use histórias pessoais nele.
- Para multiplayer protegido entre dispositivos, as migrations 0001–0006 estão aplicadas, `.env.local` está conectado e Anonymous Sign-Ins está habilitado. O modo Supabase permite testes reais entre dispositivos; use dados fictícios durante testes de produto.

### Milestone 3 — Jogo completo

- Requer pelo menos 4 jogadores para sortear dois times equilibrados; o Game Master permanece fora dos times.
- Cada equipe recebe missão própria e cada pessoa um papel comportamental secreto com poder de uso único.
- Na fase **Entender**, os três primeiros minutos aceitam apenas hipóteses; cada integrante registra uma hipótese antes de avançar.
- Na fase **Divergir**, cada pessoa registra ao menos duas ideias e vota em duas ideias de outras pessoas; votação só abre depois dos dois minutos de escrita silenciosa.
- Na fase **Decidir**, o time escolhe entre as duas finalistas; sem decisão após três minutos, o banco desempata entre elas.
- Na fase **Construir**, o time preenche um canvas compartilhado com proposta de valor e storyboard de três passos. O Game Master acompanha apenas estados e contagens agregadas.
- Os três passos do storyboard aceitam um desenho (path SVG com comandos `M`/`L`) salvo no mesmo campo `solution` do time (migration 0008).
- Cada poder secreto tem um momento (migration 0009): o visionário em **Divergir** após os dois minutos de escrita silenciosa, o advogado do diabo em **Decidir** e a voz do cliente em **Construir** depois de escrever a proposta de valor. Cada uso soma 1 minuto ao tempo sugerido da etapa (inclusive à espera do desempate em Decidir), e a missão só conclui quando todos os poderes do time foram usados ou depois que o tempo da etapa mais os bônus estoura.
- Usar um poder abre um desafio de poder (migration 0010): um pop-up bloqueante de 90 segundos em que cada outro integrante do time responde individualmente (uma resposta por rodada, 8–300 caracteres). O detentor do poder escolhe uma das respostas e aprova ou pede uma segunda rodada de 60 segundos, uma única vez. Enquanto o desafio está aberto, quem ainda deve resposta não edita o canvas e o Game Master não avança o time. Se o prazo vence sem resposta, o desafio fica registrado como sem resposta; se vence com resposta, vale como aprovado. A marca do desafio (papel, pergunta, resultado e respostas da rodada final) aparece no canvas do time e, do pitch em diante, para toda a sala. O Game Master vê só papel, rodada, prazo e contagem de respostas.
- O Game Master pode lançar uma única carta de caos para um time ou para ambos. O time afetado precisa registrar como adaptou sua solução.
- O sorteio define a ordem dos pitches. Cada jogador vota anonimamente em três categorias; não há placar total ou vencedor único.
- Os papéis só são revelados após a votação. Os votos são somados por categoria, e cada jogador escreve uma mensagem final privada até o fechamento.
- A migration 0007 guarda boards, papéis, votos e reflexões em tabelas sem acesso direto do navegador. As RPCs verificam sala e jogador, filtram o board ao próprio time e só revelam resultados/reflexões nas fases previstas.

### Supabase CLI no projeto já existente

As migrations 0001–0010 são aplicadas manualmente pelo SQL Editor (a 0011 ainda não foi aplicada); por isso, o histórico da CLI pode não registrá-las. Antes de usar `db push`, confira e sincronize o histórico remoto:

```bash
supabase link --project-ref vayfcbkwxteecvqemjks
supabase migration list
supabase migration repair --status applied 0001 0002 0003 0004 0005 0006 0007 0008 0009 0010
supabase migration list
```

Depois de aplicar a 0011 pelo SQL Editor, acrescente `0011` ao `migration repair` acima.



As migrations aplicadas pelo SQL Editor não são registradas automaticamente no histórico usado pela CLI. Se for usar a CLI neste projeto, confirme que está linkado ao projeto correto e registre as versões aplicadas com `migration repair`; confira o resultado com `migration list`. Mudanças futuras devem ser feitas em novos arquivos de migration e enviadas com `supabase db push`.

## Deploy na Vercel

1. Importe este repositório na Vercel.
2. Mantenha o framework como Next.js e o build padrão `next build`.
3. Cadastre `NEXT_PUBLIC_SUPABASE_URL` e `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` em Environment Variables para Production, Preview e Development.
4. Faça o deploy e adicione o domínio da Vercel em Authentication → URL Configuration se for usar links com autenticação no futuro.
5. Antes de divulgar o app publicamente, configure CAPTCHA em Authentication → Attack Protection para reduzir abuso de criação de sessões anônimas e crescimento indevido de MAU.

## Estrutura principal

- `app/` — shell Next.js, metadata e estilos globais.
- `components/SquadQuestApp.tsx` — lobby, fase “Quem é?” e fluxo compartilhado.
- `components/QuestStages.tsx` — times, missão, Game Master, pitch, votos, resultados e fechamento.
- `lib/gameplay.ts` — papéis secretos, cartas de missão, durações e categorias finais.
- `lib/types.ts` — tipos, perguntas, avatares e limite de 6 jogadores.
- `lib/supabase.ts` — cliente browser com configuração opcional.
- `supabase/migrations/` — schema, RLS, regras de privacidade e funções seguras das fases.

## Decisões de produto do Milestone 1

- Sem cadastro, senha ou login social; a sessão é anônima.
- O host controla a transição de fase e não entra em times.
- O limite é 1 Game Master + 6 jogadores.
- Presença usa Realtime Presence no Supabase; o fallback local mantém a presença com heartbeat entre abas.
- O estado compartilhado é a sala, não métricas individuais de performance.
