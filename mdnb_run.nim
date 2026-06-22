## Execution: build the shell command for a cell and run the dirty ones, writing
## their output to disk and back into `show:` cells. `buildCommand` handles `$1`
## substitution for compiled languages. Runs are **non-blocking**: a cell is
## launched with `osproc.startProcess` and reaped on a later watch cycle via
## `pollRuns`, so a long-running cell no longer blocks the watcher from parsing
## further saves (Tier 2 async item — see agents.md §8/§12). The `[ ]` state
## field (`s`/`r`/`x`/`k`) layers manual control on top of the dirty-driven
## auto-run default; existing notebooks keep working unchanged.
##
## Per-cell timeout (Tier 2): every launched cell is bounded by `timeout:N`
## seconds (default `defaultTimeout`, set in mdnb_types.nim). `pollRuns` checks
## each in-flight cell on every cycle and kills any that have exceeded their
## limit, writing a notice into the output file (and any matching `show:` cell)
## so the user sees what happened and why.
##
## Pipe draining (Tier 2): a cell's stdout reaches mdnb through an OS pipe whose
## buffer is tiny (~64KB). If we only read it after the process exits (the old
## behavior), any cell whose output exceeds the buffer fills it and the producer
## then *blocks* writing to a full pipe — it can never exit, so the read never
## happens, so the cell hangs until its `timeout:` kills it. `pollRuns` now
## drains each running cell's pipe on *every* cycle (`drainOutput`) into a
## per-cell accumulator, so the producer is never blocked. `readData` returns 0
## the instant the pipe is momentarily empty (it does not block on a live pipe),
## so the drain is a cheap non-blocking spin that fits the existing poll cadence;
## the accumulated output is trimmed/written on the cycle the process exits.


proc buildCommand(command, sourceFilename: string): string =
  ## Build the shell command for a cell. If `command` contains `$1`, every
  ## occurrence is replaced by `sourceFilename` with its extension stripped
  ## (e.g. `temp/demo_src1.cpp` -> `temp/demo_src1`), so compiled-language
  ## commands like `g++ -o $1.out $1.cpp && ./$1.out` work. Otherwise the
  ## source filename is appended to the command, as before.
  if "$1" in command:
    let (dir, name, _) = sourceFilename.splitFile
    command.replace("$1", dir / name)
  else:
    command & ' ' & sourceFilename

## ==============
## Non-blocking run state. The watch loop rebuilds a fresh `MarkdownFile` from
## disk on every save, so a running cell can't hold a pointer to the `md` it
## came from. Instead we keep just what's needed to (a) reap the process
## later and (b) write its captured output to disk under the cell's `output:`
## path; the matching `show:` cell is located in *whichever* `md` is current
## when the process finishes. Keyed by the source file path, which is unique
## per cell (auto-generated sources are unique per cell; explicit `source:`/
## `append:` targets are shared but a given running process still owns one).
type Running = object
  p: Process                 ## osproc handle; reaped non-blocking via peekExitCode
  filename: string           ## owning markdown file — reaps route back to its md
  language: string           ## runtime language id (for buildCommand lookup at start)
  sourceFile: string         ## the cell's source path — also our identity key
  outputFile: string         ## the cell's output: path — where captured stdout goes
  ephemeral: bool            ## bare-block cell: cwd tmp source kept as a cache, no output kept
  started: Time              ## when the cell was launched — for the per-cell timeout
  timeoutSecs: int           ## resolved per-cell timeout in seconds (default 5)
  cellId: int                ## 1-based cell ordinal at launch — for verbose status
  command: string            ## resolved shell command that ran — for verbose status
  acc: string                ## drained-so-far stdout; pipe buffer is ~64KB, so a cell
                             ## whose output exceeds it would block forever writing to a
                             ## full pipe if we only read on exit (see drainOutput).

var running: seq[Running]    ## currently-executing cell subprocesses (module-global)
var verbose: bool            ## set by `-v`/`--verbose`; gates per-run status logging

proc logRunStatus(r: Running; exitCode: int; note = "") =
  ## Verbose execution status (Tier 3): one line per completed cell run to stdout
  ## — cell id, the resolved command, exit code, and wall-clock duration. Gated on
  ## the `-v`/`--verbose` flag (set in `main`) so the default run stays quiet
  ## ("pure addition, no behavior change"). Called from every reap path: normal
  ## finish, timeout-kill, and manual `[k]`-kill. For killed cells `note` carries
  ## the reason (a post-SIGKILL `peekExitCode` is unreliable, often -1), so we
  ## print that in place of the exit code.
  if not verbose: return
  let dur = (getTime() - r.started).inMicroseconds.float / 1_000_000.0
  let tail = if note.len > 0: note else: "exit " & $exitCode
  echo &"[mdnb] {r.filename} cell {r.cellId}: '{r.command}' -> {tail} in {dur:.3f}s"

proc anyRunning(filename: string): bool =
  ## True if any in-flight cell belongs to `filename`. Used by the watch loop to
  ## decide whether a reap pass is warranted for a file that wasn't just saved.
  for r in running:
    if r.filename == filename: return true
  false

