# Como Contribuir

Obrigado pelo interesse em melhorar o `oracle-26ai-helper-ptbr`!

## Tipos de contribuição bem-vindos

### 1. Reportar bugs / inconsistências em templates

Se você usou um template e ele não funcionou em sua instalação Oracle 26ai, abra issue com:

- Versão exata do Oracle (`SELECT banner_full FROM v$version;`)
- Edition (Enterprise) e options instaladas
- Release update (23.26.x — qual exatamente)
- Template afetado (ex: `assets/ai_vector_search_basics.sql`)
- Erro recebido (ORA-XXXXX e mensagem completa)
- Trecho mínimo reproduzível

### 2. Atualizar para novos release updates

Oracle libera Release Updates trimestrais. Sintaxes podem evoluir:
- Novos parâmetros em `CREATE VECTOR INDEX`
- Novos pacotes ou subprogramas em `DBMS_VECTOR_CHAIN`
- Mudanças no protocolo RAFT
- APIs novas em duality views

Se você identificou mudança após release update, abra PR atualizando templates afetados com:
- Referência à doc oficial Oracle
- Compatibilidade reversa quando possível (mencionar versão mínima)

### 3. Sugerir novos templates ou features cobertas

A skill começou como MVP focado em 3 features. Outras áreas 26ai podem ser cobertas no futuro:
- Select AI (natural language → SQL)
- SQL Firewall (compliance/auditoria)
- True Cache (performance)
- DBMS_CLOUD nativo
- Property Graph (continua de 23ai)
- AI Agents in DB
- Server-side JavaScript

Para propor expansão, abra issue descrevendo:
- Cenário de uso
- Por que essa feature deveria estar coberta
- Esboço do template proposto

### 4. Sugerir adições/correções em references

References são markdown — fácil de revisar. PRs diretas são bem-vindas para:
- Correções de erros técnicos
- Atualização de links quebrados
- Inclusão de exemplos esclarecedores
- Adições de seções "anti-patterns"

## Padrões a seguir em PRs

### Naming

- Comentários e nomes de domínio em PT-BR
- Keywords Oracle novas (`VECTOR`, `DUALITY VIEW`, `RAFT`, etc.) em inglês obrigatoriamente
- Pacotes nativos (`DBMS_VECTOR`, `DBMS_VECTOR_CHAIN`) em inglês
- Prefixos Trivadis em inglês: `g_`, `gc_`, `l_`, `lc_`, `p_`, `r_`, `t_`, `co_`, `e_`

### Estrutura de templates

Templates SQL devem seguir o padrão dos existentes:

```sql
--==============================================================================
-- Template: <nome>
--
-- Cobre: <breve descrição>
-- Pré-requisito: Oracle 23ai+ ou 26ai (banner mostra "AI Database")
-- Princípios aplicados: #X, #Y
--==============================================================================

-- 1. Setup inicial
...

-- 2. Caso principal
...

-- 3. Variações
...

--==============================================================================
-- N. Anti-patterns
--==============================================================================

/*
ANTI-PATTERN 1: ...
  Errado:
    ...
  Correto:
    ...
*/
```

### Verificações obrigatórias antes de PR

- Testou o template num ambiente 23ai/26ai real?
- Documentou versão mínima necessária (alguns features são 23.7+, outros 23.26+)?
- Adicionou ao `assets/README.md` se for template novo?
- Atualizou `CHANGELOG.md` com a mudança?

## O que NÃO é aceito

- PRs com features de 19c ou anteriores (esta skill é só 23ai+/26ai)
- PRs em outras linguagens (Python, Java) — esta skill é exclusivamente PL/SQL/SQL
- Code dumps massivos sem teste prévio em ambiente Oracle real
- PRs traduzindo keywords Oracle ou pacotes nativos para PT-BR
- PRs sobre APEX 26.1 antes do GA (esperar release oficial)

## Código de Conduta

Seja respeitoso. Discussões técnicas são sobre código, não sobre pessoas. Todas as linguagens (PT-BR, EN, ES) são bem-vindas em issues, embora o conteúdo da skill seja em PT-BR.

## Contato

Issues no GitHub são o canal principal.
