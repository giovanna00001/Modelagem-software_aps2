# APS 2 — Dossiê de Arquitetura Viva: Gestão de Estágios UniSenai

**Funcionalidade crítica:** Algoritmo de Conciliação (Match) de Competências e Assinatura de Contrato (TCE)
**Autor(a):** Nome Sobrenome — *(substitua pelo seu nome)*
**Entidade de domínio principal:** `TermoEstagio`

## 1. Explicação da funcionalidade

O coordenador de estágios seleciona uma vaga publicada por uma empresa concedente e dispara a **conciliação**. O sistema:

1. Cria um `TermoEstagio` (estado `EM_CONCILIACAO`) e carrega a vaga e as **candidaturas** registradas pelos alunos.
2. Consulta o Sistema Acadêmico para filtrar alunos **elegíveis** (matrícula ativa, período mínimo, sem estágio vigente).
3. Para cada candidato elegível, o **MatchEngine** (gRPC) calcula o score de afinidade:
   `score = 0,60 × cobertura(competências obrigatórias) + 0,25 × cobertura(desejáveis, ponderada por nível) + 0,15 × aderência(curso/período)`.
4. Se `melhorScore >= 0,70` o termo vai a `MATCH_SUGERIDO`; caso contrário, a `SEM_MATCH`.
5. Aluno e empresa decidem **em paralelo** (Fork/Join). Com os dois aceites, o termo passa a `EM_ASSINATURA` e a minuta é enviada ao Provedor de Assinatura.
6. Aluno, empresa e coordenação assinam **em paralelo**. Com `totalAssinaturas == 3`, o termo fica `VIGENTE` e o evento `TermoVigenteEvent` é publicado.

**Proteção contra estados inválidos:** transições só ocorrem pelo método de domínio do `TermoEstagio`, que valida o estado de origem e a guarda; há *optimistic locking* (coluna `versao`) e webhooks idempotentes (`envelopeId + signatarioId`).

## 1.1 Modelo de domínio (base da equipe)

A funcionalidade usa as classes do diagrama de classes inicial da equipe e acrescenta `TermoEstagio`, que nasce de uma `Candidatura` selecionada. A conciliação compara `Vaga.competenciasExigidas` com `Aluno.competencias`; ao sugerir o match, a `Candidatura.situacao` passa a `SELECIONADA`.

```mermaid
classDiagram
    class Usuario { +Int id +String nome +String email +String senha }
    class Aluno { +String curso +String telefone }
    class RecrutadorEmpresa { +String cargo }
    class Empresa { +Int id +String cnpj +String razaoSocial }
    class Vaga { +Int id +String titulo +String descricao +Bool aberta +Modalidade tipo }
    class Candidatura { +Int id +Date dataEnvio +String situacao }
    class Competencia { +Int id +String nome }
    class TermoEstagio { +Int id +Estado estado +Int versao +Int tentativas }
    class Modalidade { <<enumeration>> ESTAGIO APRENDIZAGEM }
    Usuario <|-- Aluno
    Usuario <|-- RecrutadorEmpresa
    RecrutadorEmpresa "1..N" --> "0..1" Empresa : representa
    Empresa "1" --> "0..N" Vaga : publica
    Aluno "1" --> "0..N" Candidatura : realiza
    Vaga "1" --> "0..N" Candidatura : recebe
    Vaga "0..N" --> "0..N" Competencia : exige
    Aluno "0..N" --> "0..N" Competencia : possui
    Candidatura "1" --> "0..1" TermoEstagio : origina
    Vaga --> Modalidade
```

## 2. Artefato 1 — Diagrama de Sequência

Arquivo: [`docs/diagrams/sequencia.mmd`](docs/diagrams/sequencia.mmd). Chamadas síncronas usam `->>`, assíncronas/mensageria usam `-)`, e os retornos com DTOs usam `-->>`.

