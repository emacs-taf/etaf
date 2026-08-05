EMACS ?= emacs
LOAD_PATH = -L . -L ../ebox
SOURCES = etaf-view.el etaf-component.el etaf-reactive.el etaf-context.el etaf-resource.el etaf-data.el etaf-renderer.el etaf-runtime.el etaf-behavior.el etaf-actions.el etaf-events.el etaf.el
TESTS = tests/etaf-tests.el tests/etaf-resource-tests.el tests/etaf-data-tests.el

.PHONY: test compile load checkdoc docs-check check clean

test: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval "(setq load-prefer-newer t)" -l tests/etaf-tests.el -l tests/etaf-resource-tests.el -l tests/etaf-data-tests.el \
		-f ert-run-tests-batch-and-exit

compile: clean
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval "(load-file \"etaf.el\")" \
		--eval "(dolist (file '(\"etaf-view.el\" \"etaf-component.el\" \"etaf-reactive.el\" \"etaf-context.el\" \"etaf-resource.el\" \"etaf-data.el\" \"etaf-renderer.el\" \"etaf-runtime.el\" \"etaf-behavior.el\" \"etaf-actions.el\" \"etaf-events.el\" \"etaf.el\")) (byte-compile-file file))"

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval "(setq load-prefer-newer t)" --eval "(require 'etaf)" --eval "(princ \"ETAF load OK\\n\")"

docs-check:
	$(EMACS) -Q --batch $(LOAD_PATH) --eval "(setq load-prefer-newer t)" -l tests/etaf-docs-tests.el \
		-f ert-run-tests-batch-and-exit

checkdoc:
	$(EMACS) -Q --batch --eval '(progn (require (quote checkdoc)) (dolist (file (directory-files "." t)) (when (string-suffix-p ".el" file) (checkdoc-file file))))'

check: checkdoc compile test docs-check

clean:
	rm -f *.elc tests/*.elc
