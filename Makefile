EMACS ?= emacs
LOAD_PATH = -L . -L ../emacs-box
SOURCES = etaf-view.el etaf-component.el etaf-renderer.el etaf.el

.PHONY: test compile check clean

test:
	$(EMACS) -Q --batch $(LOAD_PATH) -l tests/etaf-tests.el \
		-f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval "(dolist (file '(\"etaf-view.el\" \"etaf-component.el\" \"etaf-renderer.el\" \"etaf.el\")) (byte-compile-file file))"

check: compile test

clean:
	rm -f *.elc tests/*.elc
