# Sophia — Architecture (v0.1, draft)

> 목표: AI 에이전트가 정확한 정보를 빠르게 찾을 수 있는 **개발자 중심 지식 계층**을 구축한다.
> 직접 구현보다 **검증된 오픈소스를 조합**하고, 그 위에 **에이전트 오케스트레이션**을 얹는다.

## 0. Goals & Non-Goals

**Goals**
- 코드 / 사내 문서 / 외부 자료를 단일 지식 계층으로 통합한다.
- 의미(vector) · 키워드(BM25) · 관계(graph) 세 축의 검색을 모두 제공한다.
- 모든 답변에 출처(provenance)를 추적할 수 있다.
- 모든 도구가 MCP로 노출되어 어떤 LLM 클라이언트에서도 사용 가능하다.

**Non-Goals (v0.1)**
- 자체 벡터 DB, 자체 그래프 DB 구현.
- 실시간 인덱싱(incremental compile은 하되, 초당 갱신은 아님).
- 멀티테넌시 / 권한 모델 (단일 팀 가정).

---

## 1. 핵심 아이디어

세 레이어 모두 **로컬-퍼스트 + 마크다운 파일 + MCP 서버 노출**이라는 동일한 mental model을 공유한다. 따라서 **마크다운 파일 시스템을 공통 인터페이스**로 삼아, 각 도구가 같은 디렉토리를 읽도록 배치한다.

```
            ┌──────────────────────────────────────┐
            │  Orchestration Agent (LangGraph)     │
            │  - 질문 분류 / 라우팅 / 합성          │
            └──────────┬───────────┬───────────────┘
                       │ MCP       │ MCP        │ MCP
            ┌──────────▼─┐ ┌───────▼────┐ ┌─────▼──────────────┐
            │  graphify   │ │   qmd      │ │ llm-wiki-compiler  │
            │  (관계)     │ │ (하이브리드)│ │ (개념 컴파일)       │
            └──────────┬─┘ └───────┬────┘ └──────────┬─────────┘
                       │           │                  │
                       └─────┬─────┴───────┬──────────┘
                             ▼             ▼
                       wiki/ (concepts, queries, index)   ← 공통 소스
                       raw/  (외부에서 수집한 .md)
                       repos/ (코드)
```

---

## 2. 컴포넌트 사양

### 2.1 Knowledge Compiler — `llm-wiki-compiler`
- **레포**: <https://github.com/atomicmemory/llm-wiki-compiler>
- **역할**: 원천 자료(URL/PDF/코드 세션/마크다운)를 받아 **개념 단위 마크다운 + `[[wikilinks]]`**로 컴파일.
- **입력**: `raw/`, 코드 레포, URL 목록.
- **출력**:
  - `wiki/concepts/*.md` — YAML frontmatter (title, summary, confidence, provenance) 포함.
  - `wiki/queries/*.md` — 저장된 질문/답변.
  - `wiki/index.md` — 자동 생성 TOC.
  - `.llmwiki/` — schema, candidates, compile state.
- **속성**: incremental (SHA-256), claim-level provenance, GraphML/JSON-LD/llms.txt 익스포트.
- **MCP**: `llmwiki serve` — `ingest`, `compile`, `query`, `lint` 도구 노출.

### 2.2 Graph Layer — `graphify`
- **레포**: <https://github.com/safishamsi/graphify>
- **역할**: `wiki/` + 코드 레포를 스캔해 **개체 간 관계 그래프**를 만든다. Leiden 알고리즘으로 커뮤니티 클러스터링.
- **입력**: 디렉토리 (코드 28개 언어 + .md + PDF 등).
- **출력**: `graph.json`, `graph.html`(시각화), `GRAPH_REPORT.md`.
- **MCP**: 노출 가능 — 노드/이웃/커뮤니티 조회.
- **운영**: 정기 재생성 (CI 또는 cron). 결과물은 git에 커밋.

### 2.3 Hybrid Search — `qmd`
- **레포**: <https://github.com/tobi/qmd>
- **역할**: `wiki/`(+ 옵션으로 코드)를 인덱싱하여 **BM25 + vector + LLM 리랭크 (RRF)** 검색.
- **모델**: 로컬 GGUF (EmbeddingGemma, Qwen3-Reranker, Qwen3 query expansion).
- **저장**: SQLite + FTS5 + sqlite-vec.
- **청킹**: AST-aware (코드), 15% 오버랩 ~900 토큰 (문서).
- **MCP**: 내장 — 에이전트가 검색 호출.

### 2.4 Orchestration — LangGraph
- **선택 근거**: 본 시스템의 핵심은 **상태 기반 라우팅** (예: 그래프 탐색 결과를 보고 추가로 의미 검색을 할지 판단). LangGraph의 명시적 state machine이 이 패턴에 자연스럽다. LlamaIndex는 자체 RAG 파이프라인이 이미 qmd와 겹치므로 일급 후보에서 제외하되, 필요 시 노드 내부에서 보조적으로 사용 가능.
- **기능**:
  - 질문 → 의도 분류 (코드 위치? 개념 정의? 관계? 최신 동향?).
  - 도구 라우팅 (qmd 우선 / graphify 우선 / wiki concept 직접 조회).
  - 결과 합성 + 출처 인용.
  - 답변이 부족하면 `llmwiki query --save`로 결과를 wiki에 환류 (자가-증식).

---

## 3. 데이터 흐름

