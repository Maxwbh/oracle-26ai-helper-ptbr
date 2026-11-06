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

A skill é de **aprofundamento** em AI Vector Search, JSON Relational Duality, RAFT e migração 19c → 26ai. Sintaxe nova genérica do 26ai (SQL Firewall, MLE JavaScript, Domains etc.) fica na `oracle-26ai-ptbr` da suíte [oracle-skills-ptbr](https://github.com/Maxwbh/oracle-skills-ptbr). Candidatos a cobertura futura aqui:
- Select AI / Select AI Agent (on-prem desde 23.26.1)
- Oracle AI Database Agent Engine (`DBMS_AI_AGENT`)
- GraphRAG (`DBMS_AI_GRAPHRAG`, 23.26.4+)
- Property Graph combinado com vetores

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

Rode a validação estática (a mesma do CI):

```bash
python3 .github/scripts/validar_repositorio.py .
```

E, com Docker, o teste de integração local contra o 26ai Free (imagem `container-registry.oracle.com/database/free:latest`; o arquivo ONNX é opcional e habilita os templates de Vector):

```bash
.github/scripts/teste_integracao_local.sh caminho/all_MiniLM_L12_v2.onnx
```


- Testou o template num ambiente 23ai/26ai real?
- Marcou o código com `-- 26ai` e a versão mínima quando a feature for de um RU específico (ex.: `-- 26ai 23.26.1+`)?
- Citou a fonte (docs.oracle.com, oracle-base, mikedietrichde) para cada afirmação de versão ou data?
- Preencheu no cabeçalho "Revisado", "Tipo", "RU mínimo" e "Edição Free"?
- Nenhuma senha, token ou chave no script (use `ACCEPT … HIDE`)?
- Package/procedure reutilizável sem `COMMIT`/`ROLLBACK` (a transação é do chamador)?
- Adicionou ao `assets/README.md` se for template novo?
- Atualizou `CHANGELOG.md` com a mudança?

## O que NÃO é aceito

- PRs com features de 19c ou anteriores (vão para a suíte oracle-skills-ptbr)
- PRs em outras linguagens (Python, Java) — esta skill é exclusivamente PL/SQL/SQL
- Code dumps massivos sem teste prévio em ambiente Oracle real
- PRs traduzindo keywords Oracle ou pacotes nativos para PT-BR
- PRs sobre APEX (vão para a `oracle-apex-ptbr` da suíte)

## Código de Conduta

Seja respeitoso. Discussões técnicas são sobre código, não sobre pessoas. Todas as linguagens (PT-BR, EN, ES) são bem-vindas em issues, embora o conteúdo da skill seja em PT-BR.

## Contato

Issues no GitHub são o canal principal.