proc writeCellState(md: var MarkdownFile; idx: int; newState: char) =
  ## Splice a single new state char into this cell's `[x]` field in the info
  ## string (the fence line above the cell body). It's a 1-for-1 char swap so no
  ## downstream offset patching is needed. If the cell has no `[ ]` field (state
  ## was '\0'), there's nothing to write.
  if newState == '\0': return
  let cell = md.cells[idx]
  # `cell.rng.a` is the first body byte; the byte just before it is the `\n`
  # ending the info-string line. Scan back to that line's start (the previous
  # `\n`) and take the last `[` on it as the `[x]` field. We do NOT break on `]`
  # because we're scanning backwards and would hit the close-bracket first.
  var bracket = -1
  var i = cell.rng.a - 2
  while i >= 0 and md.buf[][i] != '\n':
    if md.buf[][i] == '[': bracket = i
    dec i
  if bracket == -1 or bracket + 2 >= md.buf[].len or md.buf[][bracket + 2] != ']':
    return # no `[ ]` field present on this cell
  md.buf[][bracket + 1] = newState
  md.write

proc showCellForOutput(md: MarkdownFile; outputFile: string): int =
  ## Index of the `show:` cell displaying `outputFile`, or -1 if none.
  for i, c in md.cells:
    if not c.properties.code and c.properties.show == outputFile:
      return i
  -1

proc cellWithSource(md: MarkdownFile; sourceFile: string): CellProperties =
  ## The `CellProperties` of the code cell that writes `sourceFile`. Used to find
  ## the `trim:` settings that should govern a `show:` cell's display of that
  ## cell's output — the producer carries the trim window so the show block
  ## doesn't have to redeclare it. Returns a default (head,50) if not found.
  for c in md.cells:
    if c.properties.code and c.properties.source == sourceFile:
      return c.properties
  CellProperties(trimLines: defaultTrimLines)

proc cellShouldRun(cell: Cell): bool =
  ## Decide whether a code cell runs this pass under the Tier 4 stopped-by-default
  ## model. The default is now **stop**: a runnable cell mdnb has injected `[s]`
  ## into (or that still has no `[ ]` field) does NOT auto-run when dirty — the
  ## user must ask for it. `markDirtyCells` still computes dirtiness and the call
  ## graph (`inputs:`/`output:`) still propagates it; a dirty cell simply *waits*
  ## in `[s]` until the user runs it (`[x]`), one of the bulk `:runall` /
  ## `:runabove` / `:runbelow` commands, or the `-o` run-once path. (`-o` does
  ## NOT go through `cellShouldRun`: it sets `runMode = rmAll`, so `runBulk` runs
  ## every cell sequentially via `runCellsSequential`, which forces `[x]` itself.)
  ## - `x` = execute: force-run regardless of dirty (the user's run trigger).
  ## - `s`/`r`/`k` = stopped / running / kill-requested: don't (re)launch.
  if not cell.properties.code: return false
  case cell.properties.state
  of 'x': return true                    # execute: force-run regardless of dirty
  of 's', 'r', 'k': return false         # stopped / running / kill-requested
  else: return false                     # '\0' (no field): stopped by default now

proc startRun(md: var MarkdownFile; idx: int) =
  ## Launch one cell's process without blocking. Writes the source file, starts
  ## the subprocess (or writes output directly for `raw`), records it in
  ## `running`, and flips the cell's state `x` -> `r` in the file.
  let cell = md.cells[idx]
  let sourceFile = cell.properties.source
  let outputFile = cell.properties.output
  let ephemeral = cell.properties.ephemeral
  sourceFile.safeWriteFile(md.sources[sourceFile])
  # Record the command signature that produced this source, so a later
  # `markDirtyCells` can tell that a command/arg/language edit happened even when
  # the body — and thus the generated source — is byte-identical. Ephemeral
  # (bare) cells fold the signature into their cache FILENAME instead (no
  # `output:`/sidecar to pair with), so they don't need this. See
  # `cellSignature` / `sigSidecar`.
  if not ephemeral:
    writeSigSidecar(sourceFile, md.sourceSigs[sourceFile])
  let language = cell.properties.language
  if language == "raw":
    # raw blocks produce no subprocess; their body IS the output. Synchronous.
    md.sources[sourceFile].strip.safeWriteFile(outputFile)
    return
  let command = buildCommand(md.runtimes[language].command, sourceFile)
  # poEvalCommand routes the command through the shell (sh -c), matching how the
  # old blocking execProcess worked — so arbitrary shell commands, pipes, and
  # PATH lookups behave exactly as before. poStdErrToStdOut captures stderr into
  # the output too (the pre-async behavior via execProcess's default options).
  let p = startProcess(command, options = {poEvalCommand, poStdErrToStdOut})
  let secs = cell.properties.timeout
  running.add Running(p: p, filename: md.filename, language: language,
                      sourceFile: sourceFile, outputFile: outputFile,
                      ephemeral: ephemeral,
                      started: getTime(), timeoutSecs: secs,
                      cellId: cell.id, command: command)
  if verbose:
    echo &"[mdnb] {md.filename} cell {cell.id}: launched '{command}' (timeout {secs}s)"
  if cell.properties.state == 'x':
    md.cells[idx].properties.state = 'r'  # keep in-memory state in sync with the
                                          # file so a caller holding this `md`
                                          # across multiple runs (the Tier 4
                                          # sequential bulk-run path) sees `r`
                                          # and `reapFinished` can flip it to `s`.
    md.writeCellState(idx, 'r')         # x -> r so the user sees it flipped

