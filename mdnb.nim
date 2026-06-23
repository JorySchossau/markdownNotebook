## mdnb — Markdown Notebook. Entry point only: one logical module split into section files via `include` in topological order (definitions before uses). See README.md / agents.md.
import std/[strutils, sequtils, pegs, tables, sets, os, strformat, osproc, times, streams, hashes]

include mdnb_grammar
include mdnb_types
include mdnb_io
include mdnb_parse_commands
include mdnb_parse
include mdnb_shortcuts
include mdnb_imagecache
include mdnb_run
include mdnb_pipeline
include mdnb_cli

## ==============

when isMainModule:
  main()
