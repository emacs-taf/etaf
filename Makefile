.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
LOAD_PATH = -L . -L lisp -L examples -L scripts -L benchmarks -L ../ebox -L ../tp -L ../ecss
SOURCES = lisp/etaf-view.el lisp/etaf-compiler.el lisp/etaf-component.el lisp/etaf-scheduler.el lisp/etaf-reactive.el lisp/etaf-observer.el lisp/etaf-context.el lisp/etaf-theme-tp.el lisp/etaf-resource.el lisp/etaf-data.el lisp/etaf-generation.el lisp/etaf-host.el lisp/etaf-retirement.el lisp/etaf-render-port.el lisp/etaf-renderer.el lisp/etaf-runtime.el lisp/etaf-behavior.el lisp/etaf-actions.el lisp/etaf-events.el lisp/etaf-performance.el etaf.el scripts/emacs-gui-verifier.el benchmarks/benchmark-scheduler-context.el benchmarks/benchmark-ebox-resize.el
EXAMPLES = examples/etaf-counter-example.el examples/etaf-data-example.el examples/etaf-resource-example.el
TESTS = $(filter-out tests/etaf-docs-tests.el,$(wildcard tests/*-tests.el))

.PHONY: compile load checkdoc docs-check metadata-check scheduler-benchmark check clean

compile: clean
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval "(setq load-prefer-newer t byte-compile-error-on-warn t byte-compile-warnings '(not obsolete))" \
		--eval "(load-file \"etaf.el\")" \
		--eval "(dolist (file '($(foreach file,$(SOURCES) $(EXAMPLES),\"$(file)\"))) (unless (byte-compile-file file) (error \"Compilation failed: %s\" file)))"

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval "(setq load-prefer-newer t)" --eval "(require 'etaf)" --eval "(princ \"ETAF load OK\\n\")"

docs-check:
	$(EMACS) -Q --batch $(LOAD_PATH) --eval "(setq load-prefer-newer t)" -l tests/etaf-docs-tests.el \
		-f ert-run-tests-batch-and-exit

metadata-check:
	$(EMACS) -Q --batch --eval "(progn (require 'package) (with-temp-buffer (insert-file-contents \"etaf.el\") (let ((desc (package-buffer-info))) (unless (and (equal (package-desc-version desc) '(0 2 1)) (equal (package-desc-reqs desc) '((emacs (29 1)) (ebox (3 0 0)) (tp (2 0 0))))) (error \"Unexpected ETAF package metadata: %S\" desc)))))"

scheduler-benchmark:
	$(EMACS) -Q --batch $(LOAD_PATH) --eval "(setq load-prefer-newer t)" \
		-l benchmarks/benchmark-scheduler-context.el \
		-f etaf-scheduler-benchmark-run

checkdoc:
	$(EMACS) -Q --batch --eval '(progn (require (quote checkdoc)) (dolist (directory (list "lisp" "examples" "scripts")) (dolist (file (directory-files directory t)) (when (string-suffix-p ".el" file) (checkdoc-file file)))))'

check: structure-check compile acceptance api-check tool-check

.PHONY: tool-check gui-tool-check
tool-check:
	EMACS="$(EMACS)" python3 -m unittest discover -s tests/tools -p 'test_gui_scenarios.py'

gui-tool-check:
	EMACS="$(EMACS)" python3 -m unittest discover -s tests/tools -p 'test_*.py'

clean:
	rm -f *.elc lisp/*.elc examples/*.elc scripts/*.elc benchmarks/*.elc tests/*.elc

.PHONY: structure-check setup-hooks
structure-check:
	python3 scripts/check-repository.py
setup-hooks:
	git config --local core.hooksPath .githooks

.PHONY: acceptance
acceptance:
	python3 scripts/run-acceptance.py --emacs "$(EMACS)"

.PHONY: api-check
api-check:
	$(EMACS) -Q --batch -L . $(API_PROVIDER_PATH) --eval '(setq load-prefer-newer t)' -l scripts/check-api.el
API_PROVIDER_PATH = -L ../ecss -L ../tp -L ../ekp -L ../ebox -L ../etaf-ui -L ../etaf-db -L ../ebox-playground -L ../etaf-playground

.PHONY: test
test: acceptance
