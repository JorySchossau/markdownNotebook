## Grammar of record: the PEG patterns and helpers that define mdnb's syntax.
## Every directive mdnb understands is expressed here. If behavior and a PEG
## disagree, the PEG is usually the bug (see agents.md §11).
const imageExt = "png jpg jpeg gif pdf".split().mapIt("." & it)

proc contentHash(s: string): string =
  ## Short stable hex digest of a cell's body, used to derive a cache-friendly
  ## tmp filename for a bare-block (ephemeral) cell. The hash IS the cache key:
  # same content -> same hash -> same file -> not dirty -> no rerun; editing the
  # block changes the hash -> new filename -> missing -> dirty -> runs. Uses the
  # stdlib's hash (non-cryptographic, which is fine here — it's a cache key, not
  # a security boundary) truncated to 8 hex chars.
  toHex(uint32(hash(s)), 8).toLowerAscii()

proc looksEphemeral(path: string): bool =
  ## True if `path` is an mdnb-authored bare-block cache file, i.e. it ends in
  ## `_tmp_<8hex>.<ext>`. Shared understanding between the parser-side naming and
  ## the `sweepEphemeralCache` GC: only files matching this exact shape are swept,
  ## so a user file that merely contains `_tmp_` is never touched. (A plain string
  ## check rather than a PEG because Nim PEGs don't support the `{8}` count we'd
  # need, and the shape is simple enough to verify by slicing.)
  let dot = path.rfind('.')
  if dot < 0: return false                      # needs an extension
  let stem = path[0 ..< dot]                    # everything before the final '.'
  if stem.len < 13: return false                # need "_tmp_" + 8 hex at minimum
  let marker = stem.len - 13
  if stem[marker ..< marker + 5] != "_tmp_": return false
  for i in (marker + 5) ..< stem.len:           # the 8 hex chars
    let c = stem[i]
    if c notin {'0'..'9', 'a'..'f'}: return false
  true
let
  yamlEndPattern = peg"""\n'---' '-'*\n"""
  yamlConfigPattern =
    peg"""
    r <- \n \s* 'code' \s* ':' \s* {mdlangid} \s* {langext} \s* runcmd
    mdlangid <- \w*
    langext <- (\w  /  '.')*
    runcmd <- quoted_cmd  /  unquoted_cmd
    quoted_cmd <- \" {(!\n !\" .)*} \"
    unquoted_cmd <- {CommandChars*}
    CommandChars <- !\n !\" \w  /  '.'  /  ':'  /  '-'  /  '/'  /  '\\'
    """
  chunkPattern =
    peg"""
    r <- (\n / ^) upTo3WS {codefence} (!\n \s* {command})+ (!codefenceend .)* codefenceend
    codefence <- "```" '`'* / "~~~" '~'*
    upTo3WS <- !\n \s? !\n \s? !\n \s?
    command <- stateField   /   word ':' quoted_string   /   word ':' word   /   word
    stateField <- '[' statchar ']'
    statchar <- [srxk]
    quoted_string <- \" ( !\" .)+ \"
    word <- (\w / \/ / \\ / \. / \- / \,)+
    codefenceend <- \n upTo3WS $1 (!\n \s)* \n
    """
  bareShowPattern = peg"""\n (!\n \s)* "show:" {(\w / '.' / '-' / ':' / '/' / '\\')*} (!\n \s)* \n"""
  cleanPattern = peg"""\n ":clean" (!\n \s)* \n"""
  # Tier 4 global run commands: each is a single token on its own line, modeled
  # on `cleanPattern`. They select a scope of cells to run in document order (all
  # / above the command / below it). `replaceShortcuts` removes the line, records
  # the command's original byte offset (so `:runabove`/`:runbelow` can map to a
  # cell boundary), and sets a flag on the MarkdownFile for the bulk-run step.
  runAllPattern = peg"""\n ":runall" (!\n \s)* \n"""
  runAbovePattern = peg"""\n ":runabove" (!\n \s)* \n"""
  runBelowPattern = peg"""\n ":runbelow" (!\n \s)* \n"""
  # Image reference used by `refreshImageCache` (the md-viewer image-cache refresh
  # trick). This matches the classic markdown image form
  #   ![description](image_url)
  # and captures the URL (everything up to the closing paren) as its one group, so
  # the perturb/revert passes can rewrite it. The html `<img ...>` form is matched
  # by a manual scan in `applyToProseImagesHtml` instead, because a robust PEG for
  # arbitrary html attributes (quoted, unquoted, mixed quotes) runs into Nim's PEG
  # charset/quote-parsing limitations; the hand scanner is clearer and handles
  # every attribute shape the viewer emits.
  mdImagePattern = peg"'!' '[' ([^\]]*) ']' '(' {([^\)]*)} ')'"