const drainChunk = 8192   ## per-call read granularity; the loop stops at an empty pipe

proc drainOutput(r: var Running) =
  ## Pull the cell's captured stdout out of its (now-finished) process's pipe
  ## into the accumulator. The OS pipe buffer is tiny (~64KB); the bulk of a
  ## large output is read here once the process has exited (pipe at EOF). Only
  ## call this on a process that has ALREADY finished (`peekExitCode != -1`) or
  ## been killed — see `pollRuns` for why draining a still-running cell would
  ## block the watcher. At EOF `readData` returns 0 and never blocks, so this
  ## reads everything the process wrote in one pass. Memory is bounded downstream
  ## by `readTrimmed` when the accumulated bytes are shown.
  let s = r.p.outputStream
  var buf: array[drainChunk, char]
  while true:
    let n = s.readData(addr buf[0], drainChunk)
    if n == 0: break                     # pipe momentarily empty; cell may still run
    # Append the chunk to the accumulator. string.add has no openArray[char]
    # overload, so grow explicitly and copy (the same shape Nim's readAll uses).
    let prev = r.acc.len
    r.acc.setLen(prev + n)
    copyMem(addr r.acc[prev], addr buf[0], n)
  # NB: do NOT call readAll here — it loops until EOF, so it would block on a
  # still-running cell, defeating the whole point. Per-cycle drain only.

proc readTrimmed(s: Stream; tail: bool; n: int): string =
  ## Stream a source (a process pipe or a file) through a trim window so an
  ## enormous input is never read fully into memory before the lines to keep are
  ## chosen:
  ##   - `head` (`tail == false`): keep the first `n` lines, then *stop reading*.
  ##     The rest of the stream is left unread, so the cost scales with `n`, not
  ##     with the input size. (The exact number of lines cut is therefore
  ##     unknown — the footer reports that further content was truncated, without
  ##     a count, rather than draining the whole stream just to count it.)
  ##   - `tail` (`tail == true`): read the whole stream but retain only the last
  ##     `n` lines in a rolling buffer, so peak memory is still `n` lines, not
  ##     the input size. The exact count cut is reported.
  ## A no-op (no footer) when the content already fits, and a one-line footer
  ## naming the mode and limit appended when lines are actually dropped. Default
  ## `trim:head,50` (resolved in `processBodyForCells`) bounds every `show:` cell.
  if n <= 0: return ""
  if not tail:
    var kept: seq[string] = @[]
    while kept.len < n and not s.atEnd:
      kept.add(s.readLine())          # read only as many lines as we keep
    if kept.len == 0: return ""
    let core = kept.join("\n").strip()  # bounded by n lines — never the raw stream
    if core.len == 0: return ""         # whitespace-only content reads as empty
    if s.atEnd: return core             # content fit within n lines — no footer
    core & &"\n... (trim:head,{n} — further content truncated)"
  else:
    var ring = newSeq[string](n)        # rolling buffer of the last n lines
    var filled = 0
    var pos = 0                         # write cursor once the ring is full
    var total = 0
    while not s.atEnd:
      let line = s.readLine()
      inc total
      if filled < n:
        ring[filled] = line; inc filled
      else:
        ring[pos] = line; pos = (pos + 1) mod n
    if total == 0: return ""
    var kept: seq[string]
    if filled < n: kept = ring[0 ..< filled]
    else:
      kept = newSeq[string](n)
      for k in 0 ..< n: kept[k] = ring[(pos + k) mod n]   # unwind to original order
    let core = kept.join("\n").strip()
    if core.len == 0: return ""
    if total > n:
      core & &"\n... (trim:tail,{n} — {total - n} lines truncated)"
    else: core

## ==============
## md-viewer image-cache refresh. Markdown viewers (e.g. Zettlr) cache inline
## images by URL, so when a cell regenerates an image without changing its
## filename (the normal mdnb workflow — filenames are stable), the viewer keeps
## showing the stale pixels. The refresh trick, applied once a cell finishes and
## has possibly regenerated images: two passes over the prose's image references,
## saving between them. The first pass perturbs every image URL in a way the
## viewer's cache is sensitive to but that does not change the rendered image;
## the second pass reverts the perturbation so the author and version control
## see the original markdown again. Each save forces the viewer to re-resolve
## (and thus re-decode) the image.
##
## Two image-reference flavors are handled (the two the viewer supports):
##   1. classic markdown `![description](image_url)` -> append `#0` to the URL.
##   2. html flavor `<img ... src="image_url" ...>` -> append a trailing space
##      inside the quoted src value.
## Both are visual no-ops: a URL fragment (`#0`) is not part of the fetched path,
## and a trailing space in an html attribute value is collapsed by the renderer.
##
## The scan operates on the prose GAPS only — never inside a fenced code block —
## mirroring `replaceShortcuts`'s gap-walking loop, so an `![..](..)` that is part
## of a code sample is never perturbed. Cell byte ranges shift between the two
## passes (each save re-reads from disk), so offsets are recomputed per pass from
## a fresh gap walk rather than carried across.

