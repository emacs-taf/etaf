EMACS ?= emacs
LOAD_PATH = -L . -L examples -L scripts -L ../ebox -L ../tp -L ../ecss
SOURCES = etaf-view.el etaf-compiler.el etaf-component.el etaf-reactive.el etaf-observer.el etaf-context.el etaf-theme-tp.el etaf-resource.el etaf-data.el etaf-generation.el etaf-render-port.el etaf-renderer.el etaf-runtime.el etaf-behavior.el etaf-actions.el etaf-events.el etaf-performance.el etaf.el scripts/emacs-gui-verifier.el
EXAMPLES = examples/etaf-counter-example.el examples/etaf-data-example.el examples/etaf-resource-example.el
TESTS = tests/etaf-tests.el tests/etaf-compiler-tests.el tests/etaf-component-frontends-tests.el tests/etaf-resource-tests.el tests/etaf-data-tests.el tests/etaf-theme-tp-tests.el tests/etaf-examples-tests.el tests/etaf-observer-tests.el tests/etaf-performance-tests.el tests/etaf-gui-verifier-tests.el tests/etaf-m0a-current-characterization-tests.el tests/etaf-interaction-contract-tests.el tests/etaf-m0b-component-manifest-tests.el tests/etaf-render-port-tests.el tests/etaf-generation-tests.el

.PHONY: test compile load checkdoc docs-check check clean

test: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval "(setq load-prefer-newer t)" \
		$(foreach test,$(TESTS),-l $(test)) \
		-f ert-run-tests-batch-and-exit

compile: clean
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval "(setq load-prefer-newer t byte-compile-error-on-warn t byte-compile-warnings '(not obsolete))" \
		--eval "(load-file \"etaf.el\")" \
		--eval "(dolist (file '($(foreach file,$(SOURCES) $(EXAMPLES),\"$(file)\"))) (byte-compile-file file))"

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval "(setq load-prefer-newer t)" --eval "(require 'etaf)" --eval "(princ \"ETAF load OK\\n\")"

docs-check:
	$(EMACS) -Q --batch $(LOAD_PATH) --eval "(setq load-prefer-newer t)" -l tests/etaf-docs-tests.el \
		-f ert-run-tests-batch-and-exit

checkdoc:
	$(EMACS) -Q --batch --eval '(progn (require (quote checkdoc)) (dolist (directory (list "." "examples" "scripts")) (dolist (file (directory-files directory t)) (when (string-suffix-p ".el" file) (checkdoc-file file)))))'

check: checkdoc compile test docs-check

clean:
	rm -f *.elc examples/*.elc scripts/*.elc tests/*.elc
