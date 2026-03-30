# AI and Machine Learning Workloads

Use when evaluating Valkey for AI/ML use cases - vector search for RAG, semantic caching for LLM responses, session stores for AI agents, or feature stores for ML pipelines.

---

## Valkey's Position in the AI Stack

Valkey serves as a high-performance in-memory layer for AI/ML applications. Its
sub-millisecond latency and support for vector similarity search via the
valkey-search module make it suitable for
several roles in modern AI architectures:

| Role | How Valkey Fits |
|------|----------------|
| Vector store for RAG | valkey-search with HNSW/KNN indexes |
| Semantic cache for LLMs | Store prompt embeddings + cached responses |
| Session/memory store for AI agents | Persist conversation state across sessions |
| Feature store for ML pipelines | Low-latency feature serving at inference time |
| Rate limiter for API calls | Token bucket / sliding window for LLM API usage |

## Vector Store for RAG

The **valkey-search** module provides vector similarity search that can serve as the retrieval backend in Retrieval-Augmented Generation (RAG) pipelines.

### How It Works

1. Generate embeddings for your documents using an embedding model (OpenAI, Cohere, local models)
2. Store embeddings in Valkey Hash or JSON fields with a vector index
3. At query time, embed the user's question and run a nearest-neighbor search
4. Feed the top-K results as context into the LLM prompt

### Creating a Vector Index

```
FT.CREATE doc_idx ON HASH PREFIX 1 doc:
  SCHEMA
    content TEXT
    embedding VECTOR HNSW 6
      TYPE FLOAT32 DIM 1536 DISTANCE_METRIC COSINE
```

### Querying

```
FT.SEARCH doc_idx "*=>[KNN 5 @embedding $query_vec AS score]"
  PARAMS 2 query_vec <binary_blob>
  SORTBY score
  RETURN 2 content score
```

### Performance Characteristics

valkey-search achieves single-digit millisecond latency with over 99% recall. It supports billions of vectors and scales linearly with CPU cores. Two index types are available:

- **HNSW** - Approximate Nearest Neighbor, best for large-scale search with high recall
- **FLAT** - Exact K-Nearest Neighbors, best for smaller datasets or when exact results are required

### Hybrid Queries

valkey-search supports filtering during vector search - combining vector similarity with tag, numeric, or full-text filters. The query planner automatically selects between pre-filtering and inline-filtering for optimal performance.

## Semantic Caching for LLM Responses

Semantic caching stores LLM responses keyed by the semantic meaning of the prompt rather than exact string matching. This reduces redundant LLM API calls for semantically similar questions.

### Pattern

1. Embed the incoming prompt
2. Search Valkey for similar cached prompts (cosine similarity above threshold)
3. If a match is found, return the cached response - no LLM call needed
4. If no match, call the LLM, then cache both the prompt embedding and response

### Implementation Sketch

```python
# Using valkey-py with valkey-search
import numpy as np

def get_or_generate(prompt, threshold=0.95):
    embedding = embed_model.encode(prompt)
    # Search for semantically similar cached prompts
    results = client.ft("cache_idx").search(
        f"*=>[KNN 1 @embedding $vec AS score]",
        query_params={"vec": embedding.tobytes()}
    )
    if results.total and float(results.docs[0].score) >= threshold:
        return client.hget(results.docs[0].id, "response")
    # Cache miss - call LLM
    response = llm.generate(prompt)
    doc_id = f"cache:{hash(prompt)}"
    client.hset(doc_id, mapping={
        "prompt": prompt,
        "response": response,
        "embedding": embedding.tobytes()
    })
    return response
```

The **valkey-bundle-demo** project (valkey-io/valkey-bundle-demo) demonstrates this pattern in a full e-commerce application, showing how LLM response caching with Valkey dramatically reduces latency for personalized product descriptions.

## Session and Memory Store for AI Agents

Valkey is well-suited as a persistence layer for AI agent memory - conversation history, tool call results, and cross-session state.

### Use Cases

- **Conversation history** - Store chat turns in a Valkey List or Stream, with TTL for automatic expiration
- **Cross-session memory** - Persist agent memory that survives context window limits and session restarts
- **Tool call caching** - Cache results of expensive tool calls (API lookups, database queries) for reuse
- **Shared state** - Multiple agents or agent instances can share state via Valkey

### Ecosystem Integrations

