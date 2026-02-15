# Interject Integration Sweep — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use clavain:executing-plans to implement this plan task-by-task.

**Goal:** Connect interject's ambient discovery engine to the Interverse ecosystem — shared search infrastructure, tiered action routing, closed-loop feedback, and internal awareness.

**Architecture:** Four independent workstreams: (1) intersearch shared library extraction, (2) output pipeline upgrade for tiered Clavain routing, (3) feedback loop via tool-time + bead lifecycle + query log, (4) internal awareness via plans/beads/interwatch signals. Each workstream modifies interject and potentially one other module.

**Tech Stack:** Python (hatchling/uv), SQLite, numpy, sentence-transformers, aiohttp, bd CLI, sqlite3 CLI

---

### Task 1: Scaffold intersearch package

**Files:**
- Create: `plugins/intersearch/pyproject.toml`
- Create: `plugins/intersearch/src/intersearch/__init__.py`
- Create: `plugins/intersearch/src/intersearch/exa.py`
- Create: `plugins/intersearch/src/intersearch/embeddings.py`
- Create: `plugins/intersearch/tests/test_exa.py`
- Create: `plugins/intersearch/tests/test_embeddings.py`

**Step 1: Create package scaffold**

Create `plugins/intersearch/pyproject.toml`:
```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "intersearch"
version = "0.1.0"
description = "Shared search and embedding infrastructure for the Interverse ecosystem"
license = "MIT"
requires-python = ">=3.10"
authors = [
    { name = "MK", email = "mistakeknot@vibeguider.org" }
]
dependencies = [
    "aiohttp>=3.9",
    "numpy>=1.26",
    "sentence-transformers>=2.0",
]

[project.optional-dependencies]
test = ["pytest>=8.0", "pytest-asyncio>=0.23"]

[tool.hatch.build.targets.wheel]
packages = ["src/intersearch"]

[tool.pytest.ini_options]
asyncio_mode = "strict"
```

Create `plugins/intersearch/src/intersearch/__init__.py`:
```python
"""Shared search and embedding infrastructure for the Interverse ecosystem."""

__version__ = "0.1.0"
```

**Step 2: Extract embeddings module**

Create `plugins/intersearch/src/intersearch/embeddings.py` — copy from `plugins/interject/src/interject/embeddings.py` with the same API:
```python
"""Embedding client — shared across interject and tldr-swinton.

Loads sentence-transformers model locally (all-MiniLM-L6-v2, 384 dims).
"""

from __future__ import annotations

import logging
import numpy as np

logger = logging.getLogger(__name__)

DEFAULT_MODEL = "all-MiniLM-L6-v2"
EMBEDDING_DIM = 384


class EmbeddingClient:
    """Text -> vector embeddings with lazy model loading."""

    def __init__(self, model_name: str = DEFAULT_MODEL):
        self.model_name = model_name
        self._model = None

    def _ensure_model(self) -> None:
        if self._model is not None:
            return
        from sentence_transformers import SentenceTransformer
        logger.info("Loading embedding model: %s", self.model_name)
        self._model = SentenceTransformer(self.model_name)

    def embed(self, text: str) -> np.ndarray:
        """Embed a single text. Returns normalized vector."""
        return self.embed_batch([text])[0]

    def embed_batch(self, texts: list[str]) -> np.ndarray:
        """Embed multiple texts. Returns (N, dim) normalized array."""
        self._ensure_model()
        embeddings = self._model.encode(
            texts, normalize_embeddings=True, show_progress_bar=False
        )
        return np.array(embeddings, dtype=np.float32)

    def cosine_similarity(self, a: np.ndarray, b: np.ndarray) -> float:
        """Cosine similarity between two normalized vectors."""
        return float(np.dot(a, b))


def vector_to_bytes(vec: np.ndarray) -> bytes:
    """Serialize numpy vector to bytes for SQLite blob storage."""
    return vec.astype(np.float32).tobytes()


def bytes_to_vector(data: bytes) -> np.ndarray:
    """Deserialize bytes from SQLite back to numpy vector."""
    return np.frombuffer(data, dtype=np.float32)
```

**Step 3: Extract Exa module**

