# SquadQuest

SquadQuest é um team building multiplayer em formato de missão, para 1 Game Master e até 6 jogadores:

**Lobby → “Quem é?” → sorteio dos times e papéis → missão colaborativa → carta de caos → pitches → votação anônima → reveal → reconhecimento e reflexão final.**

O host é uma das até 25 pessoas totais (1 Game Master + até 24 jogadores), mas fica fora dos times. A voz continua no Meet/Teams/Discord; o navegador sincroniza as etapas, os boards dos times e a condução do Game Master. Não há placar individual nem avaliação de desempenho.

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

1. Crie ou selecione seu projeto Supabase e substitua `replace-your-project-ref` pelo identificador dele em `.env.local`.
2. No SQL Editor, execute em ordem as migrations disponíveis em [`supabase/migrations/`](supabase/migrations/). Elas configuram o schema, as regras de privacidade e as funções usadas pelo app.
3. Em Integrations → Data API → Settings, adicione `squadquest` em Exposed schemas e habilite apenas `squadquest.rooms` e `squadquest.players` em Exposed tables. O cliente consulta explicitamente esse schema.
4. Copie [`.env.example`](.env.example) para `.env.local` e preencha a URL do seu projeto e a chave pública `publishable` em Settings → API Keys. O cliente ainda aceita `NEXT_PUBLIC_SUPABASE_ANON_KEY` legado.
5. A migration 0005 adiciona uma política restritiva às tabelas públicas que já usam RLS e um pre-request do PostgREST: sessões Supabase anônimas acessam somente o schema `squadquest`. As políticas permissivas existentes continuam valendo para usuários autenticados comuns e para clientes que usam o papel `anon` sem uma sessão Auth. Se a Lista de Compras usar sessões Supabase anônimas, elas deixarão de ler/escrever as tabelas `public` e o Realtime delas enquanto essa proteção estiver ativa.
6. Habilite **Anonymous Sign-Ins** em Authentication → Providers. Reinicie o servidor Next.js após alterar variáveis locais.

Com as variáveis presentes, o app usa `signInAnonymously()`, tabelas `squadquest.rooms`/`squadquest.players`, Realtime Postgres Changes e Realtime Presence. Respostas e votos da fase “Quem é?” são acessados exclusivamente por funções verificadas no banco; as tabelas sensíveis não dão acesso direto ao navegador. Nenhuma chave secreta é enviada ao navegador; o cliente usa somente a chave pública `publishable` (ou a chave legada `anon`).

### Milestone 2 — “Quem é?”

- Cada jogador envia três histórias; não há respostas do Game Master.
- São necessários pelo menos dois jogadores (além do Game Master) para iniciar a fase.
- A sala vê apenas a contagem geral, nunca quem ainda falta nem o conteúdo enviado.
- O sorteio escolhe uma história por jogador, uma rodada por jogador; o GM pode encerrar a partir da 3ª rodada revelada (migration 0016). Os palpites são anônimos e não geram pontuação.
- O Game Master controla o sorteio e a revelação. O app não exibe métricas individuais.
- Sem configuração Supabase, o fluxo pode ser testado em várias abas do mesmo navegador. Esse modo de demonstração grava o estado no armazenamento local e **não oferece privacidade real**; não use histórias pessoais nele.
- Para multiplayer protegido entre dispositivos, as migrations 0001–0006 estão aplicadas, `.env.local` está conectado e Anonymous Sign-Ins está habilitado. O modo Supabase permite testes reais entre dispositivos; use dados fictícios durante testes de produto.

### Milestone 3 — Jogo completo