proc transformImageUrl(url, fragSuffix: string): string =
  ## Apply (or revert) the cache-busting perturbation to a classic-markdown image
  ## URL. `fragSuffix` is the fragment to ensure the URL ends with (`#0`):
  ##   - transform (`fragSuffix = "#0"`): `foo.png` -> `foo.png#0`
  ##   - revert    (`fragSuffix = ""`):   `foo.png#0` -> `foo.png`
  ## Idempotent: appending when the fragment is already present is a no-op, so a
  ## repeated perturb pass does not stack fragments.
  if fragSuffix.len == 0:
    if url.endsWith("#0"): result = url[0 ..< url.len - 2]
    else: result = url
  else:
    if url.endsWith(fragSuffix): result = url      # already perturbed; leave as-is
    else: result = url & fragSuffix

proc perturbHtmlSrcValue(val, fragSuffix: string): string =
  ## Apply (or revert) the cache-busting perturbation to an html `<img src="...">`
  ## value. The html perturbation is a trailing space inside the quotes (a renderer
  ## collapses it, so it is a visual no-op the viewer cache is still sensitive to):
  ##   - transform (`fragSuffix != ""`): `foo.png` -> `foo.png ` (trailing space)
  ##   - revert    (`fragSuffix == ""`):  `foo.png ` -> `foo.png` (strip one space)
  ## Idempotent on both directions. (`fragSuffix` is used only as a non-empty flag
  ## here — the actual perturbation char is always a space for the html flavor.)
  if fragSuffix.len > 0:
    if val.endsWith(" "): result = val
    else: result = val & " "
  else:
    if val.endsWith(" "): result = val[0 ..< val.len - 1]
    else: result = val

proc applyToProseMarkdownImages(md: var MarkdownFile; fragSuffix: string;
                                 imgCount: var int) =
  ## Walk every prose gap of `md` and rewrite each classic-markdown image URL
  ## (`![desc](url)`) via `transformImageUrl` with `fragSuffix`. Fenced code blocks
  ## are skipped: their bytes are inside a cell's `rng`, and only the gaps between
  ## cells are scanned. This mirrors the gap walk in `replaceShortcuts`
  ## (`endPrevChunk`/`startNextChunk` track the current gap's bounds as edits shift
  ## the buffer). `imgCount` accumulates rewrites for verbose reporting.
  var matches = newSeq[string](1)
  var endPrevChunk, startNextChunk = 0
  for cell_i in 0 .. md.cells.len:
    startNextChunk = if cell_i == md.cells.len: md.buf[].len - 1
                     else: md.cells[cell_i].rng.a
    var pos: tuple[first, last: int] = (-1, 0)
    while true:
      matches[0] = ""
      pos = md.buf[][endPrevChunk .. startNextChunk].findBounds(mdImagePattern,
                                                                matches, start = pos.last)
      if pos.first == -1: break
      # `matches[0]` is the captured URL. `findBounds` returns slice-relative
      # offsets, where `pos.first` is the `!` and `pos.last` is the closing `)`.
      # The URL sits immediately before the `)`, so its absolute start is
      # `endPrevChunk + pos.last - matches[0].len` (slice index 0 == buffer index
      # `endPrevChunk`, since the slice began there).
      let urlStart = endPrevChunk + pos.last - matches[0].len
      let newUrl = transformImageUrl(matches[0], fragSuffix)
      if newUrl != matches[0]:
        md.buf[] = md.buf[][0 ..< urlStart] & newUrl &
                   md.buf[][urlStart + matches[0].len .. ^1]
        let delta = newUrl.len - matches[0].len
        if cell_i < md.cells.len:
          md.updatePositionsByOffset(md.cells[cell_i].id, delta)
        startNextChunk += delta
        inc imgCount
      # Advance past this URL so the next scan continues after it.
      pos = (pos.first, pos.first + (if newUrl != matches[0]: newUrl.len - 1
                                     else: matches[0].len - 1))
    endPrevChunk = startNextChunk

