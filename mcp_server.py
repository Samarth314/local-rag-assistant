"""MCP server exposing this project's document tools over stdio, so any
MCP-compatible client (Hermes Agent, Claude Desktop, etc.) can call them.

Deliberately read-only: only search_documents and list_documents are exposed.
write_note is left out on purpose -- our safety gate for it (require a prior
search, ask for human confirmation) lives in agent.py's orchestrator loop,
not in the tool itself, so it doesn't carry over to a different orchestrator
driving these tools over MCP. Add it back only after deciding how a given
MCP client's own confirmation/risk model should handle it.
"""

from mcp.server.fastmcp import FastMCP

from tools import _list_documents, _search_documents

mcp = FastMCP("local-rag-assistant")


@mcp.tool()
def search_documents(query: str) -> str:
    """Semantic search over the user's indexed local documents. Returns the
    top matching excerpts along with their source file paths."""
    return _search_documents(query)


@mcp.tool()
def list_documents() -> str:
    """List every file path currently in the document index."""
    return _list_documents()


if __name__ == "__main__":
    mcp.run()