```mermaid
sequenceDiagram
    autonumber
    actor Coord as Coordenador UniSenai
    participant Web as PortalWeb (React SPA)
    participant Ctrl as ConciliacaoController
    participant CS as ConciliacaoService
    participant Repo as EstagioRepository
    participant Acad as SistemaAcademicoClient
    participant ME as MatchEngine (gRPC)
    participant MQ as BrokerRabbitMQ
    participant Notif as NotificacaoService
    participant CCtrl as ContratoController
    participant CT as ContratoService
    participant Prov as ProvedorAssinatura

    Note over Coord,Notif: FASE 1 - Conciliacao (Match) de Competencias

    Coord->>Web: selecionarVaga(vagaId)
    Web->>Ctrl: executar(ConciliacaoRequestDTO)
    Ctrl->>CS: executarConciliacao(ConciliacaoRequestDTO)
    CS->>Repo: criarTermo(vagaId)
    Repo-->>CS: TermoEstagioDTO (estado EM_CONCILIACAO)
    CS->>Repo: buscarVaga(vagaId)
    Repo-->>CS: VagaDTO
    CS->>Repo: buscarCandidaturas(vagaId)
    Repo-->>CS: List~CandidaturaDTO~
    CS->>Acad: consultarElegibilidade(List~alunoId~)
    Acad-->>CS: List~ElegibilidadeDTO~

    loop para cada candidatura elegivel
        CS->>ME: calcularAfinidade(VagaDTO, CandidaturaDTO)
        ME-->>CS: ResultadoMatchDTO (alunoId, score)
    end

    CS->>CS: selecionarMelhorMatch(List~ResultadoMatchDTO~)

    alt melhorScore >= limiar (0.70)
        CS->>Repo: atualizarEstado(termoId, MATCH_SUGERIDO, ResultadoMatchDTO)
        Repo-->>CS: TermoEstagioDTO
        CS->>Repo: atualizarSituacaoCandidatura(candidaturaId, SELECIONADA)
        Repo-->>CS: CandidaturaDTO
        CS-)MQ: publicar(MatchRealizadoEvent)
        MQ-)Notif: tratarMatchRealizado(MatchRealizadoEvent)
        CS-->>Ctrl: ConciliacaoResponseDTO (MATCH_SUGERIDO)
    else melhorScore < limiar ou sem candidaturas elegiveis
        CS->>Repo: atualizarEstado(termoId, SEM_MATCH, null)
        Repo-->>CS: TermoEstagioDTO
        CS-)MQ: publicar(SemMatchEvent)
        MQ-)Notif: tratarSemMatch(SemMatchEvent)
        CS-->>Ctrl: ConciliacaoResponseDTO (SEM_MATCH)
    end

    Ctrl-->>Web: ConciliacaoResponseDTO
    Web-->>Coord: exibirResultado()

    Note over Web,Prov: FASE 2 - Aceite das partes e Assinatura do Contrato (TCE)

    Web->>CCtrl: aceitar(AceiteDTO)
    CCtrl->>CT: registrarAceite(AceiteDTO)
    CT->>Repo: registrarAceite(termoId, parte)
    Repo-->>CT: TermoEstagioDTO

    alt recusa de qualquer parte [recusa == true]
        CT->>Repo: atualizarEstado(termoId, RECUSADO, null)
        CT-)MQ: publicar(MatchRecusadoEvent)
        CT-->>CCtrl: AceiteResultadoDTO (RECUSADO)
    else aceites completos [aceiteAluno e aceiteEmpresa]
        CT->>Repo: atualizarEstado(termoId, EM_ASSINATURA, null)
        CT->>Prov: criarEnvelope(MinutaDTO)
        Prov-->>CT: EnvelopeDTO (envelopeId, signatarios)
        CT-)MQ: publicar(AssinaturaSolicitadaEvent)
        CT-->>CCtrl: AceiteResultadoDTO (EM_ASSINATURA)
    else aguardando a outra parte
        CT-->>CCtrl: AceiteResultadoDTO (MATCH_SUGERIDO)
    end
    CCtrl-->>Web: AceiteResultadoDTO

    loop para cada signatario (aluno, empresa, coordenacao)
        Prov-)CT: confirmarAssinatura(AssinaturaEventoDTO)
        CT->>Repo: registrarAssinatura(termoId, signatarioId)
        Repo-->>CT: TermoEstagioDTO

        alt todas as assinaturas confirmadas [totalAssinaturas == 3]
            CT->>Repo: atualizarEstado(termoId, VIGENTE, null)
            CT-)MQ: publicar(TermoVigenteEvent)
            MQ-)Notif: tratarTermoVigente(TermoVigenteEvent)
        else assinaturas pendentes [totalAssinaturas < 3]
            CT->>CT: aguardarProximaAssinatura(termoId)
        end
    end
```

