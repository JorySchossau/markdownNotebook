## Safe IO primitives: retry-loop wrappers around file IO that never throw (agents.md §9 gotcha: they retry forever).

var verbose: bool            ## set by `-v`/`--verbose`; gates per-run status logging (declared here — read from both `mdnb_imagecache` and `mdnb_run`, which both precede `mdnb_cli` where it's set).

proc safeWriteFile(filename, contents: string) =
  var error = true
  while error:
    try:
      writeFile(filename, contents)
      error = false
    except CatchableError:
      discard

proc tryRemoveFile(filename: string) =
  ## Remove a file if it exists, swallowing errors; used by `:clean` to wipe generated source/output files including ephemeral cache files.
  try:
    if fileExists(filename): removeFile(filename)
  except CatchableError:
    discard

proc write(md: MarkdownFile) = md.filename.safeWriteFile(md.buf[])

proc sigSidecarPath(sourceFile: string): string =
  ## `<source>.mdnbsig`: the command-signature sidecar, beside the source so `:clean` does NOT sweep it.
  sourceFile & ".mdnbsig"

proc sigSidecar(sourceFile: string): string =
  ## The recorded command signature for `sourceFile`, or "" if absent/unreadable (treated as "no prior signature" -> dirty).
  try: readFile(sigSidecarPath(sourceFile))
  except CatchableError: ""

proc writeSigSidecar(sourceFile, sig: string) =
  ## Persist `sig` as the command signature that produced `sourceFile` (via retrying `safeWriteFile`; a failed write just means the next pass re-runs).
  sigSidecarPath(sourceFile).safeWriteFile(sig)