```
[외부 소스]
   │ (수집기 — v0.2 이후)
   ▼
raw/*.md ──┐
           ├──► llm-wiki-compiler ──► wiki/   ──┬──► graphify ──► graph.json
repos/* ──┘                                     └──► qmd      ──► .qmd/sqlite

[질문] ──► LangGraph Agent ──► (graphify MCP | qmd MCP | llmwiki MCP) ──► [답변+인용]
```

**핵심 불변식**
- `wiki/`는 컴파일러의 출력이자 다른 두 도구의 입력. **수동 편집은 원칙적으로 금지**, 모든 변경은 컴파일 파이프라인을 거친다.
- `raw/`와 `repos/`는 원천. graphify는 코드를 직접 읽고, 비-코드 자료는 컴파일러를 거쳐 `wiki/`에서 만난다.

---

## 4. 디렉토리 구조 (제안)

```
sophia/
├── docs/
│   └── architecture.md          # 이 문서
├── raw/                         # 외부에서 수집한 원천 .md (수집기는 v0.2)
├── repos/                       # 분석 대상 코드 (submodule 또는 심볼릭 링크)
├── wiki/                        # llm-wiki-compiler 출력 (커밋)
│   ├── concepts/
│   ├── queries/
│   └── index.md
├── .llmwiki/                    # 컴파일러 상태 (gitignore 대상 일부)
├── graph.json                   # graphify 출력 (커밋)
├── graph.html
├── .qmd/                        # qmd SQLite 인덱스 (gitignore)
├── orchestrator/
│   ├── pyproject.toml
│   ├── sophia/
│   │   ├── graph.py             # LangGraph state machine
│   │   ├── nodes/               # classify, route, synthesize 노드
│   │   ├── tools/               # MCP 클라이언트 래퍼
│   │   └── prompts/
│   └── tests/
├── scripts/
│   ├── compile.sh               # llmwiki compile
│   ├── reindex.sh               # graphify + qmd 재실행
│   └── serve-mcp.sh             # 세 MCP 서버 동시 기동
└── README.md
```

---

## 5. 오케스트레이션 워크플로우 (LangGraph 노드)

```
START → classify_intent → route ─┬─► search_qmd       ─┐
                                 ├─► traverse_graph    ├─► synthesize → cite → END
                                 └─► fetch_concept     ─┘
                                              │
                                              └─► (부족 시) → expand_query → loop
```

**노드 책임**
- `classify_intent`: LLM으로 질문 유형 분류 (lookup / explain / locate / compare / fresh).
- `route`: 분류에 따라 1차 도구 선택. 다중 도구도 가능 (병렬).
- `search_qmd` / `traverse_graph` / `fetch_concept`: 각 MCP 호출.
- `synthesize`: 결과를 사람-가독 답변으로 합성.
- `cite`: 모든 주장에 wiki concept 또는 코드 라인 출처 첨부.
- `expand_query`: 결과 confidence가 임계 이하면 질의 확장 후 재탐색.

---

## 6. 인터페이스

**v0.1 사용 진입점**
1. **IDE에서 직접**: Claude Code / Cursor가 세 MCP 서버에 직접 붙는다 (오케스트레이터 미사용).
2. **CLI 에이전트**: `sophia ask "..."` — LangGraph 파이프라인 실행.

**v0.2+ (선택)**
3. **HTTP API** + 간단 웹 UI.
4. **Slack 봇**.

---

## 7. 단계별 마일스톤

| 단계 | 산출물 | 검증 기준 |
|---|---|---|
| **M0 — 환경 셋업** | 세 도구 로컬 설치, MCP 기동 스크립트 | 각 도구가 단독 데모 동작 |
| **M1 — 단일 레포 PoC** | sophia 자기 자신을 대상으로 wiki 컴파일 + graph + qmd 인덱스 | 자연어 질의 5개에 정확한 답변 |
| **M2 — 오케스트레이터** | LangGraph state machine + CLI | 라우팅이 단일 도구보다 정확도↑ (소규모 평가셋) |
| **M3 — 외부 수집기** | Confluence/Notion → `raw/` 동기화 | 사내 문서 100건 ingest 성공 |
| **M4 — 평가/관측** | 질의 로그, confidence 트래킹, 회귀 테스트셋 | 정확도/지연 메트릭 대시보드 |

---

## 8. 미해결 질문 (다음 결정 필요)

1. **외부 소스 수집 전략** — 사용자 결정 보류. M3에서 다시 다룬다.
2. **임베딩 모델 선택** — qmd 기본(EmbeddingGemma)을 쓸지, 한국어 특화 모델로 교체할지. 사내 문서 비중에 따라 변동.
3. **그래프 정규화** — graphify의 노드 ID와 wiki concept 슬러그를 어떻게 매핑할지 (양방향 링크 유지).
4. **재컴파일 트리거** — 파일 변경 감시 / cron / Git hook 중 무엇을 1차로 할지.
5. **평가셋 구축** — golden Q&A 세트가 없으면 라우팅 정확도 측정이 어려움. 누가 만들지 결정 필요.

---

## 9. 참고 링크

- llm-wiki-compiler: <https://github.com/atomicmemory/llm-wiki-compiler>
- graphify: <https://github.com/safishamsi/graphify>
- qmd: <https://github.com/tobi/qmd>
- LangGraph: <https://github.com/langchain-ai/langgraph>
- Karpathy "LLM Wiki" gist (2026-04): <https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f>
