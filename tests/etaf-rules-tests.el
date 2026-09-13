;;; etaf-rules-tests.el --- Shared component rule validation -*- lexical-binding: t; -*-

;;; Commentary:
;; Component style replacement validates before changing supported output.

;;; Code:
(require 'ert)
(require 'etaf)
(require 'ebox)

(etaf-define-component etaf-test-rules ()
  :styles (("&" :color "#ff0000"))
  :view (text "Rules"))

(ert-deftest etaf-component-rule-replacement-validates-before-mutation ()
  "Plain rule replacement shares schema validation and preserves prior rules on error."
  (unwind-protect
      (progn
        (etaf-component-set-styles 'etaf-test-rules '(("&" :color "#00ff00")))
        (should (equal (plist-get (get-text-property
                                  0 'face (ebox-render (etaf-render (etaf-view (etaf-test-rules)))))
                                 :foreground) "#00ff00"))
        (dolist (rules '((("&" :not-an-ebox-property t))
                         (("[" :color "#ff0000"))
                         (("&" :color))))
          (should-error (etaf-component-set-styles 'etaf-test-rules rules)
                        :type 'etaf-component-definition-error)
          (should (equal (plist-get (get-text-property
                                    0 'face (ebox-render (etaf-render (etaf-view (etaf-test-rules)))))
                                   :foreground) "#00ff00")))
        (etaf-component-set-styles 'etaf-test-rules nil)
        (should-not (equal (plist-get (get-text-property
                                      0 'face (ebox-render (etaf-render (etaf-view (etaf-test-rules)))))
                                     :foreground) "#00ff00")))
    (etaf-component-set-styles 'etaf-test-rules '(("&" :color "#ff0000")))))

(provide 'etaf-rules-tests)
;;; etaf-rules-tests.el ends here
