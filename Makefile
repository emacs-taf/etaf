.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
LOAD_PATH = -L . -L examples -L scripts -L benchmarks -L ../ebox -L ../tp -L ../ecss
SOURCES = etaf-view.el etaf-compiler.el etaf-component.el etaf-scheduler.el etaf-reactive.el etaf-observer.el etaf-context.el etaf-theme-tp.el etaf-resource.el etaf-data.el etaf-generation.el etaf-host.el etaf-retirement.el etaf-render-port.el etaf-renderer.el etaf-runtime.el etaf-behavior.el etaf-actions.el etaf-events.el etaf-performance.el etaf.el scripts/emacs-gui-verifier.el benchmarks/benchmark-scheduler-context.el benchmarks/benchmark-ebox-resize.el
EXAMPLES = examples/etaf-counter-example.el examples/etaf-data-example.el examples/etaf-resource-example.el
TESTS = $(filter-out tests/etaf-docs-tests.el,$(wildcard tests/*-tests.el))

.PHONY: test compile load checkdoc docs-check metadata-check scheduler-benchmark resize-benchmark-tests check clean

test: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval "(setq load-prefer-newer t)" \
		$(foreach test,$(TESTS),-l $(test)) \
		-f ert-run-tests-batch-and-exit

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

resize-benchmark-tests:
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t)' \
		-l tests/etaf-resize-benchmark-tests.el -f ert-run-tests-batch-and-exit

checkdoc:
	$(EMACS) -Q --batch --eval '(progn (require (quote checkdoc)) (dolist (directory (list "." "examples" "scripts")) (dolist (file (directory-files directory t)) (when (string-suffix-p ".el" file) (checkdoc-file file)))))'

check: structure-check compile acceptance

clean:
	rm -f *.elc examples/*.elc scripts/*.elc benchmarks/*.elc tests/*.elc

.PHONY: structure-check setup-hooks
structure-check:
	python3 scripts/check-repository.py
setup-hooks:
	git config --local core.hooksPath .githooks

.PHONY: acceptance
acceptance:
	python3 scripts/run-acceptance.py --emacs "$(EMACS)"