### Contratos de interface (regra de consistência)

Toda mensagem recebida por uma linha de vida corresponde a uma operação pública abaixo.

| Linha de vida | Operações públicas | Retorno (DTO) |
|---|---|---|
| `ConciliacaoController` | `executar(ConciliacaoRequestDTO)` | `ConciliacaoResponseDTO` |
| `ConciliacaoService` | `executarConciliacao(ConciliacaoRequestDTO)`<br>`selecionarMelhorMatch(List<ResultadoMatchDTO>)` | `ConciliacaoResponseDTO`<br>`ResultadoMatchDTO` |
| `EstagioRepository` | `criarTermo(vagaId)`<br>`buscarVaga(vagaId)`<br>`buscarCandidaturas(vagaId)`<br>`atualizarEstado(termoId, estado, ResultadoMatchDTO)`<br>`registrarAceite(termoId, parte)`<br>`registrarAssinatura(termoId, signatarioId)`<br>`atualizarSituacaoCandidatura(candidaturaId, situacao)` | `TermoEstagioDTO`<br>`VagaDTO`<br>`List<CandidaturaDTO>`<br>`TermoEstagioDTO` ×3<br>`CandidaturaDTO` |
| `SistemaAcademicoClient` | `consultarElegibilidade(List<alunoId>)` | `List<ElegibilidadeDTO>` |
| `MatchEngine` (gRPC) | `calcularAfinidade(VagaDTO, CandidaturaDTO)` | `ResultadoMatchDTO` |
| `BrokerRabbitMQ` | `publicar(Evento)` | — (assíncrono) |
| `NotificacaoService` | `tratarMatchRealizado(MatchRealizadoEvent)`<br>`tratarSemMatch(SemMatchEvent)`<br>`tratarTermoVigente(TermoVigenteEvent)` | — (assíncrono) |
| `ContratoController` | `aceitar(AceiteDTO)` | `AceiteResultadoDTO` |
| `ContratoService` | `registrarAceite(AceiteDTO)`<br>`confirmarAssinatura(AssinaturaEventoDTO)`<br>`aguardarProximaAssinatura(termoId)` | `AceiteResultadoDTO`<br>— (webhook assíncrono)<br>— |
| `ProvedorAssinatura` | `criarEnvelope(MinutaDTO)` | `EnvelopeDTO` |
| `PortalWeb` | `selecionarVaga(vagaId)`, `exibirResultado()` | — |

## 3. Artefato 2 — Diagrama de Atividades com Raias

Arquivo: [`docs/diagrams/atividades.mmd`](docs/diagrams/atividades.mmd). Cinco raias, quatro decisões com guardas mutuamente exclusivas e dois pares Fork/Join (aceites paralelos e assinaturas paralelas).