Create `plugins/intersearch/src/intersearch/exa.py` — generalized from `plugins/interject/src/interject/sources/exa.py`, decoupled from the interject source adapter protocol:
```python
"""Exa semantic search client — shared across interject and interflux."""

from __future__ import annotations

import os
import logging
from datetime import datetime
from dataclasses import dataclass, field
from typing import Any

import aiohttp

logger = logging.getLogger(__name__)

EXA_API = "https://api.exa.ai/search"


@dataclass
class ExaResult:
    """A single Exa search result."""
    title: str
    url: str
    text: str = ""
    highlights: list[str] = field(default_factory=list)
    score: float = 0.0
    author: str = ""
    published_date: str = ""
    matched_query: str = ""


async def search(
    query: str,
    *,
    num_results: int = 10,
    use_autoprompt: bool = True,
    start_date: datetime | None = None,
    text_max_chars: int = 1000,
    highlight_sentences: int = 3,
    api_key: str | None = None,
) -> list[ExaResult]:
    """Run a single Exa semantic search query.

    Args:
        query: Search query string
        num_results: Max results to return
        use_autoprompt: Let Exa rewrite query for better results
        start_date: Only include results published after this date
        text_max_chars: Max characters of text content per result
        highlight_sentences: Number of highlight sentences per result
        api_key: Exa API key (falls back to EXA_API_KEY env var)

    Returns:
        List of ExaResult objects
    """
    key = api_key or os.environ.get("EXA_API_KEY")
    if not key:
        logger.warning("No EXA_API_KEY set, skipping search")
        return []

    payload: dict[str, Any] = {
        "query": query,
        "numResults": num_results,
        "useAutoprompt": use_autoprompt,
        "contents": {
            "text": {"maxCharacters": text_max_chars},
            "highlights": {"numSentences": highlight_sentences},
        },
    }
    if start_date:
        payload["startPublishedDate"] = start_date.strftime("%Y-%m-%dT%H:%M:%S.000Z")

    async with aiohttp.ClientSession() as session:
        async with session.post(
            EXA_API,
            json=payload,
            headers={
                "x-api-key": key,
                "Content-Type": "application/json",
            },
        ) as resp:
            if resp.status != 200:
                logger.warning("Exa search failed: HTTP %d", resp.status)
                return []
            data = await resp.json()

    results = []
    for item in data.get("results", []):
        results.append(ExaResult(
            title=item.get("title", "") or "",
            url=item.get("url", "") or "",
            text=item.get("text", "") or "",
            highlights=item.get("highlights", []),
            score=item.get("score", 0.0),
            author=item.get("author", "") or "",
            published_date=item.get("publishedDate", "") or "",
            matched_query=query,
        ))
    return results


async def multi_search(
    queries: list[str],
    **kwargs: Any,
) -> list[ExaResult]:
    """Run multiple Exa searches and deduplicate by URL.

    Accepts same kwargs as search().
    """
    seen_urls: set[str] = set()
    all_results: list[ExaResult] = []

    for query in queries:
        results = await search(query, **kwargs)
        for r in results:
            if r.url not in seen_urls:
                seen_urls.add(r.url)
                all_results.append(r)

    return all_results
```

**Step 4: Write failing tests**

Create `plugins/intersearch/tests/test_embeddings.py`:
```python
"""Tests for shared embedding client."""

import numpy as np
import pytest

from intersearch.embeddings import (
    EMBEDDING_DIM,
    EmbeddingClient,
    bytes_to_vector,
    vector_to_bytes,
)


class TestEmbeddingClient:
    def test_embed_returns_correct_dim(self):
        client = EmbeddingClient()
        vec = client.embed("test text")
        assert vec.shape == (EMBEDDING_DIM,)

    def test_embed_normalized(self):
        client = EmbeddingClient()
        vec = client.embed("test text")
        norm = np.linalg.norm(vec)
        assert abs(norm - 1.0) < 0.01

    def test_embed_batch(self):
        client = EmbeddingClient()
        vecs = client.embed_batch(["hello", "world"])
        assert vecs.shape == (2, EMBEDDING_DIM)

    def test_cosine_similarity_identical(self):
        client = EmbeddingClient()
        vec = client.embed("same text")
        sim = client.cosine_similarity(vec, vec)
        assert abs(sim - 1.0) < 0.01

    def test_cosine_similarity_different(self):
        client = EmbeddingClient()
        a = client.embed("quantum physics research")
        b = client.embed("chocolate cake recipe")
        sim = client.cosine_similarity(a, b)
        assert sim < 0.8  # Should be dissimilar


class TestSerialization:
    def test_roundtrip(self):
        vec = np.random.randn(EMBEDDING_DIM).astype(np.float32)
        data = vector_to_bytes(vec)
        recovered = bytes_to_vector(data)
        np.testing.assert_array_almost_equal(vec, recovered)
```

Create `plugins/intersearch/tests/test_exa.py`:
```python
"""Tests for shared Exa client."""

import pytest
from unittest.mock import AsyncMock, patch, MagicMock
from datetime import datetime

from intersearch.exa import ExaResult, search, multi_search


class TestExaResult:
    def test_creation(self):
        r = ExaResult(title="Test", url="https://example.com")
        assert r.title == "Test"
        assert r.text == ""
        assert r.highlights == []

    def test_defaults(self):
        r = ExaResult(title="T", url="u")
        assert r.score == 0.0
        assert r.author == ""
        assert r.matched_query == ""


class TestSearch:
    @pytest.mark.asyncio
    async def test_no_api_key_returns_empty(self):
        with patch.dict("os.environ", {}, clear=True):
            results = await search("test query", api_key=None)
            assert results == []

    @pytest.mark.asyncio
    async def test_search_with_mock_response(self):
        mock_response = MagicMock()
        mock_response.status = 200
        mock_response.json = AsyncMock(return_value={
            "results": [
                {
                    "title": "Test Result",
                    "url": "https://example.com",
                    "text": "Some text",
                    "highlights": ["highlight1"],
                    "score": 0.95,
                    "author": "Author",
                    "publishedDate": "2026-01-01",
                }
            ]
        })
        mock_response.__aenter__ = AsyncMock(return_value=mock_response)
        mock_response.__aexit__ = AsyncMock(return_value=False)

        mock_session = MagicMock()
        mock_session.post.return_value = mock_response
        mock_session.__aenter__ = AsyncMock(return_value=mock_session)
        mock_session.__aexit__ = AsyncMock(return_value=False)

        with patch("intersearch.exa.aiohttp.ClientSession", return_value=mock_session):
            results = await search("test", api_key="fake-key")
            assert len(results) == 1
            assert results[0].title == "Test Result"
            assert results[0].score == 0.95


class TestMultiSearch:
    @pytest.mark.asyncio
    async def test_deduplicates_by_url(self):
        mock_result = ExaResult(title="Dup", url="https://example.com")
        with patch("intersearch.exa.search", new_callable=AsyncMock) as mock_search:
            mock_search.return_value = [mock_result]
            results = await multi_search(["q1", "q2"], api_key="fake")
            assert len(results) == 1  # Deduplicated
```