- Requer pelo menos 4 jogadores; o GM escolhe quantos times (2 a 12, ao menos 2 pessoas por time) e o sorteio equilibra os tamanhos com diferença máxima de 1 (migration 0016); o Game Master permanece fora dos times.
- Cada equipe recebe missão própria e cada pessoa um papel comportamental secreto com poder de uso único.
- Na fase **Entender**, os três primeiros minutos aceitam apenas hipóteses; cada integrante registra uma hipótese antes de avançar.
- Na fase **Divergir**, cada pessoa registra ao menos duas ideias e vota em duas ideias de outras pessoas; votação só abre depois dos dois minutos de escrita silenciosa.
- Na fase **Decidir**, o time escolhe entre as duas finalistas; sem decisão após três minutos, o banco desempata entre elas.
- Na fase **Construir**, o time preenche um canvas compartilhado com proposta de valor e storyboard de três passos. O Game Master acompanha apenas estados e contagens agregadas.
- Os três passos do storyboard aceitam um desenho (path SVG com comandos `M`/`L`) salvo no mesmo campo `solution` do time (migration 0008).
- Cada poder secreto tem um momento (migrations 0009 e 0012): o visionário em **Construir**, com a ideia escolhida (vale também em Adaptar, sem tempo de espera), o advogado do diabo em **Decidir** e a voz do cliente em **Construir** depois de escrever a proposta de valor. Cada uso soma 1 minuto ao tempo sugerido da etapa (inclusive à espera do desempate em Decidir), e a missão só conclui quando todos os poderes do time foram usados ou depois que o tempo da etapa mais os bônus estoura.
- Usar um poder abre um desafio de poder (migration 0010): um pop-up bloqueante de 90 segundos em que cada outro integrante do time responde individualmente (uma resposta por rodada, 8–300 caracteres). O detentor do poder escolhe uma das respostas e aprova ou pede uma segunda rodada de 60 segundos, uma única vez. Enquanto o desafio está aberto, quem ainda deve resposta não edita o canvas e o Game Master não avança o time. Se o prazo vence sem resposta, o desafio fica registrado como sem resposta; se vence com resposta, vale como aprovado. A marca do desafio (papel, pergunta, resultado e respostas da rodada final) aparece no canvas do time e, do pitch em diante, para toda a sala. O Game Master vê só papel, rodada, prazo e contagem de respostas. Quem usou o poder fica anônimo para o time e para a sala até o reveal; só o próprio detentor se vê nomeado (migration 0013). As respostas também são anônimas até o reveal: cada pessoa só vê a própria identificada; o detentor escolhe pelo conteúdo (migration 0014).
- O Game Master pode lançar uma única carta de caos para um time ou para todos, sorteada de um baralho de 12 cartas (migration 0012); quando o lançamento vale para vários times, cada um recebe uma carta diferente. O caos não pode ser lançado enquanto um time alvo tem um desafio de poder aberto; o painel do Game Master mostra o motivo e o relógio (migration 0015). O time afetado precisa registrar como adaptou sua solução.
- O sorteio define a ordem dos pitches. Cada jogador vota anonimamente em três categorias; não há placar total ou vencedor único.
- Os papéis só são revelados após a votação. Os votos são somados por categoria, e cada jogador escreve uma mensagem final privada até o fechamento.
- A migration 0007 guarda boards, papéis, votos e reflexões em tabelas sem acesso direto do navegador. As RPCs verificam sala e jogador, filtram o board ao próprio time e só revelam resultados/reflexões nas fases previstas.

#### Baralhos

Os quatro baralhos vivem na migration 0012. No sorteio dos times, cada baralho de missão é embaralhado uma vez e cada time recebe a carta seguinte (time 1 a primeira, time 2 a segunda, e assim por diante), então os times nunca compartilham persona, problema ou restrição.

- **Personas (12):** Astronauta · Avó de 80 anos · Influenciador com medo de câmera · Cachorro · CEO paranoico · Criança de 8 anos · Robô recém-chegado à Terra · Motorista de app que odeia trânsito · Professora de escola pública · Turista que não fala português · Atleta olímpico aposentado · Fantasma que mora num prédio comercial.
- **Problemas (12):** não consegue acordar cedo · gasta dinheiro demais · sempre chega atrasado · tem reuniões demais · não consegue decidir o que comer · esquece aniversários · vive perdendo objetos · não consegue dormir · não sabe dizer não · tem medo de falar em público · perde todos os prazos · nunca faz exercício.
- **Restrições (12):** não pode usar telas · precisa funcionar no espaço · só pode custar R$10 · precisa usar IA · tem que funcionar por WhatsApp · precisa gerar receita no primeiro dia · tem que funcionar sem internet · tem que caber no bolso · precisa funcionar debaixo d’água · não pode usar palavras · tem que ser 100% gratuito · precisa resolver em 30 segundos.
- **Caos (12):** Budget Cut (O produto só pode custar R$5 por usuário.) · Modo offline (A internet deixou de existir. Como a solução continua funcionando?) · Plot twist (A persona agora tem mais de 70 anos.) · Monetização (Um investidor apareceu. Como isso gera receita desde o primeiro dia?) · Concorrente (Um concorrente lançou exatamente a mesma solução.) · Viralizou (Dez mil pessoas começaram a usar hoje. O que quebra primeiro e como vocês seguram?) · Regulação (Uma lei nova proibiu a parte central da solução. O que sobra e como reinventar?) · Pivô de público (O produto agora é para crianças de 6 anos. O que muda?) · Reclamação pública (Um cliente famoso detonou o produto nas redes. Como respondem sem perder a essência?) · Só por voz (A solução não pode ter tela nem texto. Tudo acontece por voz.) · Sem energia (Só funciona com bateria e a bateria dura uma hora por dia.) · Prazo impossível (Precisa lançar amanhã com metade do time. O que corta e o que fica?).

### Supabase CLI no projeto já existente

As migrations 0001–0016 são aplicadas manualmente pelo SQL Editor; por isso, o histórico da CLI pode não registrá-las. Antes de usar `db push`, confira e sincronize o histórico remoto:

```bash
supabase link --project-ref replace-your-project-ref
supabase migration list
supabase migration repair --status applied 0001 0002 0003 0004 0005 0006 0007 0008 0009 0010 0011 0012 0013 0014 0015 0016
supabase migration list
```

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
- O limite é 1 Game Master + até 24 jogadores (migration 0016; até a 0015 eram 6 jogadores).
- Presença usa Realtime Presence no Supabase; o fallback local mantém a presença com heartbeat entre abas.
- O estado compartilhado é a sala, não métricas individuais de performance.