```mermaid
flowchart TB
    INI(("●")):::ini

    subgraph L1["Raia 1 - Coordenação UniSenai"]
        direction TB
        A1["Selecionar vaga e<br/>solicitar conciliação"]
        A9["Tratar sem match<br/>(revisar vaga/perfis)"]
    end

    subgraph L2["Raia 2 - Sistema Back-End (API de Estágios)"]
        direction TB
        S1["executarConciliacao():<br/>criar Termo [EM_CONCILIACAO]"]
        S2["Carregar vaga e<br/>candidaturas"]
        D1{"Há candidatos<br/>elegíveis?"}
        S3["calcularAfinidade() por candidato<br/>(score ponderado)"]
        D2{"Melhor score<br/>vs. limiar?"}
        S4["Termo [MATCH_SUGERIDO]<br/>publicar MatchRealizadoEvent"]
        S5["Termo [SEM_MATCH]<br/>publicar SemMatchEvent"]
        F1@{ shape: fork, label: " " }
        J1@{ shape: join, label: " " }
        D3{"Aceites das<br/>partes?"}
        S6["registrarAceite():<br/>consolidar decisões"]
        S7["Termo [EM_ASSINATURA]<br/>gerar minuta (MinutaDTO)"]
        F2@{ shape: fork, label: " " }
        J2@{ shape: join, label: " " }
        D4{"Assinaturas<br/>concluídas?"}
        S8["Termo [VIGENTE]<br/>publicar TermoVigenteEvent"]
        S9["Termo [RECUSADO]<br/>liberar candidato"]
        S10["Termo [EXPIRADO]<br/>(prazoAssinatura excedido)<br/>cancelar envelope"]
    end

    subgraph L3["Raia 3 - Estudante"]
        direction TB
        E1["Avaliar vaga sugerida<br/>e registrar aceite/recusa"]
        E2["Assinar TCE (ou deixar<br/>o prazo expirar)"]
    end

    subgraph L4["Raia 4 - Empresa Concedente"]
        direction TB
        P1["Avaliar candidato sugerido<br/>e registrar aceite/recusa"]
        P2["Assinar TCE (ou deixar<br/>o prazo expirar)"]
    end

    subgraph L5["Raia 5 - Serviços Externos"]
        direction TB
        X1["Sistema Acadêmico:<br/>consultarElegibilidade()"]
        X2["Provedor de Assinatura:<br/>criarEnvelope() e coletar assinaturas"]
        X3["Coordenação assina TCE<br/>via Provedor de Assinatura"]
    end

    FIM_OK(("◉")):::fim
    FIM_NOK(("◉")):::fim

    INI --> A1
    A1 --> S1
    S1 --> S2
    S2 --> X1
    X1 --> D1
    D1 -->|"[qtdElegiveis > 0]"| S3
    D1 -->|"[qtdElegiveis == 0]"| S5
    S3 --> D2
    D2 -->|"[melhorScore >= limiar]"| S4
    D2 -->|"[melhorScore < limiar]"| S5
    S5 --> A9
    A9 --> FIM_NOK

    %% Fork 1 - aceites paralelos
    S4 --> F1
    F1 --> E1
    F1 --> P1
    E1 --> J1
    P1 --> J1
    J1 --> S6
    S6 --> D3
    D3 -->|"[aceiteAluno AND aceiteEmpresa]"| S7
    D3 -->|"[NOT (aceiteAluno AND aceiteEmpresa)]"| S9
    S9 --> FIM_NOK

    %% Fork 2 - assinaturas paralelas
    S7 --> X2
    X2 --> F2
    F2 --> E2
    F2 --> P2
    F2 --> X3
    E2 --> J2
    P2 --> J2
    X3 --> J2
    J2 --> D4
    D4 -->|"[totalAssinaturas == 3]"| S8
    D4 -->|"[totalAssinaturas < 3]"| S10
    S8 --> FIM_OK
    S10 --> FIM_NOK

    classDef ini fill:#000,stroke:#000,color:#000
    classDef fim fill:#fff,stroke:#000,stroke-width:3px,color:#000
```

## 4. Artefato 3 — Diagrama de Transição de Estados

Arquivo: [`docs/diagrams/estados.mmd`](docs/diagrams/estados.mmd). Transições no formato `Gatilho [Guarda] / Ação()`, ações internas `entry/do/exit`, região composta concorrente `EmAssinatura` e cinco estados terminais.