**Step 5: Run tests to verify they pass**

Run: `cd plugins/intersearch && uv run pytest tests/ -v`
Expected: All tests pass

**Step 6: Commit**

```bash
cd plugins/intersearch
git init && git add -A
git commit -m "feat: scaffold intersearch shared library (embeddings + exa)"
```

---

### Task 2: Wire interject to use intersearch

**Files:**
- Modify: `plugins/interject/pyproject.toml` (add intersearch dep)
- Modify: `plugins/interject/src/interject/embeddings.py` (re-export from intersearch)
- Modify: `plugins/interject/src/interject/sources/exa.py` (delegate to intersearch)
- Test: `plugins/interject/tests/test_sources.py` (existing, verify still passes)

**Step 1: Add intersearch as a path dependency**

In `plugins/interject/pyproject.toml`, add to dependencies:
```toml
dependencies = [
    "intersearch @ file:///root/projects/Interverse/plugins/intersearch",
    "mcp>=1.0.0",
    "aiohttp>=3.9",
    "pyyaml>=6.0",
    "numpy>=1.26",
    "sentence-transformers>=2.0",
]
```

**Step 2: Slim down interject's embeddings.py to re-export**

Replace `plugins/interject/src/interject/embeddings.py` with:
```python
"""Embedding client — delegates to intersearch shared library.

Re-exports all public API for backward compatibility.
"""

from intersearch.embeddings import (  # noqa: F401
    DEFAULT_MODEL,
    EMBEDDING_DIM,
    EmbeddingClient,
    bytes_to_vector,
    vector_to_bytes,
)
```

**Step 3: Slim down interject's exa adapter to use intersearch**

In `plugins/interject/src/interject/sources/exa.py`, replace the raw aiohttp calls with `intersearch.exa.multi_search()`:
```python
"""Exa source adapter — uses intersearch shared Exa client."""

from __future__ import annotations

from datetime import datetime
from typing import Any

from intersearch.exa import multi_search as exa_multi_search

from .base import EnrichedDiscovery, RawDiscovery


class ExaAdapter:
    name = "exa"

    def __init__(self, config: dict[str, Any] | None = None):
        cfg = config or {}
        self.max_results: int = cfg.get("max_results", 30)
        self.use_autoprompt: bool = cfg.get("use_autoprompt", True)
        self.search_queries: list[str] = cfg.get("search_queries", [
            "new MCP server tools for AI agents",
            "Claude Code plugin development",
            "multi-agent orchestration framework",
            "code analysis LLM tooling",
            "developer workflow automation AI",
        ])

    async def fetch(
        self, since: datetime, topics: list[str]
    ) -> list[RawDiscovery]:
        """Fetch results via intersearch Exa client."""
        queries = list(self.search_queries)
        for topic in topics[:5]:
            queries.append(f"{topic} tools and frameworks 2025 2026")

        results = await exa_multi_search(
            queries,
            num_results=min(self.max_results, 10),
            use_autoprompt=self.use_autoprompt,
            start_date=since,
        )

        discoveries = []
        for r in results[:self.max_results]:
            source_id = r.url.split("//")[-1][:80].replace("/", "_")
            summary = r.text[:300] if r.text else " ".join(r.highlights)[:300]
            discoveries.append(
                RawDiscovery(
                    source=self.name,
                    source_id=source_id,
                    title=r.title,
                    summary=summary,
                    url=r.url,
                    metadata={
                        "exa_score": r.score,
                        "author": r.author,
                        "published_date": r.published_date,
                        "highlights": r.highlights,
                        "full_text": r.text[:2000],
                        "matched_query": r.matched_query,
                    },
                )
            )
        return discoveries

    async def enrich(self, discovery: RawDiscovery) -> EnrichedDiscovery:
        """Enrich with full text for embedding."""
        full_text = discovery.metadata.get("full_text", "")
        highlights = discovery.metadata.get("highlights", [])
        embed_text = f"{discovery.title}. {full_text}" if full_text else discovery.title
        if highlights:
            embed_text += " " + " ".join(highlights)

        return EnrichedDiscovery(
            source=discovery.source,
            source_id=discovery.source_id,
            title=discovery.title,
            summary=discovery.summary,
            url=discovery.url,
            metadata=discovery.metadata,
            discovered_at=discovery.discovered_at,
            full_text=embed_text[:3000],
            tags=[discovery.metadata.get("matched_query", "")],
        )
```

**Step 4: Run existing tests to verify nothing broke**

Run: `cd plugins/interject && uv run pytest tests/ -v`
Expected: All 37 tests pass

**Step 5: Commit**

```bash
cd plugins/interject
git add pyproject.toml src/interject/embeddings.py src/interject/sources/exa.py
git commit -m "refactor: delegate embeddings and exa to intersearch shared library"
```

---

### Task 3: Upgrade output pipeline for tiered Clavain routing

**Files:**
- Modify: `plugins/interject/src/interject/outputs.py` (brainstorm doc format, digest)
- Create: `plugins/interject/tests/test_outputs.py`

**Step 1: Write failing tests for brainstorm doc generation**

