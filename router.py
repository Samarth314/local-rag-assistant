"""Back-compat shim: the heuristic tier-router moved into `routing.py` (the
dependency-free graduation module). Kept so existing imports
(`from router import heuristic_route`) keep working. New code should import
from `routing` directly."""

from routing import heuristic_route  # noqa: F401

__all__ = ["heuristic_route"]
