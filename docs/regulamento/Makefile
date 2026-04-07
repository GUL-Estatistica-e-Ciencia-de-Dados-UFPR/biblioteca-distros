##=============================================================================
## Makefile — GULECD/UFPR Documentos Institucionais
##=============================================================================
## Alvos:
##   make all     — gera PDF, HTML e Markdown para todos os arquivos .tex
##   make pdf     — gera apenas os PDFs
##   make html    — gera apenas os HTMLs
##   make md      — gera apenas os Markdowns
##   make clean   — remove arquivos intermediários de compilação
##   make distclean — remove também os arquivos gerados (pdf, html, md)
##=============================================================================

# Descobre automaticamente todos os arquivos .tex do diretório
TEX_FILES := $(wildcard *.tex)

# Arquivos de saída derivados
PDF_FILES := $(TEX_FILES:.tex=.pdf)
HTML_FILES := $(TEX_FILES:.tex=.html)
MD_FILES := $(TEX_FILES:.tex=.md)

# Compilador LaTeX e opções
LATEX := pdflatex
LATEX_OPTS := -interaction=nonstopmode -halt-on-error

# Pandoc e opções comuns
PANDOC := pandoc
PANDOC_OPTS := --standalone --toc

# Opções específicas para HTML
PANDOC_HTML_OPTS := --to=html5 --css=style.css --self-contained 2>/dev/null || $(PANDOC) --to=html5 --toc

# Opções específicas para Markdown
PANDOC_MD_OPTS := --to=gfm

#=============================================================================
# Alvos
#=============================================================================
.PHONY: all pdf html md clean distclean

all: pdf html md

#--- PDF (compila duas vezes para resolver referências cruzadas) ----------------
pdf: $(PDF_FILES)

%.pdf: %.tex
	@echo "==> Gerando PDF: $<"
	$(LATEX) $(LATEX_OPTS) $< >/dev/null 2>&1 || true
	$(LATEX) $(LATEX_OPTS) $< >/dev/null 2>&1
	@echo "    OK: $@"

#--- HTML via Pandoc -----------------------------------------------------------
html: $(HTML_FILES)

%.html: %.tex
	@echo "==> Gerando HTML: $<"
	$(PANDOC) $(PANDOC_OPTS) --to=html5 $< -o $@ 2>/dev/null
	@echo "    OK: $@"

#--- Markdown via Pandoc -------------------------------------------------------
md: $(MD_FILES)

%.md: %.tex
	@echo "==> Gerando Markdown: $<"
	$(PANDOC) $(PANDOC_OPTS) --to=gfm $< -o $@ 2>/dev/null
	@echo "    OK: $@"

#--- Limpeza de arquivos intermediários ----------------------------------------
INTERMEDIATE_EXTS := aux log toc out nav snm vrb bbl blg idx ilg ind \
                     lof lot lol lsf run.xml synctex.gz tdo xdv \
                     fls fdb_latexmk pdfsync dvi ps thm alg

clean:
	@echo "==> Limpando arquivos intermediários..."
	@for ext in $(INTERMEDIATE_EXTS); do \
		rm -f *.$$ext; \
	done
	@rm -f *.tex~ *.bak
	@echo "    Concluído."

#--- Limpeza total (remove também os arquivos gerados) -------------------------
distclean: clean
	@echo "==> Removendo arquivos gerados (pdf, html, md)..."
	@rm -f $(PDF_FILES) $(HTML_FILES) $(MD_FILES)
	@echo "    Concluído."
