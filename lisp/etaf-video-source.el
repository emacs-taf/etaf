;;; etaf-video-source.el --- Frame producers for native video -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Source normalization, ffprobe metadata, the ffmpeg argument contract, and
;; the process filter that keeps the newest complete frame.  A producer feeds
;; either fixed-size raw frames (gray or RGB24) or a stream of JPEG images
;; delimited by their SOI and EOI markers.  No buffer or Runtime state lives
;; here; `etaf-video-session' owns the playback state machine.

;;; Code:

(require 'cl-lib)

(defvar etaf-video-ffmpeg-program "ffmpeg"
  "Name or absolute path of the ffmpeg executable.
Point it at a wrapper script to add decoder options; ETAF appends the filter
and output arguments described in the manual.")

(defvar etaf-video-ffprobe-program "ffprobe"
  "Name or absolute path of the ffprobe executable.
Missing metadata degrades to documented defaults instead of failing.")

(cl-defstruct (etaf-video--source (:constructor etaf-video--source--make))
  "A running frame producer."
  process pipe width height frame-size carry latest received dropped ended exit mjpeg-p)

(defun etaf-video--probe-values (program &rest arguments)
  "Run PROGRAM with ARGUMENTS and return its key=value output as a table."
  (let ((values (make-hash-table :test #'equal)))
    (dolist (line (ignore-errors (apply #'process-lines program arguments)))
      (when (string-match "\\`\\([^=]+\\)=\\(.+\\)\\'" line)
        (puthash (match-string 1 line) (match-string 2 line) values)))
    values))

(defun etaf-video--probe-number (values key)
  "Return VALUES's KEY as a positive number, or nil."
  (let ((text (gethash key values)))
    (when (and (stringp text) (string-match-p "\\`[0-9.]+\\'" text))
      (let ((number (string-to-number text)))
        (when (> number 0) number)))))

(defun etaf-video--probe (target)
  "Return TARGET's metadata plist from ffprobe, or nil.
TARGET is a local file name or an HTTP(S) URL.  The result holds `:width',
`:height', `:fps', `:duration' and `:audio', each nil when the source does not
report it."
  (when-let* ((program (executable-find etaf-video-ffprobe-program)))
    (let* ((video (apply #'etaf-video--probe-values
                         program "-v" "error" "-select_streams" "v:0"
                         "-show_entries" "stream=width,height,r_frame_rate"
                         "-of" "default=nw=1"
                         (list target)))
           (meta (apply #'etaf-video--probe-values
                        program "-v" "error"
                        "-show_entries" "format=duration"
                        "-of" "default=nw=1"
                        (list target)))
           (audio (apply #'etaf-video--probe-values
                         program "-v" "error" "-select_streams" "a:0"
                         "-show_entries" "stream=index"
                         "-of" "default=nw=1"
                         (list target)))
           (rate (gethash "r_frame_rate" video)))
      (list :width (etaf-video--probe-number video "width")
            :height (etaf-video--probe-number video "height")
            :duration (etaf-video--probe-number meta "duration")
            :fps (when (and (stringp rate)
                            (string-match "\\`\\([0-9.]+\\)/\\([0-9.]+\\)\\'" rate))
                   (let ((frames (string-to-number (match-string 1 rate)))
                         (seconds (string-to-number (match-string 2 rate))))
                     (when (> seconds 0) (/ frames seconds))))
            :audio (and (gethash "index" audio) t)))))

(defun etaf-video--url-p (source)
  "Return non-nil when SOURCE is an HTTP or HTTPS URL string."  (and (stringp source)
       (string-match-p "\\`https?://[^[:space:]]+\\'" source)))