proc findHtmlImgSrc(buf: string; gapA, gapB: int;
                    outUrlStart, outUrlEnd: var int): bool =
  ## Manual scan for the next `<img ... src="..." ...>` tag's src value within the
  ## prose gap `[gapA .. gapB]`. On success returns true with `outUrlStart`/`
  ## outUrlEnd` set to the absolute buffer offsets of the src value (the bytes
  ## inside the quotes, exclusive of the quotes themselves). On no-more-matches
  ## returns false.
  ##
  ## A hand-written scan rather than a PEG because a robust PEG for arbitrary html
  ## attributes (quoted, unquoted, single/double quotes) runs into Nim PEG's
  ## charset/quote-parsing limitations; the scanner handles every attribute shape
  ## the viewer emits (it only needs to locate the `src` attribute's quoted value,
  ## skipping over other name=value attributes that may contain `>` or quotes
  ## inside their own quotes). Anchor is case-insensitive `<img`, then the first
  ## `src` attribute whose value is single- or double-quoted.
  var i = gapA
  while i <= gapB - 4:
    if buf[i] == '<' and buf[i + 1] == 'i' and buf[i + 2] == 'm' and
       buf[i + 3] == 'g':
      # Found `<img` — scan attributes within this tag until `>` or end of gap.
      var j = i + 4
      var foundSrc = false
      var srcStart, srcEnd = 0
      var q: char = '\0'
      while j <= gapB:
        let c = buf[j]
        if c == '>':
          break                            # end of tag
        if c == ' ' or c == '\t' or c == '\n' or c == '/':
          inc j; continue                  # skip whitespace and self-close slash
        # Read an attribute name up to '=' or whitespace.
        let nameStart = j
        while j <= gapB and buf[j] != '=' and buf[j] != ' ' and
              buf[j] != '\t' and buf[j] != '\n' and buf[j] != '>' : inc j
        let name = buf[nameStart ..< j]
        if j <= gapB and buf[j] == '=':
          inc j                             # consume '='
          while j <= gapB and (buf[j] == ' ' or buf[j] == '\t'): inc j  # skip ws
          if j <= gapB and (buf[j] == '"' or buf[j] == '\''):
            q = buf[j]; inc j               # opening quote
            let valStart = j
            while j <= gapB and buf[j] != q: inc j
            if j <= gapB:
              # quoted value spans [valStart ..< j]; closing quote at j.
              if name == "src" and not foundSrc:
                foundSrc = true
                srcStart = valStart
                srcEnd = j                 # exclusive end of value
              inc j                         # consume closing quote
            else:
              break                         # unterminated quote; bail on tag
          else:
            # Unquoted value: run of non-whitespace, non->.
            while j <= gapB and buf[j] != ' ' and buf[j] != '\t' and
                  buf[j] != '\n' and buf[j] != '>': inc j
        else:
          # bare attribute (no value) — name already consumed; loop continues.
          discard
      if foundSrc:
        outUrlStart = srcStart
        outUrlEnd = srcEnd
        return true
      i = j                                 # tag had no src; resume after it
    else:
      inc i
  false

proc applyToProseHtmlImages(md: var MarkdownFile; fragSuffix: string;
                             imgCount: var int) =
  ## Walk every prose gap and rewrite each `<img src="...">` value via
  ## `perturbHtmlSrcValue` with `fragSuffix`. Same gap-walking and offset-patching
  ## approach as `applyToProseMarkdownImages`; the html tag is located by the
  ## manual `findHtmlImgSrc` scanner. `imgCount` accumulates rewrites.
  var endPrevChunk, startNextChunk = 0
  for cell_i in 0 .. md.cells.len:
    startNextChunk = if cell_i == md.cells.len: md.buf[].len - 1
                     else: md.cells[cell_i].rng.a
    var scanFrom = endPrevChunk
    while true:
      var urlStart, urlEnd = 0
      if not md.buf[].findHtmlImgSrc(scanFrom, startNextChunk, urlStart, urlEnd):
        break
      let oldVal = md.buf[][urlStart ..< urlEnd]
      let newVal = perturbHtmlSrcValue(oldVal, fragSuffix)
      if newVal != oldVal:
        md.buf[] = md.buf[][0 ..< urlStart] & newVal &
                   md.buf[][urlEnd .. ^1]
        let delta = newVal.len - oldVal.len
        if cell_i < md.cells.len:
          md.updatePositionsByOffset(md.cells[cell_i].id, delta)
        startNextChunk += delta
        urlEnd = urlStart + newVal.len
        inc imgCount
      # Continue scanning after this value.
      scanFrom = urlEnd
    endPrevChunk = startNextChunk

import std/os
proc refreshImageCache(md: var MarkdownFile) =
  ## Force a markdown viewer to re-decode inline images after a cell run. Runs the
  ## perturb/revert trick: pass 1 rewrites every prose image URL with a visual
  ## no-op perturbation and saves; pass 2 reverts it and saves. Each save makes
  ## the viewer drop its cached pixels for those URLs. Called from `reapFinished`
  ## so a regenerated image (same filename, new pixels) shows up immediately.
  ##
  ## Both image-reference flavors the viewer supports are handled in each pass,
  ## in document order. The final file is byte-identical to its pre-refresh state
  ## (the two passes cancel), so this is invisible to the author and to version
  ## control — only the viewer's image cache is affected. No-op (and no extra
  ## saves) when the prose contains no image references at all.
  var imgCount = 0
  # Pass 1: perturb. Append `#0` to markdown URLs, a trailing space to html src.
  md.applyToProseMarkdownImages("#0", imgCount)
  md.applyToProseHtmlImages("#0", imgCount)
  if imgCount == 0:
    if verbose: echo "[mdnb] image-cache refresh: no inline images found, skipping"
    return
  md.write
  sleep(50) # sleep a bit so the viewer has a chance to recognize the change
  if verbose: echo &"[mdnb] image-cache refresh pass 1 (perturb): {imgCount} image(s)"
  # Pass 2: revert. Strip the `#0` fragment / collapse the trailing space.
  var revertCount = 0
  md.applyToProseMarkdownImages("", revertCount)
  md.applyToProseHtmlImages("", revertCount)
  md.write
  if verbose: echo &"[mdnb] image-cache refresh pass 2 (revert): {revertCount} image(s)"

## ==============