Create `plugins/interject/tests/test_outputs.py`:
```python
"""Tests for the output pipeline."""

import tempfile
from pathlib import Path

import pytest

from interject.outputs import OutputPipeline


@pytest.fixture
def pipeline(tmp_path):
    return OutputPipeline(
        docs_root=tmp_path / "docs",
        interverse_root=tmp_path,
    )


@pytest.fixture
def high_discovery():
    return {
        "id": "ij-test-1",
        "source": "github",
        "source_id": "test-repo",
        "title": "Amazing MCP Server for Code Analysis",
        "summary": "A new tool that analyzes code using AST parsing.",
        "url": "https://github.com/example/mcp-analyzer",
        "raw_metadata": '{"stars": 150, "language": "Python"}',
        "relevance_score": 0.92,
        "confidence_tier": "high",
        "discovered_at": "2026-02-15",
    }


class TestBrainstormDoc:
    def test_high_tier_creates_brainstorm(self, pipeline, high_discovery, tmp_path):
        """High tier should create a brainstorm doc in Clavain format."""
        result = pipeline.process(high_discovery, "high")
        brainstorm_path = result.get("brainstorm_path")
        assert brainstorm_path is not None
        content = Path(brainstorm_path).read_text()
        assert "## What We're Building" in content
        assert high_discovery["title"] in content

    def test_medium_tier_creates_briefing_only(self, pipeline, high_discovery, tmp_path):
        """Medium tier creates briefing but no brainstorm."""
        result = pipeline.process(high_discovery, "medium")
        assert result.get("brainstorm_path") is None
        assert result.get("briefing_path") is not None

    def test_low_tier_no_output(self, pipeline, high_discovery, tmp_path):
        """Low tier creates no files."""
        result = pipeline.process(high_discovery, "low")
        assert result.get("briefing_path") is None
        assert result.get("brainstorm_path") is None


class TestDigest:
    def test_generate_digest(self, pipeline, tmp_path):
        """Digest groups discoveries by category."""
        discoveries = [
            {"title": "Tool A", "source": "github", "relevance_score": 0.7,
             "confidence_tier": "medium", "summary": "Testing tool",
             "url": "https://a.com", "discovered_at": "2026-02-15"},
            {"title": "Tool B", "source": "arxiv", "relevance_score": 0.6,
             "confidence_tier": "medium", "summary": "Analysis paper",
             "url": "https://b.com", "discovered_at": "2026-02-15"},
        ]
        path = pipeline.generate_digest(discoveries)
        assert path.exists()
        content = path.read_text()
        assert "Tool A" in content
        assert "Tool B" in content
```

**Step 2: Run tests to verify they fail**

Run: `cd plugins/interject && uv run pytest tests/test_outputs.py -v`
Expected: FAIL (brainstorm_path not implemented, generate_digest not implemented)

**Step 3: Implement brainstorm doc generation in outputs.py**

Modify `plugins/interject/src/interject/outputs.py`:

1. In `process()`, for `tier == "high"`: replace `_write_plan()` call with `_write_brainstorm()` that generates a Clavain-format brainstorm doc at `docs/brainstorms/YYYY-MM-DD-interject-<slug>-brainstorm.md`
2. Add `result["brainstorm_path"]` to the return dict
3. The brainstorm doc should include: "What We're Building" (from discovery summary), "Why This Approach" (relevance analysis + gap context), "Key Decisions" (placeholder for human review), "Source Details" (metadata)

Add `generate_digest()` method:
- Takes a list of discovery dicts
- Groups by source
- Writes `docs/research/YYYY-MM-DD-interject-digest.md` with a summary table and per-source sections

**Step 4: Run tests to verify they pass**

Run: `cd plugins/interject && uv run pytest tests/test_outputs.py -v`
Expected: All pass

**Step 5: Run full test suite**

Run: `cd plugins/interject && uv run pytest tests/ -v`
Expected: All pass

**Step 6: Commit**

```bash
cd plugins/interject
git add src/interject/outputs.py tests/test_outputs.py
git commit -m "feat: tiered output pipeline — brainstorm docs (high), digest (medium)"
```

---

### Task 4: Add feedback loop — bead lifecycle tracking

**Files:**
- Modify: `plugins/interject/src/interject/db.py` (add feedback_signals table)
- Create: `plugins/interject/src/interject/feedback.py` (feedback collector)
- Modify: `plugins/interject/src/interject/engine.py` (consume feedback signals)
- Create: `plugins/interject/tests/test_feedback.py`

**Step 1: Write failing tests**

