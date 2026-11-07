@startuml C4_Containers_Estagios_UniSenai
' C4-PlantUML - Nivel 2 (Containers) - Gestao de Estagios UniSenai
!include https://raw.githubusercontent.com/plantuml-stdlib/C4-PlantUML/master/C4_Container.puml

LAYOUT_WITH_LEGEND()
title Nivel 2 - Containers: Conciliacao de Competencias e Assinatura de Contrato (TCE)

Person(aluno, "Estudante", "Mantem perfil de competencias, aceita/recusa match e assina o TCE")
Person(empresa, "Representante da Empresa", "Publica vagas, aceita/recusa candidato e assina o TCE")
Person(coord, "Coordenador de Estagios", "Dispara a conciliacao, trata sem-match e assina o TCE")

System_Boundary(sis, "Gestao de Estagios UniSenai") {
    Container(spa, "PortalWeb", "React 18, TypeScript, Vite", "SPA usada por estudantes, empresas e coordenacao")
    Container(api, "API de Estagios", "Node.js 20, NestJS 10", "ConciliacaoController/Service, ContratoController/Service e EstagioRepository. Mantem a maquina de estados do TermoEstagio")
    Container(match, "MatchEngine", "Python 3.12, grpcio", "Calcula a afinidade (score ponderado) entre VagaDTO e CandidaturaDTO")
    ContainerQueue(mq, "BrokerRabbitMQ", "RabbitMQ 3.13", "Exchange 'estagios.eventos' (topic) com eventos de dominio")
    Container(worker, "NotificacaoService", "Node.js 20, amqplib", "Consome eventos e dispara e-mails/notificacoes")
    ContainerDb(db, "Banco de Dados", "PostgreSQL 16", "Termos, vagas, candidaturas, competencias, assinaturas e tabela outbox")
}

System_Ext(acad, "Sistema Academico UniSenai", "Matricula, periodo e situacao do aluno")
System_Ext(prov, "ProvedorAssinatura", "Assinatura digital de contratos (envelopes e webhooks)")
System_Ext(smtp, "Servico de E-mail", "Entrega de e-mails transacionais")

Rel(aluno, spa, "Usa", "HTTPS")
Rel(empresa, spa, "Usa", "HTTPS")
Rel(coord, spa, "Usa", "HTTPS")

Rel(spa, api, "Executa conciliacao e registra aceites", "JSON/REST sobre HTTPS, JWT")
Rel(api, match, "calcularAfinidade(VagaDTO, CandidaturaDTO)", "gRPC (HTTP/2, TLS) - sincrono")
Rel(api, db, "Le e grava termos, estados e outbox", "SQL/TCP 5432 (TLS), optimistic locking")
Rel(api, acad, "consultarElegibilidade(alunoIds)", "REST/HTTPS, OAuth2 client credentials")
Rel(api, prov, "criarEnvelope(MinutaDTO)", "REST/HTTPS, API key")
Rel(prov, api, "confirmarAssinatura(AssinaturaEventoDTO)", "Webhook HTTPS, HMAC-SHA256 - assincrono")
Rel(api, mq, "publicar(Evento) via Outbox Relay", "AMQP 0-9-1 (TLS) - assincrono")
Rel(mq, worker, "Entrega eventos (tratarMatchRealizado, tratarSemMatch, tratarTermoVigente)", "AMQP 0-9-1 (TLS) - assincrono")
Rel(worker, smtp, "Envia e-mails", "SMTPS/587")
@enduml
