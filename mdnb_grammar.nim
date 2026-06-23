## Grammar of record: every directive mdnb understands is a PEG here. If behavior and a PEG disagree, the PEG is usually the bug (agents.md §11).
const imageExt = "png jpg jpeg gif pdf".split().mapIt("." & it)

proc contentHash(s: string): string =
  ## 8-hex digest of a cell's body; the cache key for a bare-block (ephemeral) cell's tmp filename (same content -> same file -> not dirty).
  toHex(uint32(hash(s)), 8).toLowerAscii()

proc looksEphemeral(path: string): bool =
  ## True if `path` matches mdnb's bare-block cache shape `_tmp_<8hex>.<ext>` (used by `sweepEphemeralCache` so a user file containing `_tmp_` is never swept).
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
    # Loose shape match for the two-field `[T](S)` control (T∈{x,o,space}, S∈{r,s,k}); the content is validated in `parseCellCommands`, which emits a stderr error and skips the cell on any invalid content.
    stateField <- '[' [^\]]* ']' '(' [^\)]* ')'
    quoted_string <- \" ( !\" .)+ \"
    word <- (\w / \/ / \\ / \. / \- / \,)+
    codefenceend <- \n upTo3WS $1 (!\n \s)* \n
    """
  bareShowPattern = peg"""\n (!\n \s)* "show:" {(\w / '.' / '-' / ':' / '/' / '\\')*} (!\n \s)* \n"""
  cleanPattern = peg"""\n ":clean" (!\n \s)* \n"""
  # Tier 4 global run commands (modeled on `cleanPattern`); `replaceShortcuts` removes the line and records its cell boundary + runMode.
  runAllPattern = peg"""\n ":runall" (!\n \s)* \n"""
  runAbovePattern = peg"""\n ":runabove" (!\n \s)* \n"""
  runBelowPattern = peg"""\n ":runbelow" (!\n \s)* \n"""
  # Classic `![desc](url)` image reference used by `refreshImageCache` (the html `<img>` form is scanned by hand in `findHtmlImgSrc`).
  mdImagePattern = peg"'!' '[' ([^\]]*) ']' '(' {([^\)]*)} ')'"