Create `plugins/interject/tests/test_feedback.py`:
```python
"""Tests for the feedback loop."""

import tempfile
from pathlib import Path
from unittest.mock import patch, MagicMock

import pytest

from interject.db import InterjectDB
from interject.feedback import FeedbackCollector


@pytest.fixture
def db():
    with tempfile.TemporaryDirectory() as tmpdir:
        db = InterjectDB(Path(tmpdir) / "test.db")
        db.connect()
        yield db
        db.close()


class TestFeedbackCollector:
    def test_collect_bead_lifecycle(self, db):
        """Track bead from created to shipped."""
        collector = FeedbackCollector(db)
        # Insert a promoted discovery
        db.insert_discovery(
            id="ij-test-1", source="github", source_id="t1",
            title="Test Tool", relevance_score=0.8, confidence_tier="high",
        )
        db.record_promotion("ij-test-1", "iv-abc", 2)

        # Simulate bead reaching "shipped" state
        collector.record_bead_outcome("iv-abc", "shipped")
        signals = db.get_feedback_signals("ij-test-1")
        assert any(s["signal_type"] == "bead_shipped" for s in signals)

    def test_collect_query_pattern(self, db):
        """Record MCP query topics for cross-session detection."""
        collector = FeedbackCollector(db)
        collector.record_query("MCP servers for testing", session_id="sess-1")
        collector.record_query("MCP servers for testing", session_id="sess-2")
        patterns = collector.get_repeated_queries(min_sessions=2)
        assert len(patterns) >= 1

    def test_source_conversion_rate(self, db):
        """Calculate conversion rate per source."""
        collector = FeedbackCollector(db)
        # Insert discoveries from two sources
        for i in range(10):
            db.insert_discovery(
                id=f"ij-gh-{i}", source="github", source_id=f"gh{i}",
                title=f"GH {i}", relevance_score=0.7,
            )
        for i in range(10):
            db.insert_discovery(
                id=f"ij-hn-{i}", source="hackernews", source_id=f"hn{i}",
                title=f"HN {i}", relevance_score=0.6,
            )
        # Promote and ship some github discoveries
        for i in range(3):
            db.record_promotion(f"ij-gh-{i}", f"iv-gh-{i}", 2)
        collector.record_bead_outcome("iv-gh-0", "shipped")
        collector.record_bead_outcome("iv-gh-1", "shipped")

        rates = collector.get_source_conversion_rates()
        assert rates["github"]["shipped"] == 2
        assert rates["github"]["promoted"] == 3
```

**Step 2: Run tests to verify they fail**

Run: `cd plugins/interject && uv run pytest tests/test_feedback.py -v`
Expected: FAIL (no module named interject.feedback)

**Step 3: Add feedback_signals table to db.py**

In `plugins/interject/src/interject/db.py`, add to `SCHEMA_SQL`:
```sql
CREATE TABLE IF NOT EXISTS feedback_signals (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    discovery_id TEXT REFERENCES discoveries(id),
    signal_type TEXT NOT NULL,
    signal_data TEXT NOT NULL DEFAULT '{}',
    session_id TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_feedback_discovery ON feedback_signals(discovery_id);
CREATE INDEX IF NOT EXISTS idx_feedback_type ON feedback_signals(signal_type);

CREATE TABLE IF NOT EXISTS query_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    query_text TEXT NOT NULL,
    query_embedding BLOB,
    session_id TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
```

Add methods: `insert_feedback_signal()`, `get_feedback_signals()`, `insert_query_log()`, `get_query_log()`.

Bump `SCHEMA_VERSION` to 2. Add migration logic in `_init_schema()` to create new tables if upgrading from v1.

**Step 4: Implement FeedbackCollector**

Create `plugins/interject/src/interject/feedback.py`:
```python
"""Feedback collector — closed-loop learning from bead lifecycle and session queries."""

from __future__ import annotations

import json
import logging
import subprocess
from typing import Any

from .db import InterjectDB

logger = logging.getLogger(__name__)


class FeedbackCollector:
    """Collects feedback signals to improve the recommendation engine."""

    def __init__(self, db: InterjectDB):
        self.db = db

    def record_bead_outcome(self, bead_id: str, outcome: str) -> None:
        """Record a bead lifecycle event (planned, executing, shipped, abandoned).

        Finds the discovery that created this bead and records a signal.
        """
        # Look up which discovery created this bead
        promotions = self.db.get_promotions(limit=1000)
        for p in promotions:
            if p["bead_id"] == bead_id:
                self.db.insert_feedback_signal(
                    discovery_id=p["discovery_id"],
                    signal_type=f"bead_{outcome}",
                    signal_data=json.dumps({"bead_id": bead_id, "outcome": outcome}),
                )
                return

    def record_query(self, query_text: str, session_id: str = "") -> None:
        """Record an MCP query for cross-session pattern detection."""
        self.db.insert_query_log(query_text, session_id=session_id)

    def get_repeated_queries(self, min_sessions: int = 2) -> list[dict]:
        """Find query topics that appear across multiple sessions."""
        entries = self.db.get_query_log()
        # Group by normalized query text
        query_sessions: dict[str, set[str]] = {}
        for entry in entries:
            key = entry["query_text"].lower().strip()
            if key not in query_sessions:
                query_sessions[key] = set()
            if entry.get("session_id"):
                query_sessions[key].add(entry["session_id"])

        return [
            {"query": q, "session_count": len(sessions)}
            for q, sessions in query_sessions.items()
            if len(sessions) >= min_sessions
        ]

    def get_source_conversion_rates(self) -> dict[str, dict[str, int]]:
        """Calculate discovery-to-shipped conversion rate per source."""
        stats: dict[str, dict[str, int]] = {}
        # Count total discoveries per source
        db_stats = self.db.get_stats()
        for source, count in db_stats.get("by_source", {}).items():
            stats[source] = {"total": count, "promoted": 0, "shipped": 0}

        # Count promotions per source
        for p in self.db.get_promotions(limit=10000):
            disc = self.db.get_discovery(p["discovery_id"])
            if disc:
                source = disc["source"]
                if source in stats:
                    stats[source]["promoted"] += 1

        # Count shipped signals per source
        # Query feedback_signals for bead_shipped
        for source in stats:
            shipped = self.db.conn.execute(
                """SELECT COUNT(DISTINCT fs.discovery_id)
                   FROM feedback_signals fs
                   JOIN discoveries d ON fs.discovery_id = d.id
                   WHERE fs.signal_type = 'bead_shipped' AND d.source = ?""",
                (source,),
            ).fetchone()[0]
            stats[source]["shipped"] = shipped

        return stats

    def scan_bead_updates(self) -> int:
        """Scan bd CLI for bead lifecycle updates. Returns count of new signals."""
        count = 0
        promotions = self.db.get_promotions(limit=1000)
        bead_ids = {p["bead_id"] for p in promotions if p["bead_id"]}

        for bead_id in bead_ids:
            try:
                result = subprocess.run(
                    ["bd", "show", bead_id],
                    capture_output=True, text=True, timeout=5,
                )
                if result.returncode != 0:
                    continue
                output = result.stdout.lower()
                # Check if bead is closed/shipped
                if "status: closed" in output or "status: done" in output:
                    # Check if we already recorded this
                    disc_id = next(
                        (p["discovery_id"] for p in promotions if p["bead_id"] == bead_id),
                        None,
                    )
                    if disc_id:
                        existing = self.db.get_feedback_signals(disc_id)
                        if not any(s["signal_type"] == "bead_shipped" for s in existing):
                            self.record_bead_outcome(bead_id, "shipped")
                            count += 1
            except (subprocess.TimeoutExpired, FileNotFoundError):
                continue

        return count
```