(cl-defun etaf-video--normalize-source (source)
  "Return SOURCE as a normalized plist, or signal `user-error'.
SOURCE is nil for the built-in demo, a file name or HTTP(S) URL string, or a
plist:

  (:file PATH)   a local video file; ffprobe supplies its metadata
  (:url URL)     an HTTP(S) video stream decoded directly by ffmpeg
  (:demo)        a generated 30 second test pattern, no file needed

A plist that already carries `:kind' is treated as authoritative metadata, as
returned by `etaf-video-source-info', so callers that probed once can mount
without another probe.

The result holds `:kind', `:file', `:url', `:target', `:width', `:height',
`:duration', `:fps' (source rate) and `:audio' (whether the source reports an
audio stream)."
  (let (kind file url)
    (cond ((and (consp source) (plist-member source :kind))
           (setq kind (plist-get source :kind)
                 file (plist-get source :file)
                 url (plist-get source :url))
           (unless (memq kind '(file url demo))
             (user-error "Unsupported etaf-video source kind: %S" kind)))
          ((null source) (setq kind 'demo))
          ((etaf-video--url-p source) (setq kind 'url url source))
          ((stringp source) (setq kind 'file file source))
          ((and (consp source) (eq (car source) :demo)) (setq kind 'demo))
          ((and (consp source) (plist-get source :demo)) (setq kind 'demo))
          ((and (consp source) (plist-get source :url))
           (setq kind 'url url (plist-get source :url)))
          ((and (consp source) (plist-get source :file))
           (setq kind 'file file (plist-get source :file)))
          (t (user-error "Unsupported etaf-video source: %S" source)))
    (when (eq kind 'file)
      (unless (and (stringp file) (file-readable-p file))
        (user-error "Video file is not readable: %S" file)))
    (when (eq kind 'url)
      (unless (etaf-video--url-p url)
        (user-error "Video URL must be http or https: %S" url)))
    (if (and (consp source) (plist-member source :kind))
        (list :kind kind
              :file file
              :url url
              :target (or file url)
              :width (plist-get source :width)
              :height (plist-get source :height)
              :duration (plist-get source :duration)
              :fps (plist-get source :fps)
              :audio (and (plist-get source :audio) t))
      (let* ((probe (and (memq kind '(file url)) (etaf-video--probe (or file url))))
             (width (or (and (memq kind '(file url)) (plist-get probe :width))
                        (plist-get source :width) 640))
             (height (or (and (memq kind '(file url)) (plist-get probe :height))
                         (plist-get source :height) 360))
             (duration (or (and (memq kind '(file url)) (plist-get probe :duration))
                           (plist-get source :duration)
                           (and (eq kind 'demo) 30)))
             (fps (or (and (memq kind '(file url)) (plist-get probe :fps))
                      (plist-get source :fps)
                      (and (eq kind 'demo) 30)
                      25))
             (audio (if (eq kind 'demo)
                        nil
                      (or (and probe (plist-get probe :audio))
                          (plist-get source :audio)))))
        (list :kind kind
              :file file
              :url url
              :target (or file url)
              :width width
              :height height
              :duration duration
              :fps fps
              :audio audio)))))

;;;###autoload
(defun etaf-video-source-info (source)
  "Return SOURCE's normalized playback metadata as a plist.

SOURCE is nil for the built-in demo, a local file name, an HTTP(S) URL, or a
plist accepted by the `etaf-video' Component (`:file', `:url' or `:demo').
The result holds `:kind', `:file', `:url', `:target', `:width', `:height',
`:duration', `:fps' (source rate) and `:audio' (whether the source reports an
audio stream).  Values come from ffprobe when it runs; a missing ffprobe
keeps documented defaults.  Unsupported sources and unreadable files signal
`user-error'.  Each call probes the source; the result is authoritative
metadata that can be passed back as the Component's `:src' without another
probe, so an application that resizes or restarts a video keeps them."
  (etaf-video--normalize-source source))

(defun etaf-video--ffmpeg-arguments (spec format width height speed start)
  "Return ffmpeg arguments for SPEC producing FORMAT frames.
WIDTH and HEIGHT are the frame dimensions (pixels for raw and JPEG output).
SPEED is the `-readrate' factor and START the seek position in seconds."
  (append (list "-hide_banner" "-loglevel" "error")
          (when (and (numberp start) (> start 0))
            (list "-ss" (number-to-string start)))
          (list "-readrate" (number-to-string speed))
          (pcase (plist-get spec :kind)
            ('file (list "-i" (plist-get spec :file)))
            ('url (list "-reconnect" "1" "-reconnect_streamed" "1"
                        "-reconnect_delay_max" "5"
                        "-i" (plist-get spec :url)))
            ('demo (list "-f" "lavfi" "-i" "testsrc2=size=640x360:rate=30" "-t" "30"))
            (_ (user-error "Cannot build ffmpeg arguments for %S" spec)))
          (pcase format
            ('mjpeg
             (list "-vf" (format "scale=%d:%d:flags=lanczos" width height)
                   "-q:v" "3"
                   "-f" "image2pipe" "-c:v" "mjpeg" "-"))
            ('rgb24
             (list "-vf" (format "scale=%d:%d:flags=area" width height)
                   "-f" "rawvideo" "-pix_fmt" "rgb24" "-"))
            (_
             (list "-vf" (format "scale=%d:%d:flags=area" width height)
                   "-f" "rawvideo" "-pix_fmt" "gray" "-")))))

(defun etaf-video--source-filter (process chunk)
  "Accumulate CHUNK into complete frames; the newest complete frame wins.
Raw frames are cut at their fixed byte length; JPEG frames are complete images
delimited by SOI and EOI markers."
  (let ((source (process-get process 'etaf-video-source)))
    (when source
      (let ((data (concat (etaf-video--source-carry source) chunk))
            (frame nil))
        (if (etaf-video--source-mjpeg-p source)
            (let ((soi (string-search "\xff\xd8" data))
                  (eoi nil))
              (when soi
                (setq eoi (string-search "\xff\xd9" data (1+ soi))))
              (while (and soi eoi)
                (setq frame (substring data soi (+ eoi 2))
                      data (substring data (+ eoi 2))
                      soi (string-search "\xff\xd8" data)
                      eoi (and soi (string-search "\xff\xd9" data (1+ soi))))))
          (let ((size (etaf-video--source-frame-size source)))
            (while (>= (length data) size)
              (setq frame (substring data 0 size)
                    data (substring data size)))))
        (when frame
          (when (etaf-video--source-latest source)
            (cl-incf (etaf-video--source-dropped source)))
          (setf (etaf-video--source-latest source) frame)
          (cl-incf (etaf-video--source-received source)))
        (setf (etaf-video--source-carry source) data)))))

(defun etaf-video--source-sentinel (process _event)
  "Mark PROCESS's source ended when the producer really terminated.
Stop and continue events leave the producer running and are ignored."
  (let ((source (process-get process 'etaf-video-source)))
    (when (and source (not (process-live-p process)))
      (setf (etaf-video--source-ended source) t)
      (setf (etaf-video--source-exit source)
            (condition-case nil (process-exit-status process) (error nil))))))

(cl-defun etaf-video--source-start (spec format width height &key speed start)
  "Start a producer for normalized SPEC, FORMAT, WIDTH and HEIGHT.
SPEED defaults to 1 and START to 0.  Return the new source; a missing ffmpeg
signals `user-error' before any process exists."
  (let* ((program (or (executable-find etaf-video-ffmpeg-program)
                      (user-error "ffmpeg is not available: %s"
                                  etaf-video-ffmpeg-program)))
         (mjpeg (eq format 'mjpeg))
         (frame-size (pcase format
                       ('rgb24 (* width height 3))
                       ('mjpeg 0)
                       (_ (* width height))))
         (pipe (generate-new-buffer " *etaf-video pipe*"))
         (process (make-process
                   :name "etaf-video"
                   :command (cons program
                                  (etaf-video--ffmpeg-arguments
                                   spec format width height (or speed 1) (or start 0)))
                   :buffer pipe
                   :coding '(no-conversion . no-conversion)
                   :connection-type 'pipe
                   :noquery t
                   :filter #'etaf-video--source-filter
                   :sentinel #'etaf-video--source-sentinel)))
    (let ((source (etaf-video--source--make
                   :process process :pipe pipe
                   :width width :height height :frame-size frame-size
                   :carry "" :latest nil :received 0 :dropped 0
                   :mjpeg-p mjpeg)))
      (process-put process 'etaf-video-source source)
      source)))

(defun etaf-video--source-claim (source)
  "Return SOURCE's newest complete frame, clearing it, or nil.
The frame is a unibyte string of raw pixels or one complete JPEG image."
  (when-let* ((frame (etaf-video--source-latest source)))
    (setf (etaf-video--source-latest source) nil)
    frame))

(defun etaf-video--source-close (source)
  "Terminate SOURCE's producer and release its buffer."
  (let ((process (etaf-video--source-process source)))
    (when (process-live-p process) (delete-process process)))
  (when (buffer-live-p (etaf-video--source-pipe source))
    (kill-buffer (etaf-video--source-pipe source))))

(provide 'etaf-video-source)
;;; etaf-video-source.el ends here
