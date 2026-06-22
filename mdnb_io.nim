## Safe IO primitives: retry-loop wrappers around file IO that never throw (they
## swallow errors and retry). The read-side sibling `getLastModTime` lives in
## `mdnb_cli.nim` since it has a single caller there; this file holds the
## general-purpose write helpers used by the execution layer and the pipeline.
## See agents.md §9 for the gotcha that these retry forever.
proc safeWriteFile(filename, contents: string) =
  var error = true
  while error:
    try:
      writeFile(filename, contents)
      error = false
    except CatchableError:
      discard

proc tryRemoveFile(filename: string) =
  ## Remove a file if it exists, swallowing errors (an already-deleted file or a
  ## permissions error should not abort the pipeline). Used by `:clean` to wipe
  ## generated source/output files, including ephemeral bare-block cache files.
  try:
    if fileExists(filename): removeFile(filename)
  except CatchableError:
    discard

proc write(md: MarkdownFile) = md.filename.safeWriteFile(md.buf[])
