Markdown Notebook is an editor-agnostic Jupyter Notebook-like experience for your markdown files. Code chunks are run and their output shown in your markdown file -- which is ready to be rendered to any format at publication time using any markdown renderer. It works best if your text editor supports smoothly reloading the file when a change is detected.

## What is it?

Markdown Notebook (mdnb) is a literate programming tool, inspired by the nifty [Emacs Babel Org Mode](https://orgmode.org/worg/org-contrib/babel/intro.html#org71e2aea). That is, instead of putting prose as comments into your source code, you can put source code into your prose, promoting better explanations, documentation, and readability. The use of markdown here allows for Emacs-like flexibility in handling various kinds of prose-level description formats like LaTeX, UML diagrams, and images (depending how you render or preview your markdown). I tried maybe 20 markdown editors, and while many work with basic editing, previewing, and reloading when changed, the [Zettlr](https://www.zettlr.com) Markdown Editor is the one I recommend for the best Jupyter Notebook-like experience. But a basic text editor like Vim also works well if you set it up to listen for file changes.

Other similar tools include:
* [Jupyter Notebooks](https://jupyter.org/)
* [VSCode Markdown Preview Enhanced Plugin Code Chunks](https://shd101wyy.github.io/markdown-preview-enhanced/#/code-chunk)
* [RStudio R-Markdown](https://rmarkdown.rstudio.com/lesson-3.html)
* [MDJS](https://medium.com/better-programming/introducing-mdjs-6bedba3d7c6f)
* [Hydrogen (Atom)](https://atom.io/packages/hydrogen)

## Why?

Jupyter Notebooks are great, but the software is gigantic, and the notebook files are not meant to be viewed directly as text files, making working with code versioning tools an annoying process. Also, you're beholden to whatever kernels exist to let your notebook know how to run your code. Why not let use whatever you want for an editor and runnable languages?

## How does it work?

Markdown Notebook is not complicated. It works by running on the command line, and you telling it what markdown files you want it to watch for changes. When it detects a change, then it parses the file looking for runnable code chunks (markdown code fenced sections), runs the code, and shows the output if you've requested that, then refreshes your file with the modified content including code output.

Here are the steps:
* Wait for change before proceeding
* Parse YAML header for supported languages in this file and how to run them
* Parse markdown for code chunks
* Only run code chunks if the resulting source files will change since last run
* Only run code chunks if the code chunk output does not exist as a file
* Show "(please wait") for output code chunks
* Run code chunks according to languages and commands described in YAML header
* Replace all output code chunks with the actual command output
* Replace all non-code chunk output shortcuts with a link to the actual file

## How to use it?

~~~
./mdnb myMarkdownFile.md (...more markdown files)
~~~

Then, let's say you want to run bash and python code. You can make mdnb aware of such code blocks, and customize how that code is run through the YAML header. The full example is below, and the resulting transformed version is shown below that.

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

```show:pydemo.txt
```

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

## Supported Commands

```
* CommonMark supported
* both code fences supported (```) and (~~~)

YAML Header Commands
* `code: id ext command
  id - the markdown language identifier you want to support in this file
  ext - the file extension of this filetype, used when saving source files
  command - the command to run for this filetype

Code Fence Commands
* `source` - Run this block, autogenerate source filename, ignore output
* `source:filename` - Run this block, use `filename` as source file
* `output:filename` - Run this block, saving output to `filename`, autogenerate source filename if unspecified
* `show:filename` - display contents of file in block

Special Supported Language
* `raw` - may be used as the language of a code block, indicating no command to run, save to output if specified

Non-Code Fence Commands
* `show:filename` - replace this text with a markdown hyperlink to `filename`
```

### To-Do
- [ ] Reimplement / Cleanup
- [ ] Make md filename part of temp filenames
- [ ] CI releases when stable
- [ ] Make non-code fence show command extension-aware and do the right thing
