## mdnb — Markdown Notebook.
##
## Literate-programming for plain Markdown: mdnb watches `.md` files, runs the
## code inside fenced blocks (per YAML-defined runtimes), and writes the output
## back into the same file. See `README.md` for the user manual and `agents.md`
## for a contributor tour.
##
## This file is the entry point only. The implementation is a single logical
## module split into navigable section files via `include` (not `import` — there
## is no encapsulation between them, they share this module's scope). The
## include order below is a topological order: it puts definitions before their
## uses. (Nim resolves forward references within a module for procs in
## expression context, but a later definition can't be reached as a
## method-call-style statement, so the include order matters here.) Roughly:
## grammar and model first, then parse, the shortcut/clean pass, the execution
## layer, then the pipeline orchestrator (which calls all of the above), and
## finally the CLI/watch loop.
import std/[strutils, sequtils, pegs, tables, sets, os, strformat, osproc, times, streams]

include mdnb_grammar
include mdnb_types
include mdnb_io
include mdnb_parse
include mdnb_shortcuts
include mdnb_run
include mdnb_pipeline
include mdnb_cli

## ==============

when isMainModule:
  main()
