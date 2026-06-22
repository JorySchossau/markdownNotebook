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

proc sigSidecarPath(sourceFile: string): string =
  ## Path of the command-signature sidecar for `sourceFile`: `<source>.mdnbsig`,
  ## sitting next to the source so `:clean` (which removes files mdnb knows about)
  ## does NOT sweep it (only generated sources/outputs are enumerated). It is a
  ## cache of the command signature that produced the current source file, used by
  ## `markDirtyCells` to detect command edits independent of body changes.
  sourceFile & ".mdnbsig"

proc sigSidecar(sourceFile: string): string =
  ## Read the recorded command signature for `sourceFile`, or "" if absent (first
  ## run, or after `:clean`). Returns "" rather than throwing on any IO error so a
  ## missing/unreadable sidecar is treated uniformly as "no prior signature" →
  ## dirty (the safe over-approximation).
  try: readFile(sigSidecarPath(sourceFile))
  except CatchableError: ""

proc writeSigSidecar(sourceFile, sig: string) =
  ## Persist `sig` as the command signature that produced `sourceFile`. Uses the
  ## retrying `safeWriteFile` so a transient IO failure doesn't abort the run; a
  ## failed write just means the next pass re-runs (the safe direction).
  sigSidecarPath(sourceFile).safeWriteFile(sig)