**Step 5: Run tests to verify they pass**

Run: `cd plugins/interject && uv run pytest tests/test_feedback.py -v`
Expected: All pass

**Step 6: Commit**

```bash
cd plugins/interject
git add src/interject/db.py src/interject/feedback.py tests/test_feedback.py
git commit -m "feat: feedback loop — bead lifecycle tracking, query log, conversion rates"
```

---

### Task 5: Integrate feedback into the recommendation engine

**Files:**
- Modify: `plugins/interject/src/interject/engine.py` (add source conversion weighting)
- Modify: `plugins/interject/src/interject/scanner.py` (run feedback scan after main scan)
- Modify: `plugins/interject/tests/test_engine.py` (add feedback-based scoring tests)

**Step 1: Write failing tests**

Add to `plugins/interject/tests/test_engine.py`:
```python
class TestFeedbackScoring:
    def test_source_weight_from_conversion(self, engine, db):
        """Sources with higher conversion rates should score higher."""
        # Set up conversion data via feedback signals
        db.insert_discovery(
            id="ij-gh-1", source="github", source_id="gh1", title="GH Tool",
            relevance_score=0.7,
        )
        db.record_promotion("ij-gh-1", "iv-1", 2)
        db.insert_feedback_signal(
            discovery_id="ij-gh-1",
            signal_type="bead_shipped",
            signal_data='{"bead_id": "iv-1"}',
        )
        engine.update_source_weights_from_feedback()
        profile = db.get_profile()
        gh_weight = profile.get("source_weights", {}).get("github", 1.0)
        assert gh_weight > 1.0
```

**Step 2: Run test to verify it fails**

Run: `cd plugins/interject && uv run pytest tests/test_engine.py::TestFeedbackScoring -v`
Expected: FAIL

**Step 3: Add `update_source_weights_from_feedback()` to engine.py**

In `plugins/interject/src/interject/engine.py`, add method:
```python
def update_source_weights_from_feedback(self) -> None:
    """Adjust source weights based on conversion rates from feedback signals."""
    from .feedback import FeedbackCollector
    collector = FeedbackCollector(self.db)
    rates = collector.get_source_conversion_rates()

    profile = self.db.get_profile()
    source_weights = profile.get("source_weights", {})

    for source, data in rates.items():
        promoted = data.get("promoted", 0)
        shipped = data.get("shipped", 0)
        if promoted >= 3:  # Need enough data
            conversion = shipped / promoted if promoted > 0 else 0
            # Blend conversion signal with existing weight
            current = source_weights.get(source, 1.0)
            # High conversion → boost, low conversion → dampen
            adjustment = 0.1 * (conversion - 0.3)  # 0.3 is baseline
            source_weights[source] = max(0.3, min(2.0, current + adjustment))

    self.db.update_profile(source_weights=source_weights)
```

**Step 4: Wire feedback scan into scanner.py**

In `plugins/interject/src/interject/scanner.py`, in `scan_all()`, after `self.engine.adapt_thresholds()`:
```python
# Scan for bead lifecycle updates
from .feedback import FeedbackCollector
collector = FeedbackCollector(self.db)
feedback_count = collector.scan_bead_updates()
if feedback_count > 0:
    logger.info("Recorded %d new feedback signals", feedback_count)
    self.engine.update_source_weights_from_feedback()
results["feedback_signals"] = feedback_count
```

**Step 5: Run tests to verify they pass**

Run: `cd plugins/interject && uv run pytest tests/ -v`
Expected: All pass

**Step 6: Commit**

```bash
cd plugins/interject
git add src/interject/engine.py src/interject/scanner.py tests/test_engine.py
git commit -m "feat: feedback-driven scoring — conversion rates adjust source weights"
```

---

### Task 6: Add internal awareness — plans, beads, and interwatch signals

**Files:**
- Modify: `plugins/interject/src/interject/gaps.py` (extend to read plans, beads, brainstorms)
- Create: `plugins/interject/src/interject/awareness.py` (internal state reader)
- Modify: `plugins/interject/src/interject/scanner.py` (use awareness for context)
- Create: `plugins/interject/tests/test_awareness.py`

**Step 1: Write failing tests**