proc reapFinished(md: var MarkdownFile; r: var Running) =
  ## Read the finished process's stdout, write it in full to its `output:` file,
  ## write a trimmed view into any matching `show:` cell of the current md, then
  ## flip the cell `r` -> `s`. The on-disk `output:` file is intentionally
  ## untrimmed — it holds the real, complete output. Trimming is a display
  # concern: it's applied only when content is read into a `show:` cell, so the
  # source of truth on disk is never truncated. Notices mdnb authors itself
  # (the timeout-kill notice, `(please wait)`, `(empty output)`) are written
  # verbatim — only captured subprocess output is trimmed for display.
  #
  # Non-zero exit (Tier 3): when the command did not exit cleanly, prepend an
  # mdnb-authored notice naming the exit code to both the `output:` file and the
  # `show:` cell, so the failure is unambiguous even when the command printed
  # nothing. stderr is already merged into the captured output (`poStdErrToStdOut`
  # in startRun), so the command's own error text is in `raw`; the notice just
  # flags the failure. The notice is prepended to the captured output and the
  # combined text is what's trimmed for display, so under the default
  # `trim:head,N` the notice stays pinned at the top.
  # The bulk of the output was drained incrementally by `pollRuns`/`drainOutput`
  # while the cell ran (to keep the OS pipe from filling and blocking the
  # producer); drain the final tail bytes the process wrote between the last poll
  # and exiting, then read from the accumulator rather than the pipe.
  r.drainOutput
  let exitCode = r.p.peekExitCode
  r.p.close
  # Ephemeral bare-block cell: it ran for its side effects only — no `output:`
  # file is kept and there is no `show:` cell to fill. The tmp source stays on
  # disk as a CACHE so an unchanged bare block does not re-run on the next save
  # (see markDirtyCells: it skips a cell whose source file matches its content).
  # `:clean` is what wipes these; editing the block changes its content-derived
  # filename, so the stale cache file is simply left behind (harmless) and the
  # new one is missing -> dirty -> runs. Just report status and settle state.
  if r.ephemeral:
    r.logRunStatus(exitCode)
    for i, c in md.cells:
      if c.properties.code and c.properties.source == r.sourceFile and c.properties.state == 'r':
        md.cells[i].properties.state = 's'   # keep in-memory state synced with disk
        md.writeCellState(i, 's')
        break
    # A bare-block cell may have regenerated an image (it ran for its side
    # effects, e.g. `python` writing `plot.png`). Refresh the viewer's image
    # cache so the new pixels show up.
    md.refreshImageCache
    return
  let raw = r.acc.strip
  let errored = exitCode != 0          # reapFinished is only reached once finished, so != 0 means failed
  let body =
    if errored and raw.len > 0:
      &"(mdnb: cell exited with code {exitCode})\n" & raw
    elif errored:
      &"(mdnb: cell exited with code {exitCode})"
    else:
      raw
  r.outputFile.safeWriteFile(body)
  let showIdx = md.showCellForOutput(r.outputFile)
  if showIdx >= 0:
    # Stream the full output through the producer cell's trim window for display.
    # The producer cell carries the `trim:` settings (resolved at parse time) so
    # the `show:` cell reflects them without the user having to redeclare `trim:`
    # on the show block.
    let props = cellWithSource(md, r.sourceFile)
    let shown = readTrimmed(newStringStream(body), props.trimTail, props.trimLines)
    md.writeIntoCell(showIdx, if shown.len > 0: shown else: "(empty output)")
    md.write
  # Verbose execution status (Tier 3): cell id, command, exit code, duration.
  r.logRunStatus(exitCode)
  # Flip the producing cell's state r -> s so the user sees it settled.
  for i, c in md.cells:
    if c.properties.code and c.properties.source == r.sourceFile and c.properties.state == 'r':
      md.cells[i].properties.state = 's'   # keep in-memory state synced with disk
      md.writeCellState(i, 's')
      break
  # Refresh the md viewer's image cache: a cell that ran may have regenerated an
  # image (same filename, new pixels), and viewers cache by URL. The perturb/
  # revert trick forces a re-decode. Runs after the cell's output/state are
  # settled so the refresh is the last write the viewer sees this pass.
  md.refreshImageCache

proc reapTimeout(md: var MarkdownFile; r: Running) =
  ## Kill a cell that exceeded its `timeout:` and write a notice explaining what
  ## happened and the limit that was hit, into both its `output:` file and any
  ## matching `show:` cell. Mirrors `reapFinished` but substitutes the notice for
  ## the (incomplete, possibly empty) captured output.
  osproc.kill(r.p)
  let exitCode = r.p.peekExitCode
  r.p.close
  # Ephemeral bare-block cell: no `output:`/`show:` to write a notice into. The
  # tmp source stays on disk as a cache (wiped by `:clean`). Just report status.
  if r.ephemeral:
    r.logRunStatus(exitCode, note = &"killed (timeout:{r.timeoutSecs}s)")
    for i, c in md.cells:
      if c.properties.code and c.properties.source == r.sourceFile and c.properties.state == 'r':
        md.cells[i].properties.state = 's'   # keep in-memory state synced with disk
        md.writeCellState(i, 's')
        break
    return
  let notice = &"(mdnb killed this cell: exceeded timeout:{r.timeoutSecs}s)"
  r.outputFile.safeWriteFile(notice)
  let showIdx = md.showCellForOutput(r.outputFile)
  if showIdx >= 0:
    md.writeIntoCell(showIdx, notice)
    md.write
  # Verbose execution status (Tier 3): the killed cell still gets a status line.
  r.logRunStatus(exitCode, note = &"killed (timeout:{r.timeoutSecs}s)")
  for i, c in md.cells:
    if c.properties.code and c.properties.source == r.sourceFile and c.properties.state == 'r':
      md.cells[i].properties.state = 's'   # keep in-memory state synced with disk
      md.writeCellState(i, 's')
      break

