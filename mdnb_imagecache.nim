## md-viewer image-cache refresh. Viewers cache inline images by URL, so a cell regenerating an image without changing its filename (the normal mdnb workflow) leaves the viewer showing stale pixels. The trick: two passes over the prose's image references with a save between them — pass 1 perturbs each URL with a visual no-op the cache is sensitive to, pass 2 reverts it. Each save forces a re-decode. The file ends byte-identical to its pre-refresh state. Two flavors are handled: classic `![desc](url)` (append `#0`) and html `<img src="...">` (append a trailing space, collapsed by the renderer). Scans prose GAPS only (never inside a fenced block).

proc transformImageUrl(url, fragSuffix: string): string =
  ## Apply/revert the `#0` perturbation to a classic-markdown image URL. Idempotent (appending when already present is a no-op).
  if fragSuffix.len == 0:
    if url.endsWith("#0"): result = url[0 ..< url.len - 2]
    else: result = url
  else:
    if url.endsWith(fragSuffix): result = url      # already perturbed; leave as-is
    else: result = url & fragSuffix

proc perturbHtmlSrcValue(val, fragSuffix: string): string =
  ## Apply/revert the trailing-space perturbation to an html `<img src="...">` value (`fragSuffix` is just a non-empty flag here). Idempotent both directions.
  if fragSuffix.len > 0:
    if val.endsWith(" "): result = val
    else: result = val & " "
  else:
    if val.endsWith(" "): result = val[0 ..< val.len - 1]
    else: result = val

proc applyToProseMarkdownImages(md: var MarkdownFile; fragSuffix: string;
                                 imgCount: var int) =
  ## Walk every prose gap and rewrite each classic-markdown image URL via `transformImageUrl`. Fenced blocks (inside a cell's `rng`) are skipped. `imgCount` accumulates rewrites for verbose reporting.
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
      # `matches[0]` is the captured URL; `pos.first` is the `!`, `pos.last` the closing `)`. URL start = endPrevChunk + pos.last - matches[0].len (slice index 0 == buffer index endPrevChunk).
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
  ## Manual scan for the next `<img ... src="..." ...>` src value within the prose gap `[gapA .. gapB]`. Returns true with `outUrlStart`/`outUrlEnd` set to the value bytes (exclusive of quotes). Hand-written rather than a PEG because Nim PEGs can't cleanly express arbitrary html attribute shapes (quoted/unquoted/mixed).
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
  ## Walk every prose gap and rewrite each `<img src="...">` value via `perturbHtmlSrcValue`. Same gap-walking/offset-patching as `applyToProseMarkdownImages`; the tag is located by `findHtmlImgSrc`.
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

proc refreshImageCache(md: var MarkdownFile) =
  ## Run the perturb/revert trick so a regenerated image (same filename, new pixels) shows up. Pass 1 rewrites URLs and saves; pass 2 reverts and saves. No-op (no extra saves) when the prose has no image references. Called from `reapFinished`.
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