Create `plugins/interject/tests/test_awareness.py`:
```python
"""Tests for internal awareness module."""

import tempfile
from pathlib import Path

import pytest

from interject.awareness import InternalAwareness


@pytest.fixture
def docs_root(tmp_path):
    plans = tmp_path / "docs" / "plans"
    plans.mkdir(parents=True)
    brainstorms = tmp_path / "docs" / "brainstorms"
    brainstorms.mkdir(parents=True)
    return tmp_path


class TestPlanAwareness:
    def test_reads_active_plans(self, docs_root):
        plan = docs_root / "docs" / "plans" / "2026-02-15-test-plan.md"
        plan.write_text("# Test Plan\n\n**Goal:** Build a testing framework\n")
        awareness = InternalAwareness(interverse_root=docs_root)
        topics = awareness.get_active_topics()
        assert any("test" in t.lower() for t in topics)

    def test_reads_brainstorms(self, docs_root):
        bs = docs_root / "docs" / "brainstorms" / "2026-02-15-search-brainstorm.md"
        bs.write_text("# Search Infrastructure\n\nExploring semantic search.\n")
        awareness = InternalAwareness(interverse_root=docs_root)
        topics = awareness.get_active_topics()
        assert any("search" in t.lower() for t in topics)

    def test_no_plans_returns_empty(self, docs_root):
        awareness = InternalAwareness(interverse_root=docs_root)
        topics = awareness.get_active_topics()
        assert isinstance(topics, list)


class TestBeadAwareness:
    def test_get_active_bead_topics(self, docs_root):
        """Should extract topics from active beads (mocked)."""
        awareness = InternalAwareness(interverse_root=docs_root)
        # Just verify it returns a list without crashing
        # (bd may not be available in test env)
        topics = awareness.get_bead_topics()
        assert isinstance(topics, list)
```

**Step 2: Run tests to verify they fail**

Run: `cd plugins/interject && uv run pytest tests/test_awareness.py -v`
Expected: FAIL

**Step 3: Implement InternalAwareness**

Create `plugins/interject/src/interject/awareness.py`:
```python
"""Internal awareness — reads plans, beads, and brainstorms to understand active work."""

from __future__ import annotations

import logging
import re
import subprocess
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)


class InternalAwareness:
    """Reads internal project state to provide context for discovery scoring."""

    def __init__(self, interverse_root: Path | None = None):
        self.root = interverse_root or Path("/root/projects/Interverse")

    def get_active_topics(self) -> list[str]:
        """Extract topic strings from active plans and brainstorms."""
        topics: list[str] = []
        topics.extend(self._topics_from_plans())
        topics.extend(self._topics_from_brainstorms())
        return topics

    def get_bead_topics(self) -> list[str]:
        """Extract topic strings from open beads via bd CLI."""
        try:
            result = subprocess.run(
                ["bd", "list", "--status=open", "--format=json"],
                capture_output=True, text=True, timeout=5,
                cwd=str(self.root),
            )
            if result.returncode != 0:
                return []

            import json
            beads = json.loads(result.stdout) if result.stdout.strip() else []
            return [b.get("title", "") for b in beads if b.get("title")]
        except (subprocess.TimeoutExpired, FileNotFoundError, Exception):
            return []

    def get_suppression_topics(self) -> list[str]:
        """Topics from shipped/closed work — discoveries matching these should be deprioritized."""
        try:
            result = subprocess.run(
                ["bd", "list", "--status=closed", "--format=json"],
                capture_output=True, text=True, timeout=5,
                cwd=str(self.root),
            )
            if result.returncode != 0:
                return []

            import json
            beads = json.loads(result.stdout) if result.stdout.strip() else []
            return [b.get("title", "") for b in beads if b.get("title")]
        except (subprocess.TimeoutExpired, FileNotFoundError, Exception):
            return []

    def _topics_from_plans(self) -> list[str]:
        """Extract goal lines from plan docs."""
        plans_dir = self.root / "docs" / "plans"
        if not plans_dir.exists():
            return []

        topics = []
        for plan in sorted(plans_dir.glob("*.md"), reverse=True)[:10]:  # Recent 10
            try:
                text = plan.read_text()[:1000]
                # Extract title
                title_match = re.search(r"^# (.+)$", text, re.MULTILINE)
                if title_match:
                    topics.append(title_match.group(1).strip())
                # Extract goal
                goal_match = re.search(r"\*\*Goal:\*\*\s*(.+)$", text, re.MULTILINE)
                if goal_match:
                    topics.append(goal_match.group(1).strip())
            except OSError:
                continue
        return topics

    def _topics_from_brainstorms(self) -> list[str]:
        """Extract titles from brainstorm docs."""
        bs_dir = self.root / "docs" / "brainstorms"
        if not bs_dir.exists():
            return []

        topics = []
        for bs in sorted(bs_dir.glob("*.md"), reverse=True)[:10]:
            try:
                text = bs.read_text()[:500]
                title_match = re.search(r"^# (.+)$", text, re.MULTILINE)
                if title_match:
                    topics.append(title_match.group(1).strip())
            except OSError:
                continue
        return topics
```

**Step 4: Wire into scanner.py**

In `plugins/interject/src/interject/scanner.py`, in `scan_all()`, after loading adapters:
```python
# Internal awareness — boost/suppress based on active work
from .awareness import InternalAwareness
awareness = InternalAwareness(self.interverse_root)
active_topics = awareness.get_active_topics() + awareness.get_bead_topics()
suppression_topics = awareness.get_suppression_topics()
```

Pass `active_topics` as additional seed topics and use `suppression_topics` to lower scores for discoveries that match already-shipped work.

**Step 5: Run tests to verify they pass**

Run: `cd plugins/interject && uv run pytest tests/ -v`
Expected: All pass