proc pollRuns(md: var MarkdownFile) =
  ## Reap finished/killed subprocesses belonging to `md.filename` non-blockingly.
  ## Called every watch cycle (independent of mtime change) so a long-running
  ## cell completing gets written back promptly. Also honors `[k]`: kill the
  ## matching running cell. Reaps are file-scoped so file A's slow cell never
  ## interferes with file B's cells.
  # First, honor kills: a cell now marked 'k' kills its running process.
  for i, cell in md.cells:
    if cell.properties.code and cell.properties.state == 'k':
      for j, r in running:
        if r.filename == md.filename and r.sourceFile == cell.properties.source:
          # osproc.kill sends SIGKILL (p.close only closes handles and leaves
          # the child orphaned/running). Reap the corpse, drop it from `running`,
          # and flip the cell's state k -> s — both on disk and in memory, so the
          # run-launch pass below doesn't immediately re-launch this cell.
          osproc.kill(running[j].p)
          let exitCode = running[j].p.peekExitCode
          running[j].p.close
          # Verbose execution status (Tier 3): report the manually-killed cell.
          running[j].logRunStatus(exitCode, note = "killed ([k])")
          running.delete j
          md.cells[i].properties.state = 's'
          md.writeCellState(i, 's')
          break
  # Then reap whatever has finished on its own, or kill any past its timeout
  # (this file's processes only). Drain each of this file's running cells first:
  # the OS pipe buffer is ~64KB, so without a per-cycle drain a cell whose output
  # exceeds it blocks the producer on a full pipe and can never exit — the
  # timeout below would then kill it before any output landed (see drainOutput).
  let now = getTime()
  var i = 0
  while i < running.len:
    if running[i].filename != md.filename:
      inc i                              # belongs to another watched file
    else:
      # Decide the cell's fate BEFORE draining. `outputStream.readData` blocks on
      # an empty-but-live pipe (it returns 0 only at EOF, i.e. once the process
      # has exited), so draining a still-running cell that is momentarily silent
      # (e.g. `sleep 30`) would hang the whole watcher — and then a user-typed
      # `[k]` could never be honored. The stdlib has no portable non-blocking
      # pipe read (`Process.hasData` reports an open write-end as readable even
      # with zero bytes), so we gate the drain on `peekExitCode`: only drain when
      # the process is finished (pipe at EOF → readData returns 0, no block) or
      # when it is being killed for timeout. A still-running cell is left alone
      # this cycle. Trade-off: a running cell whose output exceeds the ~64KB pipe
      # buffer blocks its own producer and is then killed by its `timeout:` — so
      # very-heavy-output cells need a generous `timeout:` AND must fit in the
      # buffer, or be split up. This keeps the watcher responsive (the priority).
      if now - running[i].started >= initDuration(seconds = running[i].timeoutSecs):
        # Per-cell timeout (Tier 2): exceeded its `timeout:N` (default 5s). Kill,
        # drop from `running`, and write a notice so the user can see what/why.
        md.reapTimeout(running[i])
        running.delete i
      elif running[i].p.peekExitCode == -1:
        inc i   # still running; leave it for a future cycle (do NOT drain)
      else:
        md.reapFinished(running[i])   # finished: drains at EOF inside reapFinished
        running.delete i

## ==============

proc sweepEphemeralCache(md: var MarkdownFile) =
  ## Garbage-collect orphaned bare-block (ephemeral) tmp files for *this* md
  ## file. Each run leaves a cache file per distinct cell body, named
  ## `<mdname>_tmp_<hash>.<ext>`; when a cell's body changes (new hash) or a cell
  ## is deleted, its old file becomes an orphan. Rather than track "the last
  ## filename" per cell (which needs a stable cross-parse identity cell ids can't
  ## provide), we treat the filesystem as the map: after parsing, mdnb knows every
  ## CURRENT cell's source path, so any mdnb-authored tmp file for this md that
  ## isn't a current source is an orphan and is deleted here. Files still in use
  ## by a running subprocess are spared (a cell edited mid-run keeps its source
  ## until the run is reaped). Per-md: a multi-file run never touches another
  ## file's cache. Stateless — no map to maintain or corrupt.
  let base = splitFile(md.filename).name
  # Sources the current parse knows about, plus any file a running cell still
  # needs (an edited-while-running cell's source is live until it's reaped).
  var keep: HashSet[string]
  for cell in md.cells:
    if cell.properties.code and cell.properties.source.len > 0:
      keep.incl cell.properties.source
  for r in running:
    if r.sourceFile.len > 0: keep.incl r.sourceFile
  for path in walkFiles(base & "_tmp_*"):
    if path in keep: continue
    # Only sweep files matching mdnb's exact ephemeral naming (not a user file
    # that merely contains `_tmp_`): the name must end in `_tmp_<8hex>.<ext>`.
    if not path.looksEphemeral: continue
    tryRemoveFile(path)

