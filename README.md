Markdown Notebook is an editor-agnostic Jupyter Notebook-like experience for your markdown files. Code chunks are run and their output shown in your markdown file -- CommonMark specification is followed, so there is no special syntax that should break any markdown editor, renderer, or converter you want to use. It works best if your text editor supports smoothly reloading the file when a change is detected.

## What is it?

Markdown Notebook (mdnb) is a literate programming tool, inspired by the nifty [Emacs Babel Org Mode](https://orgmode.org/worg/org-contrib/babel/intro.html#org71e2aea). That is, instead of putting prose as comments into your source code, you can put source code into your prose, promoting better explanations, documentation, and readability. The use of markdown here allows for Emacs-like flexibility in handling various kinds of prose-level description formats like LaTeX, UML diagrams, and images (depending how you render or preview your markdown). I tried maybe 20 markdown editors, and while many work with basic editing, previewing, and reloading when changed, the [Zettlr](https://www.zettlr.com) Markdown Editor is the one I recommend for the best Jupyter Notebook-like experience. But a basic text editor like Vim also works well if you set it up to listen for file changes.

Related tools include:
* [Jupyter Notebooks](https://jupyter.org/)
* [VSCode Markdown Preview Enhanced Plugin Code Chunks](https://shd101wyy.github.io/markdown-preview-enhanced/#/code-chunk)
* [RStudio R-Markdown](https://rmarkdown.rstudio.com/lesson-3.html)
* [MDJS](https://medium.com/better-programming/introducing-mdjs-6bedba3d7c6f)
* [Hydrogen (Atom)](https://atom.io/packages/hydrogen)

## Why?

Jupyter Notebooks are great, but the software is gigantic, and the notebook files are not meant to be viewed directly as text files, making working with code versioning tools an annoying process. Also, you're beholden to whatever kernels exist to let your notebook know how to run your code. Why not use whatever you want for an editor and runnable languages?

## How does it work?

Markdown Notebook is not complicated. It works by running on the command line, and you telling it what markdown files you want it to watch for changes. When it detects a change, then it parses the file looking for runnable code chunks (markdown code fenced sections), runs the code, and shows the output if you've requested that, then refreshes your file with the modified content including code output.

Here are the steps:
* Wait for change before proceeding
* Parse markdown for code chunks
* Replace special keywords that expand to new code chunks or expand to a uri link
* Parse YAML header for supported languages in this file and how to run them
* Parse markdown for code chunks
* Only run code chunks if the resulting source files will change since last run
* Only run code chunks if the code chunk output does not exist as a file
* Show "(please wait") for output code chunks
* Run code chunks according to languages and commands described in YAML header
* Replace all output code chunks with the actual command output

## How to use it?

~~~
./mdnb myMarkdownFile.md (...more markdown files)
~~~

Then, open your markdown files in your favorite editor and `save` the file to update the code interpretation. Let's say you want to run bash and python code. You can make mdnb aware of such code blocks, and customize how that code is run through the YAML header. The full example is below, and the resulting transformed version is shown below that.

The frontmatter includes the ability to define different language codeblocks. The format is `code: <lang_name> <file_ext> <system_command>`
That is, the lang_name is the short name for the language, used possibly also conveniently as the code block markdown renderer syntax highlighting language name. file_ext is the file extension to use when saving to a temporary file in the current directory. system_command is the system command to which to pass the temporary filename to run the interpreter or compiler. The system_command may use `$1` as a placeholder for the source filename with its extension removed; each occurrence is replaced with that base path before running. This lets a single command both compile and run, e.g. `g++ -o $1.out $1.cpp && ./$1.out`. When `$1` is absent, the source filename is appended to the command (the default for interpreters like `python -OO`).

~~~
---
code: sh .sh sh
code: python .py "python -OO"
---

## Code Chunk Example

Some **Standard** Markdown

```sh output:bashdemo
echo "from the bash demo"
```

```show:bashdemo
```

``` python source:pydemo.py
# start of the python example code
from cowpy import cow
import text_to_image
from PIL import Image, ImageDraw, ImageFont
from resizeimage import resizeimage
import os
```

We can continue an explanation, and then add more code to a source file as we build our explanation.

```python source:pydemo.py output:pydemo.txt
msg = cow.Small().milk("mdnb!")
print(msg)
```

We can use the `show:file` shortcut directly; it will be replaced for us.

show:pydemo.txt

Let's save that out to an image too, and show it below

```python source:pydemo.py
image = Image.new(mode = "RGB", size = (200,200), color = "black")
draw = ImageDraw.Draw(image)
draw.text((10,10), msg, font=ImageFont.truetype('arial.ttf', 22), fill=(255,255,255))
image.save("cow.png") 
```

show:cow.png
~~~

When you save the the file, mdnb converts that to

~~~
---
code: sh .sh sh
code: python .py "python -OO"
---

## Code Chunk Example

Some **Standard** Markdown

```sh output:bashdemo
echo "from the bash demo"
```

```show:bashdemo
from the bash demo
```

``` python source:pydemo.py
# start of the python example code
from cowpy import cow
import text_to_image
from PIL import Image, ImageDraw, ImageFont
from resizeimage import resizeimage
import os
```

We can continue an explanation, and then add more code to a source file as we build our explanation.

```python source:pydemo.py output:pydemo.txt
msg = cow.Small().milk("mdnb!")
print(msg)
```

We can use the `show:file` shortcut directly; it will be replaced for us.

```show:pydemo.txt
 _______
< mdnb! >
 -------
       \   ,__,
        \  (oo)____
           (__)    )\
            ||--|| *
```

Let's save that out to an image too, and show it below

```python source:pydemo.py
image = Image.new(mode = "RGB", size = (200,200), color = "black")
draw = ImageDraw.Draw(image)
draw.text((10,10), msg, font=ImageFont.truetype('arial.ttf', 22), fill=(255,255,255))
image.save("cow.png") 
```

![cow.png](cow.png)
~~~

## Compiling

```sh
git clone https://github.com/JorySchossau/markdownNotebook
cd markdownNotebook
nim c mdnb
```
Done!

## Supported Commands

```
* CommonMark supported
* both code fences supported (```) and (~~~)

YAML Header Commands
* `code: id ext command
  id - the markdown language identifier you want to support in this file
  ext - the file extension of this filetype, used when saving source files
  command - the command to run for this filetype
    Use `$1` as a placeholder for the source filename without its extension
    (e.g. `g++ -o $1.out $1.cpp && ./$1.out`). When `$1` is absent, the source
    filename is appended to the command instead.

Code Fence Commands
* `source` - Run this block, autogenerate source filename, ignore output
* `source:filename` - Run this block, use `filename` as source filename
* `output:filename` - Run this block, saving output to `filename`, autogenerate source filename if `source` unspecified
* `show:filename` - display contents of file in block

Special Supported Language
* `raw` - may be used as the language of a code block, indicating no command to run, save to output if specified

Non-Code Fence Commands
* `show:filename` - replace this text with a markdown hyperlink to `filename` if image, or a codeblock if not an image
* `:clean` - on a line of its own. When mdnb next processes the file, this line is removed, every generated source and output file for the code cells in this file is deleted, and all cells are rerun from scratch. Use it to force a full fresh build; a normal save only reruns cells whose source or output is missing or would change.
```

## To-Do

The smaller-scope and architectural items that are ready to work on but are not
part of the core "Planned features" roadmap below.

- [x] Reimplement / Cleanup
- [x] Make non-code fence `show` command extension-aware and do the right thing
- [x] Make md filename part of temp filenames
- [x] **Modernize for current Nim** — the code is old relative to the latest compiler version; update to modern idioms.
- [x] **Memory model rewrite** — replace the `ptr ptr string` manual memory scheme with reallocated real strings. Currently, if the file content outgrows its allocated buffer, we must reallocate, copy, and free. This is the right fix but architectural.
- [x] **`$1` substitution in runtime commands** — allow variables like `g++ -o $1.out $1.cpp && ./$1.out` so compiled languages work cleanly.
- [ ] **Position cache for unchanged files** — cache the locations of codeblock starts so that if a file hasn't been edited since the last parse, mdnb can use cached positions to write outputs without re-scanning. If the file has been modified, fall back to full PEG parsing.

### Planned features

These features have been agreed as the next work. They are grouped by priority.

**Tier 1 — core workflow**
- [ ] Allow mutually exclusive `source:` vs `append:` codeblock commands. A cell with `source:filename` (as today) defines the single source file for its content. A cell with `append:filename` instead appends its content to the named source file, so several cells spread through the prose can all contribute to one source file. A cell must use exactly one of `source:` / `append:` (not both, not neither if the cell is runnable). This is the supported way to build up a program across multiple prose-separated blocks without persistent kernel state.

**Tier 2 — reliability**
- [ ] Only act on saves that are at least 1 second apart. If a save arrives less than 1s after the last processed save for that file, ignore it (debounce). Polling every 500ms stays; we will keep using mtime polling rather than native inotify/FSEvents watchers because they are system-limited and mdnb is cross-platform.
- [ ] Build a cell call-dependency graph. A cell should be considered dirty (and rerun) when a cell whose output it consumes changes, not only when its own source or output file is missing. Changing cell A should invalidate cells that depend on A's output.
- [ ] Implement asynchronous multithreaded execution so that a long-running cell does not block the watcher from parsing further saves. Introduce a new `[ ]` state field after the lang_name/id in the info string: states are `s`=stopped / `r`=running, and user can set `x`=execute / `k`=kill to control state.
- [ ] Add a `timeout:N` codeblock command to set a per-cell timeout in N seconds. If a cell exceeds its timeout it should be killed. If `timeout:` is unspecified, default to 5 seconds.

**Tier 3 — usability**
- [ ] Surface execution status in the output, e.g. for each run: which cell, the system command, the exit code, and how long it took. Add this as debug/verbose output alongside the existing run.
- [ ] Add a `trim:head:N` and `trim:tail:N` codeblock command to truncate output to the first or last N lines before it is written back. Default to `trim:head:50` so large outputs do not burden the source file or the mdnb server. This default applies when no `trim:` is given.
- [ ] Add an `unsafe` codeblock command. By default, refuse to run a cell whose command or content matches a destructive pattern (e.g. `rm -rf`, `mkfs`, force-format) and report it in the file. A cell marked `unsafe` opts in and will run regardless.
- [ ] Report errors on non-zero exit codes. When a system command does not exit cleanly, show the error in the resulting file so it will be displayed if the user created a `show:file` block for that output.

### Decisions recorded (not to do)
- Do **not** inline rich output by default. By default we should not show output; output only appears where the user explicitly requests it via `show:` / `output:`.
- Do **not** add native file watchers (inotify/FSEvents). Polling is fine and keeps mdnb cross-platform.
- Keep the current `:clean` behavior (documented above). No per-cell clear for now.
- Keep running cells in the current working directory; cells are responsible for their own environment variables if needed.
- No output-stripping/export pipeline, no multi-file project config, no shared cross-file runtimes for now.

## Bugs

Thar be bugs! Probably. Please file an issue if you find any.
