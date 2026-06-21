## Grammar of record: the PEG patterns and helpers that define mdnb's syntax.
## Every directive mdnb understands is expressed here. If behavior and a PEG
## disagree, the PEG is usually the bug (see agents.md §11).
const imageExt = "png jpg jpeg gif pdf".split().mapIt("." & it)
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