proc runCells(md: var MarkdownFile) =
  ## Launch every cell that should run this pass (dirty, or `[x]`-forced) and
  ## reap any that finished since last cycle. Non-blocking: long cells are
  ## left in `running` and reaped on subsequent calls rather than blocking here.
  createDir "temp"
  md.sweepEphemeralCache
  md.pollRuns
  for i, cell in md.cells:
    if cellShouldRun(cell):
      md.startRun(i)
    elif not cell.properties.code:
      # Non-runnable `show:` cell: read its file back in if it already exists
      # (e.g. output landed on a previous pass, or from a prior session). The
      # file is streamed through the cell's trim window (`trim:head,N` /
      # `trim:tail,N`, default `head,50`) so an enormous file is never read
      # fully into memory and the markdown only ever shows the trimmed view —
      # the on-disk file stays the complete source of truth. Cells whose
      # producer is still running get their freshest output on a later cycle
      # via reapFinished.
      let target = cell.properties.show
      if fileExists(target):
        let fs = newFileStream(target, fmRead)
        if fs != nil:
          let shown = readTrimmed(fs, cell.properties.trimTail,
                                  cell.properties.trimLines)
          fs.close
          md.writeIntoCell(i, shown)
          md.write

proc reapThis(md: var MarkdownFile; sourceFile: string; timeoutSecs: int; started: Time) =
  ## Block until the running cell identified by `sourceFile` is reaped, honoring
  ## its `timeout:` and `[k]`. Used by `runCellsSequential` to run one cell to
  ## completion before starting the next, so the bulk-run commands produce a
  ## visible per-cell x -> r -> s progression in the file. Mirrors the watch
  ## loop's reap path: drain the pipe each spin (large output must not block the
  # producer on a full ~64KB pipe), kill on timeout, and call `reapFinished`
  ## (which writes output + the show cell + flips state to `s` + writes the file).
  let deadline = started + initDuration(seconds = timeoutSecs)
  while true:
    var idx = -1
    for j, r in running:
      if r.filename == md.filename and r.sourceFile == sourceFile: idx = j; break
    if idx == -1: return   # no longer in `running` -> already reaped elsewhere
    # Honor a user-typed `[k]` on this cell between spins (parse current file).
    let killRequested = block:
      var kr = false
      for c in md.cells:
        if c.properties.code and c.properties.source == sourceFile and c.properties.state == 'k':
          kr = true; break
      kr
    if killRequested:
      osproc.kill(running[idx].p)
      let ec = running[idx].p.peekExitCode
      running[idx].p.close
      running[idx].logRunStatus(ec, note = "killed ([k])")
      running.delete idx
      # flip k -> s in the file
      for i, c in md.cells:
        if c.properties.code and c.properties.source == sourceFile:
          md.cells[i].properties.state = 's'
          md.writeCellState(i, 's')
          break
      return
    if getTime() >= deadline:
      md.reapTimeout(running[idx])
      running.delete idx
      return
    if running[idx].p.peekExitCode != -1:
      md.reapFinished(running[idx])
      running.delete idx
      return
    sleep(50)

proc runCellsSequential(md: var MarkdownFile; selectedIdx: seq[int]) =
  ## Tier 4 bulk-run core: run `selectedIdx` cells one at a time in document
  ## order, fully completing each (x -> r -> s, output written, show cell filled)
  ## before the next starts — so `:runall`/`:runabove`/`:runbelow` give a visible
  ## per-cell progression, as required. Each cell is forced by flipping its state
  ## to `x` (the run trigger) in memory and on disk, then launched via the normal
  ## `startRun` and synchronously reaped via `reapThis`. This deliberately BLOCKS
  ## the watcher for the duration (documented behavior): ordering and per-cell
  ## file updates are the point of the bulk commands, and neither is possible
  ## with the non-blocking launch path. Dependencies (`inputs:`/`output:`) still
  ## apply transitively: `markDirtyCells` already ran, and a cell whose inputs
  ## changed simply re-runs because it is in `selectedIdx`.
  createDir "temp"
  md.sweepEphemeralCache
  md.pollRuns
  for idx in selectedIdx:
    # Skip a cell that is already running (e.g. launched on a prior pass) — its
    # output lands on a later cycle; forcing a second launch would collide on the
    # same source file. Also skip raw/non-running cells handled below.
    if idx < 0 or idx >= md.cells.len: continue
    if not md.cells[idx].properties.code: continue
    # Read the producer's resolved timeout (default 5) for the blocking reap.
    let secs = md.cells[idx].properties.timeout
    # Force the run trigger: set state x in memory and splice into the file so
    # the user sees x, then startRun flips it to r and launches the subprocess.
    md.cells[idx].properties.state = 'x'
    md.writeCellState(idx, 'x')
    md.startRun(idx)
    md.write   # x -> r visible before we block on the reap
    md.reapThis(md.cells[idx].properties.source, secs,
                if running.len > 0: running[^1].started else: getTime())
  # After the sequential run, refresh any show cells whose files now exist but
  # weren't the target of a just-run producer (e.g. a show cell below all run
  # cells, displaying a pre-existing file). Cheap and keeps the view consistent.
  for i, cell in md.cells:
    if not cell.properties.code and cell.properties.show.len > 0:
      let target = cell.properties.show
      if fileExists(target):
        let fs = newFileStream(target, fmRead)
        if fs != nil:
          let shown = readTrimmed(fs, cell.properties.trimTail,
                                  cell.properties.trimLines)
          fs.close
          md.writeIntoCell(i, shown)
  md.write