| Project | Description |
|---------|-------------|
| [Recall](https://github.com/joseairosa/recall) | Persistent cross-session memory for Claude and AI agents, backed by Valkey. Self-host or use managed SaaS (recallmcp.com) |
| [Cognee](https://github.com/topoteretes/cognee) | AI memory system with Valkey vector database adapter |
| [Mem0](https://docs.mem0.ai/components/vectordbs/dbs/valkey) | Universal memory layer for AI agents with Valkey vector store adapter using HNSW/FLAT indexing |

### MCP Servers

Model Context Protocol (MCP) servers provide AI agents with structured access to Valkey:

| Server | Description |
|--------|-------------|
| [AWS MCP Server](https://github.com/awslabs/mcp) | Official AWS MCP suite with Valkey/ElastiCache access |
| [Valkey MCP Task Management](https://github.com/jbrinkman/valkey-ai-tasks) | Task management for AI agents with Valkey persistence |

## Feature Store for ML Pipelines

Valkey can serve as a low-latency online feature store for ML model inference. Features computed in batch pipelines are loaded into Valkey and served at prediction time with sub-millisecond reads.

### Pattern

- **Batch pipeline** writes feature vectors to Valkey Hashes (one hash per entity)
- **Inference service** reads features by entity ID at prediction time
- **TTL** ensures stale features expire automatically
- **Hashes** allow atomic reads of all features for an entity in a single `HGETALL`

This pattern avoids the latency of database lookups during inference while keeping features fresh through periodic batch updates.

## valkey-bundle

The [valkey-bundle](https://github.com/valkey-io/valkey-bundle)
packages valkey-server with all official modules (valkey-search, valkey-json,
valkey-bloom) into a single installable unit. For AI workloads, this is the
simplest way to get vector search, JSON storage, and Bloom filters in one
deployment.

## AI Framework Integrations

| Framework | Valkey Integration |
|-----------|-------------------|
| [Haystack](https://github.com/deepset-ai/haystack-core-integrations/tree/main/integrations/valkey) | Document store and retriever for RAG pipelines |
| LangChain | Compatible via redis vectorstore (uses RESP protocol) |
| LlamaIndex | Compatible via redis vector store integration |

The Haystack integration is the most mature, with a dedicated `valkey` integration package in the haystack-core-integrations repository.

## Google Memorystore for Valkey

Google Cloud Memorystore offers a managed Valkey service with built-in vector search support. It uses the same valkey-search module API, so applications using `FT.CREATE` and `FT.SEARCH` locally work without modification on Memorystore.

See `../services/comparison.md` for managed service details across AWS, GCP, and other providers.

## valkey-bundle-demo

The [valkey-bundle-demo](https://github.com/valkey-io/valkey-bundle-demo) is a complete reference application demonstrating AI-powered e-commerce with Valkey. It showcases:

- **Hybrid search** - Combining keyword (tag) filtering with vector similarity
- **Personalization** - User profile embeddings for tailored search results
- **Semantic caching** - LLM response caching for reduced latency
- **Bloom filters** - Tracking viewed products efficiently
- **Multiple AI backends** - Ollama (local), Google Gemini, AWS Bedrock

Run it locally with `valkey/valkey-bundle` Docker image:

```bash
docker run -d --rm --name valkey-bundle-demo -p 6379:6379 valkey/valkey-bundle
```

## Valkey-Samples (Awesome List)

The [Valkey-Samples](https://github.com/valkey-io/Valkey-Samples) repository is the official curated list of resources for using Valkey in the AI ecosystem. It includes:

- MCP servers for AI agent integration
- Real-world integrations (Recall, Cognee, Haystack, Mem0)
- Tutorials and video guides
- Cloud platform deployment guides

This is the best starting point for discovering community-built AI integrations with Valkey.

## When to Use Valkey vs Dedicated Vector Databases

| Factor | Valkey | Dedicated Vector DB (Pinecone, Weaviate, etc.) |
|--------|--------|------------------------------------------------|
| Latency | Sub-millisecond | Low milliseconds |
| Existing Valkey deployment | Extend what you have | New infrastructure |
| Dataset size | Billions of vectors (in-memory) | Disk-based, larger capacity |
| Full-text search | Supported in valkey-search | Varies by product |
| Operational complexity | One system for cache + vectors | Separate system to manage |
| Filtering | Hybrid queries with tag/numeric/text | Native metadata filtering |

Choose Valkey when you already use it for caching/sessions and want to consolidate, or when sub-millisecond latency is critical. Choose a dedicated vector DB when your dataset far exceeds available memory or you need specialized features like multi-tenancy or managed replication.

## Related Files

- [../modules/search.md](../modules/search.md) - valkey-search module details and command reference
- [../modules/overview.md](../modules/overview.md) - module system overview and valkey-bundle
- [../services/comparison.md](../services/comparison.md) - managed Valkey services with vector search
- [frameworks.md](frameworks.md) - framework integrations for application development