**Step 6: Commit**

```bash
cd plugins/interject
git add src/interject/awareness.py src/interject/gaps.py src/interject/scanner.py tests/test_awareness.py
git commit -m "feat: internal awareness — reads plans, beads, brainstorms for context"
```

---

### Task 7: Enhance session hook with topic-aware context injection

**Files:**
- Modify: `plugins/interject/hooks/session-start.sh` (add topic matching)
- Modify: `plugins/interject/src/interject/server.py` (add MCP tool for session context)

**Step 1: Add `interject_session_context` MCP tool**

In `plugins/interject/src/interject/server.py`, add a new tool:
```python
@mcp.tool()
async def interject_session_context(topic: str = "") -> str:
    """Get discoveries relevant to the current session's topic.

    Unlike interject_inbox (which shows globally highest-scoring),
    this matches against the provided topic text.
    """
    if not topic:
        return "No topic provided. Use interject_inbox for global top discoveries."

    embedding = embedder.embed(topic)
    # Query all new discoveries
    discoveries = db.list_discoveries(status="new", limit=100)
    scored = []
    for d in discoveries:
        if d.get("embedding"):
            vec = bytes_to_vector(d["embedding"])
            sim = embedder.cosine_similarity(embedding, vec)
            if sim > 0.3:
                scored.append((sim, d))

    scored.sort(key=lambda x: x[0], reverse=True)
    if not scored:
        return "No relevant discoveries for this topic."

    lines = [f"Discoveries relevant to: {topic[:80]}"]
    for sim, d in scored[:5]:
        lines.append(f"- [{d['source']}] {d['title']} (relevance: {sim:.2f})")
        lines.append(f"  {d.get('url', '')}")
    return "\n".join(lines)
```

**Step 2: Update session hook to record query**

Modify `plugins/interject/hooks/session-start.sh` — after displaying inbox items, record the session start as a query log entry so cross-session pattern detection can work. Add at the end:
```bash
# Record session start for cross-session pattern detection
SESSION_ID=$(echo "$SESSION_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")
if [[ -n "$SESSION_ID" ]]; then
    sqlite3 "$INTERJECT_DB" \
        "INSERT INTO query_log (query_text, session_id) VALUES ('session_start', '$SESSION_ID')" \
        2>/dev/null || true
fi
```

**Step 3: Run MCP server smoke test**

Run: `cd plugins/interject && timeout 5 uv run interject-mcp 2>&1 || true`
Expected: Server starts without errors (may timeout waiting for stdin, that's fine)

**Step 4: Commit**

```bash
cd plugins/interject
git add src/interject/server.py hooks/session-start.sh
git commit -m "feat: session-aware context injection — topic-matched discovery surfacing"
```

---

### Task 8: Update CLAUDE.md, AGENTS.md, and register intersearch

**Files:**
- Modify: `plugins/interject/CLAUDE.md` (update key files, add integration docs)
- Modify: `plugins/intersearch/CLAUDE.md` (create)
- Modify: `/root/projects/Interverse/CLAUDE.md` (add intersearch to structure)
- Modify: `/root/projects/Interverse/AGENTS.md` (add intersearch, update interject description)

**Step 1: Update interject CLAUDE.md**

Update `plugins/interject/CLAUDE.md` to reflect new modules: feedback.py, awareness.py, intersearch dependency, and the enhanced output pipeline.

**Step 2: Create intersearch CLAUDE.md**

```markdown
# intersearch

Shared search and embedding infrastructure for the Interverse ecosystem.

## Overview

Pure library — 0 skills, 0 commands, 0 agents, 0 hooks, 0 MCP servers. Provides `intersearch.exa` (semantic web search) and `intersearch.embeddings` (text embedding client). Used by interject and interflux.

## Key Files

- `src/intersearch/exa.py` — Exa semantic search client (search, multi_search)
- `src/intersearch/embeddings.py` — Embedding client (all-MiniLM-L6-v2, 384 dims)
```

**Step 3: Update Interverse CLAUDE.md and AGENTS.md**

Add `plugins/intersearch/` to the structure listing and update interject's description to mention integrations.

**Step 4: Commit**

```bash
# In interject repo
cd plugins/interject && git add CLAUDE.md && git commit -m "docs: update CLAUDE.md with integration modules"

# In intersearch repo
cd plugins/intersearch && git add CLAUDE.md && git commit -m "docs: add CLAUDE.md"

# In Interverse root
cd /root/projects/Interverse && git add CLAUDE.md AGENTS.md && git commit -m "docs: register intersearch, update interject description"
```

---

### Task 9: Final integration test — end-to-end scan with all integrations

**Files:**
- No new files — this is a verification task

**Step 1: Install intersearch locally**

Run: `cd plugins/intersearch && uv pip install -e .`

**Step 2: Reinstall interject with intersearch dependency**

Run: `cd plugins/interject && uv pip install -e .`

**Step 3: Run full scan with feedback + awareness**

Run: `cd plugins/interject && uv run interject-scan`
Expected:
- All 5 adapters load
- Exa uses intersearch (check logs for `intersearch.exa` logger)
- Feedback scan runs after main scan
- No errors

**Step 4: Run full test suite across both packages**

Run:
```bash
cd plugins/intersearch && uv run pytest tests/ -v
cd plugins/interject && uv run pytest tests/ -v
```
Expected: All tests pass in both packages

**Step 5: Push all repos**

```bash
cd plugins/intersearch && git push
cd plugins/interject && git push
cd /root/projects/Interverse && git push
```
