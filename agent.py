"""Tool-calling agent loop.

The LLM proposes one tool call at a time; we validate the arguments, look up
the tool's risk level (deterministic, not left to the model), auto-execute
low-risk calls, and ask for interactive human confirmation before high-risk
ones. The result is fed back so the model can continue, capped at MAX_TURNS
so a confused model can't loop forever.
"""

import json
import sys

import ollama

import config
from tools import RISK_LEVELS, TOOL_FUNCTIONS, TOOL_SCHEMAS

MAX_TURNS = 5

SYSTEM_PROMPT = (
    "You are a personal assistant with tools to search and read the user's local "
    "documents and save notes. Before answering any question or writing any note "
    "that involves a fact from the user's files -- a number, date, name, or quote "
    "-- you must first retrieve it with a tool. Never state a fact from the user's "
    "files from memory or a guess, even if you feel confident.\n\n"
    "Choose the right retrieval tool:\n"
    "- read_document: when the question is about ONE specific document as a whole "
    "-- summarizing it, or listing every item in it (all courses on a transcript, "
    "all points in a paper, everything in a file). Reading the whole document is "
    "far more reliable than searching for these, because search returns only a few "
    "fragments. If you don't know the exact filename, call list_documents first.\n"
    "- search_documents: when you need to FIND specific facts that could be spread "
    "across many documents (a rate, a definition, who said what).\n"
    "- list_documents: to find a file's exact name -- pass a 'filter' substring "
    "(e.g. list_documents with filter 'resume') rather than listing everything; "
    "the index can be large.\n\n"
    "Call one tool at a time and wait for its result. Once you have enough "
    "information, answer the user directly without calling another tool."
)


def _run_tool(name: str, args: dict) -> str:
    if name not in TOOL_FUNCTIONS:
        return f"Error: unknown tool '{name}'"
    try:
        return TOOL_FUNCTIONS[name](**args)
    except TypeError as e:
        return f"Error: invalid arguments for {name} -- {e}"


def _confirm(name: str, args: dict) -> bool:
    print(f"\n[confirmation required] Agent wants to call {name}({args})")
    return input("Approve? [y/N]: ").strip().lower() == "y"


def run(user_query: str) -> str:
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": user_query},
    ]
    has_retrieved = False  # enforced by the orchestrator, not left to the model's compliance

    for _ in range(MAX_TURNS):
        response = ollama.chat(
            model=config.CHAT_MODEL,
            messages=messages,
            tools=TOOL_SCHEMAS,
            options={"num_ctx": config.NUM_CTX},
        )
        message = response["message"]
        messages.append({"role": "assistant", "content": message.get("content") or "",
                          "tool_calls": message.get("tool_calls")})

        tool_calls = message.get("tool_calls")
        if not tool_calls:
            return message.get("content", "")

        for call in tool_calls:
            name = call["function"]["name"]
            args = call["function"]["arguments"]
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except json.JSONDecodeError:
                    messages.append({"role": "tool", "content": f"Error: could not parse arguments as JSON: {args}"})
                    continue

            if name == "write_note" and not has_retrieved:
                result = ("Error: you must retrieve first (search_documents or "
                           "read_document) and base this note's content on the actual "
                           "retrieved text before writing it.")
            else:
                risk = RISK_LEVELS.get(name, "high")  # unknown tools default to high risk
                if risk == "high" and not _confirm(name, args):
                    result = "User declined this action."
                else:
                    result = _run_tool(name, args)
                    if name in ("search_documents", "read_document"):
                        has_retrieved = True

            preview = result if len(result) <= 200 else result[:200] + "..."
            print(f"  -> {name}({args}): {preview}")
            messages.append({"role": "tool", "content": result})

    return "Stopped after reaching the maximum number of tool-call turns without a final answer."


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print('Usage: python agent.py "<request>"')
        sys.exit(1)

    print(run(sys.argv[1]))