```mermaid
stateDiagram-v2
    direction TB

    [*] --> EmConciliacao : criarTermo(vagaId)

    state "EmConciliacao" as EmConciliacao
    EmConciliacao : entry / carregarVagaECandidaturas()
    EmConciliacao : do / calcularAfinidade()
    EmConciliacao : exit / registrarAuditoria()

    EmConciliacao --> MatchSugerido : conciliacaoConcluida [melhorScore >= limiar] / publicarMatchRealizado()
    EmConciliacao --> SemMatch : conciliacaoConcluida [melhorScore < limiar OU qtdElegiveis == 0] / publicarSemMatch()

    SemMatch --> EmConciliacao : reprocessar [tentativas < 3] / incrementarTentativas()
    SemMatch --> Cancelado : reprocessar [tentativas >= 3] / arquivarTermo()

    state "MatchSugerido" as MatchSugerido
    MatchSugerido : entry / iniciarPrazoAceite(72h)
    MatchSugerido : exit / cancelarPrazoAceite()

    MatchSugerido --> EmAssinatura : aceitesRecebidos [aceiteAluno E aceiteEmpresa] / gerarMinutaEEnvelope()
    MatchSugerido --> Recusado : recusaRecebida [recusaAluno OU recusaEmpresa] / liberarCandidato()
    MatchSugerido --> Expirado : prazoAceiteExcedido [agora > prazoAceite] / notificarPartes()

    state EmAssinatura {
        direction LR
        [*] --> AlunoPendente
        AlunoPendente --> AlunoAssinou : assinaturaConfirmada [signatario == ALUNO] / registrarAssinatura()
        AlunoAssinou --> [*]
        --
        [*] --> EmpresaPendente
        EmpresaPendente --> EmpresaAssinou : assinaturaConfirmada [signatario == EMPRESA] / registrarAssinatura()
        EmpresaAssinou --> [*]
        --
        [*] --> CoordenacaoPendente
        CoordenacaoPendente --> CoordenacaoAssinou : assinaturaConfirmada [signatario == COORDENACAO] / registrarAssinatura()
        CoordenacaoAssinou --> [*]
    }

    EmAssinatura --> Vigente : todasAssinaturasConfirmadas [totalAssinaturas == 3] / ativarVigencia()
    EmAssinatura --> Cancelado : assinaturaRecusada [recusaSignatario] / cancelarEnvelope()
    EmAssinatura --> Expirado : prazoAssinaturaExcedido [agora > prazoAssinatura] / cancelarEnvelope()

    state "Vigente" as Vigente
    Vigente : entry / publicarTermoVigente()
    Vigente : do / monitorarVigencia()

    Vigente --> Concluido : fimVigencia [hoje >= dataFim] / emitirRelatorioFinal()
    Vigente --> Rescindido : rescisaoSolicitada [motivoValido] / notificarPartes()

    Recusado --> [*]
    Expirado --> [*]
    Cancelado --> [*]
    Concluido --> [*]
    Rescindido --> [*]

    note right of EmAssinatura
        Regioes concorrentes (Fork/Join).
        Saida somente quando as 3 regioes
        atingem o estado final (Join).
    end note
```

## 5. Artefato 4 — Visão C4 (Nível 2, Contêineres)

Arquivos: [`docs/architecture/workspace.dsl`](docs/architecture/workspace.dsl) (C4-PlantUML) e [`docs/architecture/c4-containers.mmd`](docs/architecture/c4-containers.mmd) (versão Mermaid renderizada abaixo).

```mermaid
C4Container
    title Nivel 2 - Containers: Conciliacao de Competencias e Assinatura de Contrato (TCE)

    Person(aluno, "Estudante", "Mantem perfil, aceita/recusa match e assina o TCE")
    Person(empresa, "Representante da Empresa", "Publica vagas, aceita/recusa candidato e assina o TCE")
    Person(coord, "Coordenador de Estagios", "Dispara conciliacao e assina o TCE")

    System_Boundary(sis, "Gestao de Estagios UniSenai") {
        Container(spa, "PortalWeb", "React 18, TypeScript, Vite", "SPA de estudantes, empresas e coordenacao")
        Container(api, "API de Estagios", "Node.js 20, NestJS 10", "Conciliacao, Contrato e maquina de estados do TermoEstagio")
        Container(match, "MatchEngine", "Python 3.12, grpcio", "Calcula score de afinidade ponderado")
        ContainerQueue(mq, "BrokerRabbitMQ", "RabbitMQ 3.13", "Exchange topic estagios.eventos")
        Container(worker, "NotificacaoService", "Node.js 20, amqplib", "Consome eventos e envia notificacoes")
        ContainerDb(db, "Banco de Dados", "PostgreSQL 16", "Termos, vagas, candidaturas, competencias, assinaturas e outbox")
    }

    System_Ext(acad, "Sistema Academico UniSenai", "Matricula, periodo e situacao do aluno")
    System_Ext(prov, "ProvedorAssinatura", "Assinatura digital (envelopes e webhooks)")
    System_Ext(smtp, "Servico de E-mail", "E-mails transacionais")

    Rel(aluno, spa, "Usa", "HTTPS")
    Rel(empresa, spa, "Usa", "HTTPS")
    Rel(coord, spa, "Usa", "HTTPS")
    Rel(spa, api, "Executa conciliacao e registra aceites", "JSON/REST, HTTPS, JWT")
    Rel(api, match, "calcularAfinidade()", "gRPC, HTTP/2 TLS, sincrono")
    Rel(api, db, "Le e grava termos, estados e outbox", "SQL, TCP 5432 TLS")
    Rel(api, acad, "consultarElegibilidade()", "REST, HTTPS, OAuth2")
    Rel(api, prov, "criarEnvelope()", "REST, HTTPS, API key")
    Rel(prov, api, "confirmarAssinatura()", "Webhook HTTPS, HMAC-SHA256, assincrono")
    Rel(api, mq, "publicar(Evento) via Outbox Relay", "AMQP 0-9-1 TLS, assincrono")
    Rel(mq, worker, "Entrega eventos de dominio", "AMQP 0-9-1 TLS, assincrono")
    Rel(worker, smtp, "Envia e-mails", "SMTPS 587")
```

## 6. Artefato 5 — ADR 0001

Texto completo em [`docs/architecture/adr-0001.md`](docs/architecture/adr-0001.md).

**ADR 0001 — Mensageria Assíncrona com RabbitMQ e Transactional Outbox** · **Status:** Aprovado
**Contexto:** a conciliação integra Sistema Acadêmico, provedor de assinatura (webhooks) e e-mail; gravar o estado e publicar o evento separadamente gera inconsistência.
**Decisão:** RabbitMQ 3.13 com padrão Transactional Outbox em PostgreSQL 16; matching permanece síncrono (gRPC).
**Consequências:** desacoplamento e eventos sem perda; em troca, consistência eventual, consumidores idempotentes e operação do broker.

## 7. Rastreabilidade entre modelos

| Estado (Artefato 3) | Atividade (Artefato 2) | Mensagem (Artefato 1) |
|---|---|---|
| `EmConciliacao` | `executarConciliacao()`, `calcularAfinidade()` | `executarConciliacao`, `calcularAfinidade` |
| `MatchSugerido` | Termo `[MATCH_SUGERIDO]` + Fork 1 (aceites) | `atualizarEstado(MATCH_SUGERIDO)`, `registrarAceite` |
| `SemMatch` | Termo `[SEM_MATCH]` | `atualizarEstado(SEM_MATCH)`, `publicar(SemMatchEvent)` |
| `EmAssinatura` | Fork 2 (3 assinaturas) | `criarEnvelope`, `confirmarAssinatura` ×3 |
| `Vigente` | Termo `[VIGENTE]` | `atualizarEstado(VIGENTE)`, `publicar(TermoVigenteEvent)` |
| `Recusado` / `Expirado` / `Cancelado` | Termo `[RECUSADO]` / `[EXPIRADO]` | `atualizarEstado(RECUSADO)`, `publicar(MatchRecusadoEvent)` |

## 8. Como renderizar

- GitHub e GitLab renderizam os blocos `mermaid` deste README.
- PlantUML (`workspace.dsl`): `java -jar plantuml.jar docs/architecture/workspace.dsl`.
- Mermaid CLI: `npx -p @mermaid-js/mermaid-cli mmdc -i docs/diagrams/sequencia.mmd -o sequencia.svg`.
