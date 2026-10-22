;;; reddigg.el --- A reader for redditt -*- lexical-binding: t; -*-
;; Copyright (C) 2021  Thanh Vuong

;; Author: Thanh Vuong <thanhvg@gmail.com>
;; URL: https://github.com/thanhvg/emacs-reddigg
;; Package-Requires: ((emacs "26.3") (promise "1.1") (ht "2.3") (org "9.2") (json "1.4"))
;; Version: 0.9.0

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;; This package allows you to browse reddit in org-mode.
;;
;; Reddit now requires a logged-in, browser-driven session for its
;; JSON endpoints, so reddigg no longer talks to old.reddit.com
;; directly.  Instead it talks to a small local Python server (see
;; server/reddigg_server.py) over a simple HTTP/REST API.  That server
;; relays requests to a reddit tab running the reddigg userscript,
;; which is the only thing with the user's real, logged-in session.
;; You must:
;;   1. Have the Python dependencies ready (see server/pyproject.toml).
;;      The server itself is started automatically as an Emacs
;;      subprocess on the first request; see `reddigg-server-autostart',
;;      `reddigg-server-start' and `reddigg-server-stop'.  There is no
;;      separate server to launch by hand.
;;   2. Load userscript/reddigg-ws.user.js in your browser and be
;;      logged into old.reddit.com there.
;; The server listens on a single port (1979) for both the userscript's
;; websocket and Emacs's REST requests.  REST requests are authenticated
;; with a token the server stores in `reddigg-token-file'.
;; See `reddigg-server-url' to point Emacs at a non-default host/port,
;; and `reddigg-ping' to check that the whole chain
;; (Emacs -> server -> browser tab) is working.
;;
;; Buffers:
;; There are three buffers which are on org-mode. They show links and elisp
;; commands which will run when you enter/click (org-open-at-point) on them.
;; *reddigg-main*: show your subreddit list, enter on them will fetch the
;; subreddit posts and show them on *reddigg*. On *reddigg* when you enter on a
;; post will fetch the comments and show them on *reddigg-comments* buffer.
;;
;; Variables:
;; reddigg-subs: list of subreddits you want to show on *reddigg-main*
;;
;; * Commands
;; reddigg-view-main: show your subreddit list in *reddigg-main*, r/all and
;; r/popular are included.
;;
;; reddigg-view-sub: prompt for a subreddits and show it,
;;
;; reddigg-view-frontpage: view frontpage
;;
;; reddigg-view-comments: prompt for a post (eg:
;; r/emacs/comments/lfww57/weekly_tipstricketc_thread/ or
;; https://old.reddit.com/r/emacs/comments/lfww57/weekly_tipstricketc_thread/)
;; and show it.
;;
;; reddigg-ping: check the server and the browser tab are reachable.
;;
;; reddigg-server-start: start the relay server explicitly (normally it
;; starts by itself on the first request; see `reddigg-server-autostart').
;;
;; reddigg-server-stop: stop a server that reddigg started.
;;
;; reddigg-refresh-session: re-read the logged-in username from the tab.
;;
;; reddigg-show-images: download and show the images of the entry at point.
;;
;; reddigg-play-video: play the video attached to the entry at point.  A
;; video post's poster is shown inline like an image, with a play badge
;; baked into it; RET or a mouse click on the poster plays it too.  The
;; player streams the URL, and its error output goes to *reddigg-video*.
;;
;; reddigg-toggle-images: show or hide inline images in a buffer.
;;
;; reddigg-clear-image-cache: delete cached images (default
;; ~/.cache/reddigg/images).
;;
;; * Interaction (in the generated buffers, `reddigg-view-mode')
;; C-c C-v u / d / 0   upvote / downvote / clear vote
;; C-c C-v r           reply
;; C-c C-v e           edit your own post/comment
;; C-c C-v x           delete your own post/comment
;; C-c C-v i           show the images of the entry at point
;; C-c C-v I           toggle inline images in the buffer
;; C-c C-v v           play the video of the entry at point
;; `reddigg-submit-post' creates a new submission.

;;; Code:

(require 'promise)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'ht)
(require 'org)
(require 'json)
(require 'url)
(require 'url-http)
(require 'image)

(defgroup reddigg nil
  "Search and read stackoverflow and sisters's sites."
  :group 'convenience
  :link '(emacs-commentary-link "reddigg.el"))

(defcustom reddigg-subs '(acmilan emacs starcraft)
  "List of subreddits."
  :type 'list
  :group 'reddigg)

(defcustom reddigg-server-url "http://127.0.0.1:1979/reddigg"
  "Base URL of the reddigg HTTP/REST server.
The server (see server/reddigg_server.py) relays requests to a reddit
tab running userscript/reddigg-ws.user.js.  The default matches the
server's default --port (1979), which serves both REST and websocket.

When `reddigg-server-autostart' is non-nil, the host and port in this
URL are also used to start the server."
  :type 'string
  :group 'reddigg)

(defcustom reddigg-token-file
  (or (getenv "REDDIGG_TOKEN_FILE")
      (expand-file-name "reddigg/token"
                        (or (getenv "XDG_CONFIG_HOME") "~/.config")))
  "File holding the secret token the reddigg server requires.
The server creates this file (mode 0600) on first start; it is sent
as the X-Bridge-Token header on every request."
  :type 'file
  :group 'reddigg)

(defcustom reddigg-request-timeout 35
  "Seconds to wait for a single reddigg HTTP request to complete."
  :type 'number
  :group 'reddigg)

(defconst reddigg--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing reddigg.el.")

(defcustom reddigg-server-directory
  (expand-file-name "server" reddigg--directory)
  "Directory containing reddigg_server.py."
  :type 'directory
  :group 'reddigg)

(defcustom reddigg-server-autostart t
  "Whether reddigg starts the relay server automatically.
When non-nil, the first request starts server/reddigg_server.py as an
Emacs subprocess and waits for it to accept connections.  Set this to
nil if you prefer to run the server yourself."
  :type 'boolean
  :group 'reddigg)

(defcustom reddigg-server-command nil
  "Command and arguments used to start the relay server.
The command runs in `reddigg-server-directory'.  Each element may
contain \"%h\" and \"%p\", which are replaced with the host and port
from `reddigg-server-url'.

When nil, reddigg uses the virtualenv in `reddigg-server-directory'
if it exists, then `uv run', then `python3'."
  :type '(repeat string)
  :group 'reddigg)

(defcustom reddigg-server-startup-timeout 30
  "Seconds to wait for a newly started relay server to accept connections."
  :type 'number
  :group 'reddigg)

(defcustom reddigg-server-stop-on-exit t
  "Whether to stop a server started by reddigg when Emacs exits.
A server that was already running before reddigg started one is never
stopped.  Set this to nil if several Emacs instances share a server."
  :type 'boolean
  :group 'reddigg)

(defvar reddigg--modhash nil
  "Cached CSRF modhash scraped from the reddit tab (informational only;
the server/userscript attaches the modhash to state-changing requests).")

(defvar reddigg--current-user nil
  "Cached logged-in reddit username, scraped from the reddit tab.")

(defvar-local reddigg--render-generation 0
  "Counter bumped each time a reddigg buffer is fully re-rendered.
Background image downloads compare it with the value they captured so
that an image from an old listing cannot be inserted into a new one.")

(defvar-local reddigg--image-anchors nil
  "Alist of (REDDIT-FULLNAME . MARKER) where an entry's images go.")

(defvar-local reddigg--image-jobs nil
  "Hash table mapping (FULLNAME GENERATION) to `loading' or `done'.
It keeps `reddigg-show-images' from scheduling the same entry twice.")

(defvar-local reddigg--images-hidden nil
  "Non-nil when the user hid inline images in this buffer.")

(defconst reddigg--json-false :reddigg-false
  "Sentinel representing JSON `false', kept distinct from `null'/missing
when parsing reddit API responses. Needed for fields like \"likes\",
where true = upvoted, this sentinel = downvoted, and nil = no vote /
not present -- collapsing false and null together (the old behavior)
made \"downvoted\" indistinguishable from \"never voted\".")

(defun reddigg--parse-json-string (text)
  "Parse JSON TEXT the way reddit's API responses should be read:
hash-tables for objects, nil for JSON null, and `reddigg--json-false'
for JSON false."
  (if (fboundp 'json-parse-string)
      (json-parse-string text
                          :object-type 'hash-table
                          :null-object nil
                          :false-object reddigg--json-false)
    (let ((json-array-type 'vector)
          (json-object-type 'hash-table)
          (json-false reddigg--json-false))
      (json-read-from-string text))))

(defun reddigg--parse-json-buffer ()
  "Read json from the current buffer (from point to the end)."
  (reddigg--parse-json-string
   (buffer-substring-no-properties (point) (point-max))))

(defun reddigg--reason-string (reason)
  "Turn a promise rejection REASON into a printable string.
Reasons are either plain strings (from the HTTP layer) or Lisp error
objects such as (error \"msg\") or (user-error \"msg\")."
  (cond ((stringp reason) reason)
        ((and (consp reason) (symbolp (car reason)))
         (error-message-string reason))
        (t (format "%s" reason))))

(defconst reddigg--sub-path
  "/r/%s.json?count=25"
  "Sub reddit path template (origin supplied by the server).")

(defconst reddigg--sub-view-sort-path
  "/r/%s/%s.json?count=25"
  "Sub reddit path template for new and rising.")

(defconst reddigg--sub-view-sort-scope-path
  "/r/%s/%s.json?count=25&sort=%s&t=%s"
  "Sub reddit path template for top and controversial.")

(defconst reddigg--cmt-path
  "/%s.json"
  "Comment link path template.")

(defconst reddigg--cmt-more-path
  "/api/morechildren?api_type=json&link_id=%s&children=%s"
  "More comment link path template.")

(defconst reddigg--template-sub "[[elisp:(reddigg-view-sub \"%s\")][%s]]\n"
  "Template string for main.")

(defconst reddigg--template-sub* "[[elisp:(reddigg-view-sub \"%s\")][%s]]"
  "Template string for refresh sub post list.")

(defconst reddigg--template-sub-sort "[[elisp:(reddigg--view-sub \"%s\" %s)][%s]]"
  "Template string for sub sort.")

(defun reddigg--ensure-modes ()
  "Get a bunch of modes up and running."
  (if (equal major-mode 'org-mode)
      (org-set-startup-visibility)
    ;; `org-mode' kills buffer-local variables.  Preserve the image state
    ;; gathered while the contents were inserted so background downloads
    ;; can still find their anchors afterwards.
    (let ((generation reddigg--render-generation)
          (anchors reddigg--image-anchors)
          (jobs reddigg--image-jobs)
          (hidden reddigg--images-hidden))
      (org-mode)
      (setq-local reddigg--render-generation generation
                  reddigg--image-anchors anchors
                  reddigg--image-jobs jobs
                  reddigg--images-hidden hidden))
    (font-lock-flush))
  (visual-line-mode)
  (reddigg-view-mode 1))

(defvar reddigg-replacement-list
  '(("^\\* " . "- ")
    ("&gt;" . ">")
    ("&lt;" . "<")
    ("&amp;#x200B;" . "\n")
    ("&amp;nbsp;" . "\n")
    ("&amp;" . "&"))
  "List of (find . replace) to sanitize the text in range.")

(defvar-local reddigg--cmt-list-id nil
  "ID/name of the current comment list.")

;;; --- server process ------------------------------------------------------
;;
;; The Python relay server is normally started on demand as an Emacs
;; subprocess, so there is no separate "start the server" step.  Emacs
;; only ever stops a server it started itself; if something is already
;; listening on the configured port, it is used as-is.

(defconst reddigg--server-buffer-name "*reddigg-server*"
  "Buffer collecting the output of the relay server process.")

(defvar reddigg--server-process nil
  "The relay server process started by reddigg, if any.")

(defun reddigg--server-url-parts ()
  "Return (HOST . PORT) taken from `reddigg-server-url'."
  (let* ((url (url-generic-parse-url reddigg-server-url))
         (host (url-host url))
         (port (url-port url)))
    (cons (or host "127.0.0.1")
          (or (and port (> port 0) port)
              (if (equal (url-type url) "https") 443 80)))))

(defun reddigg--server-host ()
  "Return the host part of `reddigg-server-url'."
  (car (reddigg--server-url-parts)))

(defun reddigg--server-port ()
  "Return the port part of `reddigg-server-url'."
  (cdr (reddigg--server-url-parts)))

(defun reddigg--server-accepting-p ()
  "Return non-nil when something accepts connections on the server port."
  (condition-case nil
      (let ((proc (open-network-stream "reddigg-probe" nil
                                       (reddigg--server-host)
                                       (reddigg--server-port))))
        (delete-process proc)
        t)
    (error nil)))

(defun reddigg--server-default-command ()
  "Return the default command list for starting the relay server."
  (let* ((dir (expand-file-name reddigg-server-directory))
         (script (expand-file-name "reddigg_server.py" dir))
         (venv-python (expand-file-name
                       (if (eq system-type 'windows-nt)
                           "Scripts/python.exe"
                         "bin/python")
                       (expand-file-name ".venv" dir))))
    (cond
     ((file-executable-p venv-python) (list venv-python script))
     ((executable-find "uv")
      (list (executable-find "uv") "run" "reddigg_server.py"))
     ((executable-find "python3")
      (list (executable-find "python3") script))
     (t (error "reddigg: cannot find a Python interpreter to run %s" script)))))

(defun reddigg--server-command ()
  "Return the command list to start the relay server.
`reddigg-server-command' is used when non-nil; otherwise a suitable
interpreter is detected and --host/--port are appended.  In either
case, \"%h\" and \"%p\" in the elements are expanded."
  (let* ((host (reddigg--server-host))
         (port (number-to-string (reddigg--server-port)))
         (template (or reddigg-server-command
                       (append (reddigg--server-default-command)
                               (list "--host" "%h" "--port" "%p"))))
         (subst (lambda (arg)
                  (setq arg (replace-regexp-in-string "%p" port arg t t))
                  (replace-regexp-in-string "%h" host arg t t))))
    (mapcar subst template)))

(defun reddigg--server-sentinel (proc event)
  "Handle PROC exiting with EVENT."
  (when (memq (process-status proc) '(exit signal))
    (when (eq proc reddigg--server-process)
      (setq reddigg--server-process nil))
    (unless (process-get proc 'reddigg-stopping)
      (message "reddigg: server process exited (%s); see buffer %s"
               (string-trim event) reddigg--server-buffer-name))))

(defun reddigg--server-wait (proc)
  "Wait until PROC accepts connections, or signal an error."
  (let ((deadline (+ (float-time) reddigg-server-startup-timeout)))
    (while (and (process-live-p proc)
                (not (reddigg--server-accepting-p))
                (< (float-time) deadline))
      (accept-process-output proc 0.1))
    (cond
     ((reddigg--server-accepting-p) t)
     ((not (process-live-p proc))
      (error "reddigg: server failed to start; see buffer %s"
             reddigg--server-buffer-name))
     (t
      (error "reddigg: server did not start within %s seconds; see buffer %s"
             reddigg-server-startup-timeout reddigg--server-buffer-name)))))

(defun reddigg--server-start ()
  "Start the relay server in a subprocess and wait until it is ready."
  (let ((dir (expand-file-name reddigg-server-directory))
        (default-directory (expand-file-name reddigg-server-directory)))
    (unless (file-directory-p dir)
      (error "reddigg: server directory %s does not exist" dir))
    (let ((script (expand-file-name "reddigg_server.py" dir)))
      (unless (or reddigg-server-command (file-readable-p script))
        (error "reddigg: cannot find %s; set `reddigg-server-directory'" script)))
    (when (process-live-p reddigg--server-process)
      (process-put reddigg--server-process 'reddigg-stopping t)
      (delete-process reddigg--server-process))
    (let ((buffer (get-buffer-create reddigg--server-buffer-name))
          (command (reddigg--server-command)))
      (with-current-buffer buffer
        (erase-buffer))
      (setq reddigg--server-process
            (make-process
             :name "reddigg-server"
             :buffer buffer
             :stderr buffer
             :command command
             :connection-type 'pipe
             :coding 'utf-8-unix
             :noquery t
             :sentinel #'reddigg--server-sentinel))
      (message "reddigg: starting server (%s)" (mapconcat #'identity command " "))
      (reddigg--server-wait reddigg--server-process))))

(defun reddigg--server-ensure ()
  "Ensure the relay server is reachable, starting it when allowed.
Return non-nil when a server is listening.  When
`reddigg-server-autostart' is nil and no server is running, return nil
without signalling."
  (cond
   ((reddigg--server-accepting-p) t)
   ((not reddigg-server-autostart) nil)
   ((and reddigg--server-process (process-live-p reddigg--server-process))
    (reddigg--server-wait reddigg--server-process))
   (t (reddigg--server-start))))

(defun reddigg--server-kill-emacs ()
  "Stop a relay server started by reddigg when Emacs exits."
  (when (and reddigg-server-stop-on-exit
             reddigg--server-process
             (process-live-p reddigg--server-process))
    (process-put reddigg--server-process 'reddigg-stopping t)
    (delete-process reddigg--server-process)))

(add-hook 'kill-emacs-hook #'reddigg--server-kill-emacs)

;;;###autoload
(defun reddigg-server-start ()
  "Start the reddigg relay server and wait until it accepts requests.
Normally this happens automatically on the first request; see
`reddigg-server-autostart'.  Server output goes to the buffer named
by `reddigg--server-buffer-name'."
  (interactive)
  (if (reddigg--server-accepting-p)
      (message "reddigg: server already running on %s:%s"
               (reddigg--server-host) (reddigg--server-port))
    (reddigg--server-start)
    (message "reddigg: server started on %s:%s"
             (reddigg--server-host) (reddigg--server-port))))

;;;###autoload
(defun reddigg-server-stop ()
  "Stop the reddigg relay server if Emacs started it."
  (interactive)
  (if (and reddigg--server-process (process-live-p reddigg--server-process))
      (progn
        (process-put reddigg--server-process 'reddigg-stopping t)
        (delete-process reddigg--server-process)
        (setq reddigg--server-process nil)
        (message "reddigg: server stopped"))
    (message "reddigg: no server process started by reddigg")))

;;; --- HTTP transport to the local reddigg server --------------------------
;;
;; All reddit access goes through the local Python server (see
;; `reddigg-server-url'), which relays each request to the reddit tab
;; running the reddigg userscript -- the only thing with a real,
;; logged-in session.  The server exposes a small REST API:
;;
;;   GET  /reddigg/ping                   -> {"ok":true,"result":...}
;;   GET  /reddigg/session                -> {"ok":true,"result":{modhash,user}}
;;   GET  /reddigg/get?path=<reddit path> -> {"ok":true,"result":<json>}
;;   POST /reddigg/vote     {"id","dir"}
;;   POST /reddigg/comment  {"parent","text"}
;;   POST /reddigg/edit     {"id","text"}
;;   POST /reddigg/delete   {"id"}
;;   POST /reddigg/submit   {"subreddit","title","kind","text","url"}
;;
;; Every reply is either {"ok":true,"result":...} or {"error":"..."}
;; (with a 4xx/5xx status on failure).  Every request must carry the
;; token from `reddigg-token-file' in an X-Bridge-Token header.

(defun reddigg--token ()
  "Return the server auth token read from `reddigg-token-file'."
  (let ((file (expand-file-name reddigg-token-file)))
    (unless (file-readable-p file)
      (error "reddigg: cannot read token file %s (is the server running?  Try M-x reddigg-server-start)"
             file))
    (string-trim
     (with-temp-buffer
       (insert-file-contents file)
       (buffer-string)))))

(defun reddigg--url-encode (s)
  "Percent-encode string S for use as a URL query value."
  (url-hexify-string s))

(defun reddigg--http-request (method url &optional body)
  "Perform a synchronous HTTP request and promise the parsed result.
METHOD is \"GET\" or \"POST\".  URL is the full request URL.  BODY,
when non-nil, is a hash-table/alist to send as a JSON POST body.
The promise resolves to the server's `result' value, or rejects with
a string carrying the server's message on failure."
  (promise-new
   (lambda (resolve reject)
     (condition-case err
         (progn
           (reddigg--server-ensure)
           (let* ((url-request-method method)
                  (url-request-extra-headers
                   `(("X-Bridge-Token" . ,(reddigg--token))
                     ,@(when body '(("Content-Type" . "application/json")))))
                  (url-request-data
                   (when body (encode-coding-string (json-encode body) 'utf-8)))
                  (buf (url-retrieve-synchronously url t t
                                                   reddigg-request-timeout)))
             (if (not buf)
                 (funcall reject
                          "reddigg: no response from server (is it running, or did the request time out?)")
               (unwind-protect
                   (with-current-buffer buf
                     (goto-char (point-min))
                     (let* ((status (and (looking-at "HTTP/[0-9.]+ \\([0-9]+\\)")
                                         (string-to-number (match-string 1))))
                            ;; The body starts after the blank line that ends
                            ;; the headers; it is UTF-8 bytes in a unibyte buffer.
                            (data (and (re-search-forward "\r?\n\r?\n" nil t)
                                       (condition-case nil
                                           (reddigg--parse-json-string
                                            (decode-coding-string
                                             (buffer-substring-no-properties
                                              (point) (point-max))
                                             'utf-8))
                                         (error nil)))))
                       (if (and status (>= status 200) (< status 300)
                                (hash-table-p data))
                           (funcall resolve (gethash "result" data))
                         (funcall reject
                                  (or (and (hash-table-p data)
                                           (gethash "error" data))
                                      (format "reddigg: HTTP %s from server"
                                              (or status "?")))))))
                 (kill-buffer buf)))))
       (error (funcall reject
                       (format "reddigg: request to %s failed: %s"
                               url (error-message-string err))))))))

(defun reddigg--reddigg-get (path)
  "Promise the reddit JSON at reddit PATH (e.g. \"/r/emacs.json\")."
  (reddigg--http-request
   "GET"
   (format "%s/get?path=%s" reddigg-server-url (reddigg--url-encode path))))

(defun reddigg--reddigg-post (action params)
  "Promise the result of POSTing PARAMS to server ACTION.
PARAMS is an alist of (\"name\" . value) or a hash-table; it is sent
as a JSON object body."
  (reddigg--http-request
   "POST"
   (format "%s/%s" reddigg-server-url action)
   (if (hash-table-p params) params (ht<-alist params))))

;;; --- reading: posts and comments -------------------------------------------

(cl-defun reddigg--promise-posts (sub &key after before sort scope)
  "Promise SUB post list with keywords.
AFTER: fetch post after name.
BEFORE: fetch posts before name.
SORT: top, hot, best, rising, controversial.
SCOPE: hour, day, week, year, all."
  (reddigg--reddigg-get
   ;; create the reddit path (the server prepends the origin)
   (concat
    (cond
     ((or (eq sort 'new )
          (eq sort 'rising))
      (format reddigg--sub-view-sort-path sub sort))
     ((or (eq sort 'top )
          (eq sort 'controversial))
      (format reddigg--sub-view-sort-scope-path sub sort sort scope))
     (t (format reddigg--sub-path sub)))
    (when after
      (concat "&after=" after))
    (when before
      (concat "&before=" before)))))

(defun reddigg--normalize-cmt-path (cmt)
  "Reduce CMT to a bare path such as \"r/emacs/comments/abc/title\".
CMT may be a full reddit URL, a permalink with leading/trailing
slashes (as reddit returns them), or an already-bare path.  The
leading slash matters: the server resolves the path against the
reddit origin, so a stray \"//\" would be read as a host."
  (let* ((p (replace-regexp-in-string "\\`https?://[^/]+/" "" cmt))
         (p (replace-regexp-in-string "[?#].*\\'" "" p))
         (p (replace-regexp-in-string "\\`/+\\|/+\\'" "" p))
         (p (replace-regexp-in-string "\\.json\\'" "" p)))
    p))

(defun reddigg--promise-comments (cmt)
  "Promise CMT list."
  (reddigg--reddigg-get
   (format reddigg--cmt-path (reddigg--normalize-cmt-path cmt))))

(defun reddigg--promise-more-comments (children)
  "Promise more comment list for CHILDREN."
  (reddigg--reddigg-get
   (format reddigg--cmt-more-path reddigg--cmt-list-id children)))

;;; --- health check -----------------------------------------------------------

;;;###autoload
(defun reddigg-ping ()
  "Check that the reddigg server is up and a reddit tab is connected."
  (interactive)
  (promise-chain (reddigg--http-request
                  "GET" (format "%s/ping" reddigg-server-url))
    (then (lambda (_result)
            (message "reddigg: server and browser tab are reachable")))
    (promise-catch (lambda (reason)
                     (message "reddigg: ping failed: %s"
                              (reddigg--reason-string reason))))))

;;; --- session info -------------------------------------------------------
;;
;; The local server reports the logged-in user (and modhash) for the
;; reddit tab it is relaying to; Emacs keeps the username around so it
;; can tell which entries are the user's own (for edit/delete).

(defun reddigg--promise-session-info (&optional force)
  "Promise (MODHASH . USER). Uses cached values unless FORCE."
  (if (and (not force) reddigg--current-user)
      (promise-resolve (cons reddigg--modhash reddigg--current-user))
    (promise-chain (reddigg--http-request
                    "GET" (format "%s/session" reddigg-server-url))
      (then (lambda (data)
              (let ((modhash (and (hash-table-p data) (gethash "modhash" data)))
                    (user (and (hash-table-p data) (gethash "user" data))))
                (unless (and (stringp user) (> (length user) 0))
                  (error "reddigg: not logged in on the reddit tab \
(are you logged into old.reddit.com?)"))
                (setq reddigg--modhash modhash
                      reddigg--current-user user)
                (cons modhash user)))))))

(defun reddigg--prefetch-session ()
  "Warm the session cache in the background, ignoring failures."
  (promise-catch (reddigg--promise-session-info) #'ignore))

;;;###autoload
(defun reddigg-refresh-session ()
  "Force re-reading the username from the reddit tab.
Use this if actions start failing after you log out/in or switch
accounts in the browser."
  (interactive)
  (promise-chain (reddigg--promise-session-info t)
    (then (lambda (info)
            (message "reddigg: session refreshed (logged in as %s)" (cdr info))))
    (promise-catch (lambda (reason)
                     (message "reddigg: could not refresh session: %s"
                              (reddigg--reason-string reason))))))

;;; --- Generic authenticated POST ------------------------------------------

(defun reddigg--check-api-errors (data)
  "Signal a readable error if DATA (parsed reddit API JSON) carries
errors in the {\"json\":{\"errors\":[...]}} envelope; else return DATA."
  (when (hash-table-p data)
    (let* ((json (gethash "json" data))
           (errors (and (hash-table-p json) (gethash "errors" json))))
      (when (and errors (> (length errors) 0))
        (error "reddigg: reddit API error: %s"
               (mapconcat (lambda (e)
                            (format "%s" (if (and (sequencep e) (>= (length e) 2))
                                             (elt e 1)
                                           e)))
                          (append errors nil) "; ")))))
  data)

(defun reddigg--promise-post (action fields)
  "Promise the parsed JSON result of POSTing FIELDS (an alist) to server
ACTION (e.g. \"vote\").  The browser side attaches the CSRF modhash
itself; this signals an error if reddit's response reports one."
  (promise-chain (reddigg--reddigg-post action fields)
    (then #'reddigg--check-api-errors)))

;;; --- Thing identity (posts/comments) at point ----------------------------

(defun reddigg--thing-at-point ()
  "Return (:id ID :author AUTHOR :subreddit SUBREDDIT) for the reddigg
entry at point, or user-error."
  (save-excursion
    (condition-case nil
        (org-back-to-heading t)
      (error (user-error "reddigg: point is not on a reddigg entry")))
    (let ((id (org-entry-get (point) "REDDIGG_ID"))
          (author (org-entry-get (point) "REDDIGG_AUTHOR"))
          (subreddit (org-entry-get (point) "REDDIGG_SUBREDDIT")))
      (unless id
        (user-error "reddigg: no reddit item at point (missing REDDIGG_ID)"))
      (list :id id :author author :subreddit subreddit))))

(defun reddigg--mark-body-overlay (start end)
  "Wrap START..END (markers or positions) in an overlay tagging it as
this entry's editable body text, so `reddigg-edit-at-point' can find
and replace it later without needing to re-fetch from reddit."
  (let ((ov (make-overlay start end nil t nil)))
    (overlay-put ov 'reddigg-body t)
    ov))

(defun reddigg--find-body-overlay ()
  "Find the body overlay for the reddigg entry at point, or nil."
  (save-excursion
    (org-back-to-heading t)
    (let ((subtree-end (save-excursion (org-end-of-subtree t t) (point))))
      (car (seq-filter (lambda (ov) (overlay-get ov 'reddigg-body))
                       (overlays-in (point) subtree-end))))))

(defun reddigg--likes->string (value)
  "Convert a raw reddit \"likes\" JSON VALUE into \"up\"/\"down\"/\"none\".
VALUE is t (upvoted), `reddigg--json-false' (downvoted), or nil (no
vote / not present)."
  (cond
   ((eq value t) "up")
   ((eq value reddigg--json-false) "down")
   (t "none")))

(defun reddigg--likes-string->number (s)
  "Inverse of `reddigg--likes->string': \"up\"/\"down\"/\"none\" (or nil,
treated as \"none\") to 1/-1/0."
  (cond ((equal s "up") 1)
        ((equal s "down") -1)
        (t 0)))

(defun reddigg--bump-score (delta)
  "Add DELTA to the :REDDIGG_SCORE: property of the heading at point."
  (let* ((current (org-entry-get (point) "REDDIGG_SCORE"))
         (current-n (if current (string-to-number current) 0)))
    (org-entry-put (point) "REDDIGG_SCORE" (number-to-string (+ current-n delta)))))

(defun reddigg--format-created (epoch)
  "Format EPOCH (reddit's \"created_utc\", seconds since epoch) as a
readable timestamp, or \"unknown\" if EPOCH isn't a number."
  (if (numberp epoch)
      (format-time-string "%Y-%m-%d %H:%M:%S" epoch)
    "unknown"))

;;; --- Images ---------------------------------------------------------------
;;
;; Reddit image posts carry a direct `url' and/or a `preview' object with
;; several resolutions.  Galleries carry `gallery_data' plus
;; `media_metadata'.  We pick a preview no wider than
;; `reddigg-image-max-width' (the original can be many megabytes),
;; download it in the background, cache it on disk, and insert an org
;; file link so `org-display-inline-images' can show it.  Images that
;; are already cached make no network request.

(defcustom reddigg-image-display 'inline
  "How reddigg handles images attached to posts.
`inline' downloads the images in the background and displays them in
the buffer.  `link' only inserts a \"show image\" link; the image is
fetched when you activate it or run `reddigg-show-images'.  nil
inserts neither, but the direct image URL is still shown for link
posts."
  :type '(choice (const :tag "Display inline" inline)
                 (const :tag "On demand" link)
                 (const :tag "Disabled" nil))
  :group 'reddigg)

(defcustom reddigg-image-cache-dir
  (expand-file-name "reddigg/images"
                    (let ((xdg (getenv "XDG_CACHE_HOME")))
                      (if (and xdg (not (string-empty-p xdg)))
                          xdg
                        (expand-file-name "~/.cache"))))
  "Directory where downloaded reddit images are cached.
The name of each file is a hash of its URL, so an image is only
downloaded once.  Use `reddigg-clear-image-cache' to empty it."
  :type 'directory
  :group 'reddigg)

(defcustom reddigg-image-max-width 400
  "Maximum width, in pixels, of inline images.
Wider images are scaled down; smaller images keep their natural size.
This is also used to pick a reasonably sized reddit preview instead of
fetching the original.  Set to nil to use the original image at its
natural size."
  :type '(choice (integer :tag "Pixels") (const :tag "Natural size" nil))
  :group 'reddigg)

(defcustom reddigg-image-max-size (* 20 1024 1024)
  "Maximum size in bytes of an image reddigg will download."
  :type 'integer
  :group 'reddigg)

(defcustom reddigg-image-timeout 30
  "Seconds to wait for an image download before giving up."
  :type 'number
  :group 'reddigg)

(defcustom reddigg-video-player "mpv"
  "Program `reddigg-play-video' uses to play a post's video.
The video URL is passed as the last argument.  Set it to nil to open
the video in a browser with `browse-url' instead."
  :type '(choice (const :tag "Browser" nil) (string :tag "Program"))
  :group 'reddigg)

(defcustom reddigg-video-player-args nil
  "Extra arguments passed to `reddigg-video-player'.
They come before the video URL, so a slower, less eager stream looks
like this:

  (setq reddigg-video-player-args
        (list \"--no-terminal\" \"--demuxer-readahead-secs=5\"))

Ignored when `reddigg-video-player' is nil."
  :type '(repeat string)
  :group 'reddigg)

(defcustom reddigg-video-poster-badge t
  "Non-nil means draw a play badge onto an inline video poster.
The badge is baked into a small SVG file next to the cached poster, so
it costs nothing to redisplay.  Video posters are still shown without
it when this is nil or when Emacs cannot reference one image from
another."
  :type 'boolean
  :group 'reddigg)

(defconst reddigg--image-url-regexp
  "\\.\\(?:png\\|jpe?g\\|gif\\|webp\\|bmp\\)\\(?:[?#].*\\)?\\'"
  "Regexp matching URLs that point at a bitmap image.")

(defconst reddigg--image-file-extensions
  '("png" "jpg" "jpeg" "gif" "webp" "bmp")
  "Extensions reddigg uses for cached images.")

(defvar reddigg--image-queue (make-hash-table :test 'equal)
  "In-flight image downloads, keyed by URL.
Each value is a list of callbacks waiting for the cached file name.")

(defun reddigg--seq->list (seq)
  "Return the elements of SEQ as a list, or nil if SEQ is not a sequence."
  (cond ((vectorp seq) (append seq nil))
        ((and (listp seq) seq) seq)
        (t nil)))

(defun reddigg--html-unescape (string)
  "Undo the HTML escaping reddit applies to preview URLs."
  (when (stringp string)
    (let ((s string))
      (setq s (replace-regexp-in-string "&amp;" "&" s t t))
      (setq s (replace-regexp-in-string "&#x2F;" "/" s t t))
      s)))

(defun reddigg--image-host-blocked-p (url)
  "Non-nil when URL points at localhost or a private network address.
Post data comes from reddit and is untrusted, so an image URL should
never make Emacs fetch something on the user's own machine or LAN."
  (condition-case nil
      (let ((host (downcase (or (url-host (url-generic-parse-url url)) ""))))
        (or (string= host "localhost")
            (string-match-p "\\.localhost\\'" host)
            (string-match-p "\\`127\\." host)
            (string-match-p "\\`10\\." host)
            (string-match-p "\\`192\\.168\\." host)
            (string-match-p "\\`169\\.254\\." host)
            (string-match-p "\\`172\\.\\(?:1[6-9]\\|2[0-9]\\|3[01]\\)\\." host)
            (string= host "[::1]")
            (string= host "::1")
            (string= host "0.0.0.0")))
    (error t)))

(defun reddigg--http-url-p (url)
  "Return non-nil when URL is an http(s) URL reddigg may contact."
  (and (stringp url)
       (let ((case-fold-search t))
         (and (string-match-p "\\`https?://" url)
              (not (reddigg--image-host-blocked-p url))))))

(defun reddigg--image-url-p (url)
  "Return non-nil when URL is an http(s) link to a bitmap image."
  (and (string-match-p reddigg--image-url-regexp (or url ""))
       (reddigg--http-url-p url)))

(defun reddigg--preview-entry-width (entry)
  "Return the pixel width recorded in preview ENTRY, or 0."
  (let ((width (or (gethash "width" entry) (gethash "x" entry))))
    (if (numberp width) width 0)))

(defun reddigg--pick-preview (entries max-width)
  "Pick a preview ENTRY at least MAX-WIDTH wide, else the largest one."
  (when entries
    (or (and max-width
             (seq-find (lambda (entry)
                         (and (hash-table-p entry)
                              (>= (reddigg--preview-entry-width entry)
                                  max-width)))
                       entries))
        (car (last entries)))))

(defun reddigg--post-preview-url (post)
  "Return a preview URL from POST's \"preview\" data, or nil."
  (let* ((preview (gethash "preview" post))
         (images (and (hash-table-p preview)
                      (reddigg--seq->list (gethash "images" preview))))
         (image (car images))
         (entries (and (hash-table-p image)
                       (reddigg--seq->list (gethash "resolutions" image))))
         (source (and (hash-table-p image) (gethash "source" image)))
         (max-width (and (numberp reddigg-image-max-width)
                         reddigg-image-max-width))
         (chosen (and max-width
                      (reddigg--pick-preview entries max-width))))
    (when (hash-table-p image)
      (reddigg--html-unescape
       (or (and (hash-table-p chosen) (gethash "url" chosen))
           (and (hash-table-p source) (gethash "url" source))
           (let ((last (car (last entries))))
             (and (hash-table-p last) (gethash "url" last))))))))

(defun reddigg--gallery-preview-url (media)
  "Return a display URL for gallery media MEDIA, or nil."
  (let* ((entries (reddigg--seq->list (gethash "p" media)))
         (source (gethash "s" media))
         (max-width (and (numberp reddigg-image-max-width)
                         reddigg-image-max-width))
         (chosen (and max-width
                      (reddigg--pick-preview entries max-width))))
    (reddigg--html-unescape
     (or (and (hash-table-p chosen) (gethash "u" chosen))
         (and (hash-table-p source) (gethash "u" source))
         (let ((last (car (last entries))))
           (and (hash-table-p last) (gethash "u" last)))))))

(defun reddigg--gallery-image-urls (post)
  "Return the image URLs of POST's gallery, in gallery order."
  (let* ((gallery (gethash "gallery_data" post))
         (items (and (hash-table-p gallery)
                     (reddigg--seq->list (gethash "items" gallery))))
         (metadata (gethash "media_metadata" post))
         urls)
    (when (hash-table-p metadata)
      (dolist (item items)
        (when (hash-table-p item)
          (let* ((media-id (gethash "media_id" item))
                 (media (and (stringp media-id)
                             (gethash media-id metadata)))
                 (url (and (hash-table-p media)
                           (reddigg--gallery-preview-url media))))
            (when url (push url urls))))))
    (nreverse urls)))

(defun reddigg--post-thumbnail-url (post)
  "Return POST's thumbnail URL when it is a real image, or nil.
Reddit uses the same `thumbnail' field for both URLs and words such
as `self', `default', `nsfw' or `spoiler'."
  (let ((thumbnail (reddigg--html-unescape (gethash "thumbnail" post))))
    (and (reddigg--http-url-p thumbnail)
         thumbnail)))

(defun reddigg--reddit-video (post)
  "Return the video object describing POST's video, or nil.
Reddit repeats the video under `media' and `secure_media'.  A
crossposted video that has neither only carries
`preview'/`reddit_video_preview'."
  (let ((preview (gethash "preview" post))
        (candidates nil))
    (dolist (key '("media" "secure_media"))
      (let* ((media (gethash key post))
             (video (and (hash-table-p media)
                         (gethash "reddit_video" media))))
        (when (hash-table-p video)
          (push video candidates))))
    (when (hash-table-p preview)
      (let ((video (gethash "reddit_video_preview" preview)))
        (when (hash-table-p video)
          (setq candidates (append candidates (list video))))))
    (car candidates)))

(defconst reddigg--external-video-hints '("rich:video" "rich-video" "video")
  "Reddit `post_hint' values for videos hosted somewhere else.
YouTube and Vimeo posts, for example, have a preview image but no
reddit-hosted video stream.")

(defun reddigg--post-video (post)
  "Return a plist describing the video attached to POST, or nil.
The plist carries :url (what to play), :hls and :fallback (reddit's
streams), :external (non-nil for videos hosted elsewhere), :duration
in seconds and :poster, a frame to show before playing.  :url prefers
HLS, which is the only stream reddit serves with sound."
  (when (hash-table-p post)
    (let* ((hint (gethash "post_hint" post))
           (video (reddigg--reddit-video post))
           (url (reddigg--html-unescape (gethash "url" post)))
           (external (and (not video)
                          (reddigg--http-url-p url)
                          (or (eq (gethash "is_video" post) t)
                              (member hint reddigg--external-video-hints))
                          url))
           (hls (and video (reddigg--html-unescape
                            (gethash "hls_url" video))))
           (fallback (and video (reddigg--html-unescape
                                 (gethash "fallback_url" video))))
           (duration (and video (gethash "duration" video))))
      (when (or hls fallback external)
        (list :url (or hls fallback external)
              :hls hls
              :fallback fallback
              :external (and external t)
              :duration (and (numberp duration) duration)
              :poster (or (reddigg--post-preview-url post)
                          (reddigg--post-thumbnail-url post)))))))

(defun reddigg--post-media (post &optional depth)
  "Return the media attached to reddit POST as a plist.
:images is the list of image URLs to display, :poster is the frame
shown for a video post and :video is its `reddigg--post-video' plist.
A post without media of its own falls back to the post it crossposts,
unless DEPTH is non-nil."
  (when (hash-table-p post)
    (let* ((hint (gethash "post_hint" post))
           (url (reddigg--html-unescape (gethash "url" post)))
           (video (reddigg--post-video post))
           (poster (plist-get video :poster))
           (preview-url (reddigg--post-preview-url post))
           (images
            (cond
             ((or (gethash "is_gallery" post) (equal hint "gallery"))
              (reddigg--gallery-image-urls post))
             (video (and poster (list poster)))
             ((and preview-url
                   (or (equal hint "image")
                       (reddigg--image-url-p url)))
              (list preview-url))
             ((reddigg--image-url-p url)
              (list url)))))
      (cond
       ((or images video)
        (list :images images :poster poster :video video))
       (depth nil)
       (t
        (let ((parents (reddigg--seq->list
                        (gethash "crosspost_parent_list" post))))
          (when parents
            (reddigg--post-media (car parents) t))))))))

(defun reddigg--post-image-urls (post &optional depth)
  "Return a list of image URLs attached to reddit POST.
Handles direct image links, image previews, galleries, video posters
and (one level of) crossposts.  DEPTH is non-nil when looking at a
crosspost parent."
  (plist-get (reddigg--post-media post depth) :images))

(defun reddigg--image-cache-file (url)
  "Return the cached file for URL, or nil if it is not downloaded."
  (let ((base (expand-file-name (secure-hash 'sha1 url)
                                reddigg-image-cache-dir)))
    (seq-some (lambda (ext)
                (let ((file (concat base "." ext)))
                  (and (file-regular-p file)
                       (> (or (file-attribute-size (file-attributes file)) 0) 0)
                       file)))
              reddigg--image-file-extensions)))

(defun reddigg--image-extension-from-data (data)
  "Return a file extension for image DATA, or nil if DATA is not an image."
  (cond
   ((string-prefix-p (unibyte-string #x89 ?P ?N ?G) data) "png")
   ((string-prefix-p (unibyte-string #xff #xd8 #xff) data) "jpg")
   ((string-prefix-p (unibyte-string ?G ?I ?F ?8) data) "gif")
   ((and (>= (length data) 12)
         (string-prefix-p (unibyte-string ?R ?I ?F ?F) data)
         (string= (substring data 8 12) "WEBP"))
    "webp")
   ((string-prefix-p (unibyte-string ?B ?M) data) "bmp")))

(defun reddigg--save-image-response (url)
  "Save the image in the current URL response buffer for URL.
Return the cache file name, or nil when the response is not a usable
image (error page, too large, unsupported format)."
  (when (<= (buffer-size) reddigg-image-max-size)
    (save-excursion
      (goto-char (point-min))
      (when (and (looking-at "HTTP/[0-9.]+ 200")
                 (re-search-forward "\r?\n\r?\n" nil t))
        (let* ((data (buffer-substring-no-properties (point) (point-max)))
               (ext (reddigg--image-extension-from-data data)))
          (when ext
            (make-directory reddigg-image-cache-dir t)
            (let ((file (expand-file-name
                         (concat (secure-hash 'sha1 url) "." ext)
                         reddigg-image-cache-dir)))
              (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert data)
                (let ((coding-system-for-write 'no-conversion))
                  (write-region (point-min) (point-max) file nil 'silent)))
              file)))))))

(defun reddigg--image-download (url callback)
  "Download image URL in the background and call CALLBACK with its file.
CALLBACK receives the cache file name, or nil if the download failed.
Cached images call CALLBACK immediately, and a URL that is already
being downloaded only adds CALLBACK to the waiters."
  (let ((cached (reddigg--image-cache-file url)))
    (cond
     (cached (funcall callback cached))
     ((gethash url reddigg--image-queue)
      (push callback (gethash url reddigg--image-queue)))
     (t
      (puthash url (list callback) reddigg--image-queue)
      (let* ((finished nil)
             (response-buffer nil)
             (timer nil)
             (complete
              (lambda (file)
                (unless finished
                  (setq finished t)
                  (when (timerp timer) (cancel-timer timer))
                  (let ((callbacks (gethash url reddigg--image-queue)))
                    (remhash url reddigg--image-queue)
                    (dolist (cb (nreverse callbacks))
                      (condition-case err
                          (funcall cb file)
                        (error
                         (message "reddigg: image callback failed: %s"
                                  (error-message-string err))))))))))
        (setq timer
              (run-at-time
               reddigg-image-timeout nil
               (lambda ()
                 (when (buffer-live-p response-buffer)
                   (kill-buffer response-buffer))
                 (funcall complete nil))))
        (condition-case err
            (setq response-buffer
                  (let ((url-request-extra-headers
                         '(("Accept" . "image/png,image/jpeg,image/gif,image/webp,image/*;q=0.8")))
                        (url-user-agent
                         "reddigg/0.9 (Emacs; +https://github.com/thanhvg/emacs-reddigg)"))
                    (url-retrieve
                     url
                     (lambda (status)
                       (funcall complete
                                (and (not (plist-get status :error))
                                     (buffer-live-p (current-buffer))
                                     (reddigg--save-image-response url))))
                     nil t t)))
          (error
           (funcall complete nil)
           (message "reddigg: could not fetch image %s: %s"
                    url (error-message-string err)))))))))

(defun reddigg--image-width (file)
  "Return the width to use for FILE, capped to `reddigg-image-max-width'.
Return nil when the natural width should be used."
  (when (and (integerp reddigg-image-max-width)
             (> reddigg-image-max-width 0))
    (condition-case nil
        (let* ((image (create-image file nil nil))
               (size (image-size image t)))
          (when (and (consp size)
                     (numberp (car size))
                     (> (car size) reddigg-image-max-width))
            reddigg-image-max-width))
      (error nil))))

(defun reddigg--display-inline-images (&optional beg end)
  "Display inline images between BEG and END in the current buffer."
  (when (display-graphic-p)
    ;; Bind the width variable so the `#+ATTR_ORG: :width' lines inserted
    ;; by `reddigg--insert-inline-image' are honored even when the user
    ;; keeps the global default of t (natural size).
    (let ((org-image-actual-width nil))
      (funcall (if (fboundp 'org-link-preview-region)
                   'org-link-preview-region
                 'org-display-inline-images)
               nil nil beg end))))

(defun reddigg--clear-inline-images ()
  "Remove inline image previews from the current buffer."
  (funcall (if (fboundp 'org-link-preview-clear)
               'org-link-preview-clear
             'org-remove-inline-images)))

(defun reddigg--reset-image-state ()
  "Forget per-render image state after erasing a reddigg buffer."
  ;; `erase-buffer' can leave zero-length preview overlays behind.
  (ignore-errors (reddigg--clear-inline-images))
  (setq reddigg--render-generation (1+ reddigg--render-generation)
        reddigg--image-anchors nil
        reddigg--image-jobs (make-hash-table :test 'equal)))

(defun reddigg--image-jobs-table ()
  "Return the image job table for the current buffer."
  (or reddigg--image-jobs
      (setq reddigg--image-jobs (make-hash-table :test 'equal))))

(defun reddigg--image-generation-current-p (buffer generation)
  "Non-nil when BUFFER is alive and still at GENERATION."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (eql generation reddigg--render-generation))))

(defun reddigg--image-supported-p (file)
  "Non-nil when this Emacs can display the image in FILE."
  (let ((type (pcase (downcase (or (file-name-extension file) ""))
                ("png" 'png)
                ("jpg" 'jpeg)
                ("jpeg" 'jpeg)
                ("gif" 'gif)
                ("webp" 'webp)
                ("bmp" 'bmp)
                ("svg" 'svg))))
    (and type (image-type-available-p type))))

;;; Video posters
;;
;; A video post has no image of its own, only a frame reddit computes
;; for it.  That frame is shown exactly like an image, with a play
;; badge drawn on top: a small SVG that embeds the cached poster and a
;; white triangle in a black circle, the way telega marks its videos.
;; Org displays the SVG as one image, so panning, scaling and the
;; inline image commands keep working on it.

(defconst reddigg--play-link-label "▶ play video"
  "Description of the link `reddigg--insert-video-link' inserts.")

(defun reddigg--play-badge-supported-p ()
  "Non-nil when reddigg can draw a play badge onto a poster.
That needs librsvg and the `:base-uri' image property, which is what
lets the badge find the poster sitting next to it (Emacs 28 and up)."
  (and reddigg-video-poster-badge
       (version<= "28" emacs-version)
       (image-type-available-p 'svg)))

(defun reddigg--xml-escape (string)
  "Escape STRING for use in an XML attribute value."
  (replace-regexp-in-string
   "[&<>\"]"
   (lambda (match)
     (cdr (assq (aref match 0)
                '((?& . "&amp;") (?< . "&lt;") (?> . "&gt;") (?\" . "&quot;")))))
   string t t))

(defun reddigg--play-badge-svg (poster width height)
  "Return SVG drawing POSTER at WIDTH x HEIGHT with a play badge.
POSTER is the file name of the poster, which lives in the same
directory as the SVG, so the reference to it stays relative."
  (let* ((radius (max 12.0 (/ (float (min width height)) 8.0)))
         (cx (/ width 2.0))
         (cy (/ height 2.0))
         (half (/ radius 2.0))
         (xoff (/ radius 8.0))
         (left (+ xoff (- cx half)))
         (right (+ xoff (+ cx half))))
    (cl-labels ((num (value) (format "%.2f" value))
                (point (x y) (format "%s,%s" (num x) (num y))))
      (format (concat "<svg xmlns=\"http://www.w3.org/2000/svg\""
                      " xmlns:xlink=\"http://www.w3.org/1999/xlink\""
                      " width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\">\n"
                      "  <image x=\"0\" y=\"0\" width=\"%d\" height=\"%d\""
                      " preserveAspectRatio=\"xMidYMid slice\""
                      " xlink:href=\"%s\"/>\n"
                      "  <circle cx=\"%s\" cy=\"%s\" r=\"%s\""
                      " fill=\"black\" fill-opacity=\"0.55\"/>\n"
                      "  <polygon points=\"%s %s %s\""
                      " fill=\"white\" fill-opacity=\"0.9\"/>\n"
                      "</svg>\n")
              width height width height
              width height
              (reddigg--xml-escape poster)
              (num cx) (num cy) (num radius)
              (point left (- cy half))
              (point left (+ cy half))
              (point right cy)))))

(defun reddigg--poster-badge-file (poster)
  "Return POSTER, or an SVG copy of it with a play badge on top.
The SVG is written once, next to the cached poster, and is shown by
org like any other image.  POSTER itself is returned when the badge
cannot be drawn, so callers always get a displayable file."
  (if (not (reddigg--play-badge-supported-p))
      poster
    (let ((svg (concat (file-name-sans-extension poster) "-play.svg")))
      (unless (file-regular-p svg)
        (condition-case err
            (let* ((size (image-size (create-image poster nil nil) t))
                   (width (round (car size)))
                   (height (round (cdr size))))
              (when (and (> width 0) (> height 0))
                (with-temp-file svg
                  (insert (reddigg--play-badge-svg
                           (file-name-nondirectory poster) width height)))))
          (error
           (message "reddigg: could not add a play badge to %s: %s"
                    poster (error-message-string err)))))
      (if (file-regular-p svg) svg poster))))

(defvar reddigg-video-poster-map
  (make-composed-keymap
   (list (let ((map (make-sparse-keymap)))
           (define-key map (kbd "RET") #'reddigg-play-video)
           (define-key map (kbd "<return>") #'reddigg-play-video)
           ;; A short mouse-1 click is translated to mouse-2 through
           ;; `follow-link' when `mouse-1-click-follows-link' is on.
           (define-key map [follow-link] t)
           (define-key map [mouse-1] #'reddigg-play-video)
           (define-key map [mouse-2] #'reddigg-play-video)
           (define-key map [double-mouse-2] #'reddigg-play-video)
           ;; Keep org's way of opening the poster file itself.
           (define-key map [mouse-3] #'org-find-file-at-mouse)
           map)
         image-map))
  "Keymap active on an inline video poster.
RET and a mouse click play the video, mouse-3 opens the poster file,
and everything else falls through to `image-map', so the usual image
commands keep working.")

(defun reddigg--add-video-poster-overlay (beg end)
  "Let the poster link spanning BEG..END play the video when activated.
The overlay outranks org's link preview overlay -- the one that puts
`image-map' on the inline image -- so `reddigg-video-poster-map' is
the keymap Emacs consults above the poster."
  (let ((overlay (make-overlay beg end)))
    (overlay-put overlay 'evaporate t)
    (overlay-put overlay 'priority 1)
    (overlay-put overlay 'keymap reddigg-video-poster-map)
    (overlay-put overlay 'help-echo "mouse-1, RET: play video")
    (overlay-put overlay 'reddigg-video-poster t)
    overlay))

(defun reddigg--insert-inline-image (marker file &optional video-p)
  "Insert a previewable org link to image FILE at MARKER.
When VIDEO-P, FILE is a video poster: a play badge is drawn on it
first when this Emacs can do that, and the link plays the video on
RET or mouse-1."
  (let ((buffer (marker-buffer marker)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (file (if video-p (reddigg--poster-badge-file file) file)))
          (save-excursion
            (goto-char marker)
            (let ((start (point))
                  (supported (reddigg--image-supported-p file)))
              (when supported
                (let ((width (reddigg--image-width file)))
                  (when width
                    (insert (format "#+ATTR_ORG: :width %d\n" width)))))
              (if supported
                  (let ((link (point)))
                    (insert (format "[[file:%s]]" (expand-file-name file)))
                    (when video-p
                      (reddigg--add-video-poster-overlay link (point)))
                    (insert "\n\n"))
                ;; Keep an inert, described link for formats this Emacs
                ;; cannot render instead of letting org try and fail.
                (insert (format "[[file:%s][image (%s)]]\n\n"
                                (expand-file-name file)
                                (or (file-name-extension file) "?"))))
              (when (and supported (not reddigg--images-hidden))
                (condition-case err
                    (reddigg--display-inline-images start (point))
                  (error
                   (message "reddigg: could not display image: %s"
                            (error-message-string err))))))))))))

(defun reddigg--fill-images (buffer anchor urls generation done &optional poster)
  "Download URLS one at a time, inserting each at ANCHOR in BUFFER.
POSTER, when non-nil, is the URL among URLS that is a video poster and
is therefore marked with a play badge.
GENERATION is BUFFER's render generation when the download started.
Call DONE after the last URL (or when the buffer has been re-rendered)."
  (if (null urls)
      (funcall done)
    (let ((url (car urls)))
      (reddigg--image-download
       url
       (lambda (file)
         (if (not (reddigg--image-generation-current-p buffer generation))
             nil
           (when (and file (markerp anchor) (marker-buffer anchor))
             (reddigg--insert-inline-image anchor file (equal url poster)))
           (reddigg--fill-images
            buffer anchor (cdr urls) generation done poster)))))))

(defun reddigg--schedule-entry-images (id urls anchor &optional poster)
  "Download URLS for entry ID and insert them at ANCHOR.
POSTER is the URL among URLS that is a video poster.
The actual work starts from a timer so the buffer finishes rendering
before `org-mode' is set up; cached files are then inserted at once."
  (let* ((generation reddigg--render-generation)
         (jobs (reddigg--image-jobs-table))
         (key (list id generation))
         (buffer (current-buffer)))
    (unless (gethash key jobs)
      (puthash key 'loading jobs)
      (run-at-time
       0 nil
       (lambda ()
         (if (not (reddigg--image-generation-current-p buffer generation))
             nil
           (reddigg--fill-images
            buffer anchor urls generation
            (lambda () (puthash key 'done jobs))
            poster)))))))

(defun reddigg--insert-image-link (urls)
  "Insert the on-demand image link for an entry with image URLS.
Return the buffer position where the images should be inserted, or
nil when the entry has no images.  The caller registers the position
only after inserting any text that must stay below the images."
  (when urls
    (when (eq reddigg-image-display 'link)
      (insert "[[elisp:(reddigg-show-images)][show image]]\n"))
    (point)))

(defun reddigg--insert-video-link (video)
  "Insert the play link for VIDEO (see `reddigg--post-video')."
  (let ((duration (reddigg--format-duration (plist-get video :duration))))
    (insert (format "[[elisp:(reddigg-play-video)][%s%s]]\n"
                    reddigg--play-link-label
                    (if duration (format " (%s)" duration) "")))))

(defun reddigg--insert-media-link (media)
  "Insert the on-demand image link and the play link for MEDIA.
Return the position where the images should be inserted, or nil when
MEDIA has no image."
  (let ((position (reddigg--insert-image-link (plist-get media :images))))
    (when (plist-get media :video)
      (reddigg--insert-video-link (plist-get media :video)))
    position))

(defun reddigg--insert-media-properties (media)
  "Insert the org properties that describe MEDIA.
They let `reddigg-show-images' and `reddigg-play-video' find an
entry's media again after the buffer has been re-rendered."
  (let ((images (plist-get media :images))
        (poster (plist-get media :poster))
        (video (plist-get media :video)))
    (when images
      (insert (format ":REDDIGG_IMAGES: %s\n" (mapconcat #'identity images " "))))
    (when poster
      (insert (format ":REDDIGG_POSTER: %s\n" poster)))
    (when video
      (insert (format ":REDDIGG_VIDEO: %s\n" (plist-get video :url)))
      (let ((fallback (and (not (plist-get video :external))
                           (plist-get video :fallback))))
        (when (and fallback (not (equal fallback (plist-get video :url))))
          (insert (format ":REDDIGG_VIDEO_FALLBACK: %s\n" fallback)))))))

(defun reddigg--register-image-area (id urls position &optional poster)
  "Remember POSITION as entry ID's image spot and schedule URLS.
POSTER is the URL among URLS that is a video poster.
The marker advances as images are inserted, keeping gallery images in
order, but stays above text that was inserted before this call."
  (let ((anchor (copy-marker position t)))
    (push (cons id anchor) reddigg--image-anchors)
    (when (eq reddigg-image-display 'inline)
      (reddigg--schedule-entry-images id urls anchor poster))
    anchor))

(defun reddigg--entry-property (name)
  "Return the value of org property NAME for the entry at point, or nil."
  (save-excursion
    (condition-case nil
        (org-back-to-heading t)
      (error nil))
    (let ((value (org-entry-get (point) name)))
      (and (stringp value) (not (string-empty-p value)) value))))

(defun reddigg--entry-image-urls ()
  "Return the image URLs recorded for the reddit entry at point."
  (let ((value (reddigg--entry-property "REDDIGG_IMAGES")))
    (and value (split-string value " " t))))

(defun reddigg--entry-body-end ()
  "Return the position where the current entry's own text ends.
That is the next heading, including a child heading."
  (save-excursion
    (org-back-to-heading t)
    (forward-line 1)
    (while (and (not (eobp))
                (not (looking-at-p org-outline-regexp-bol)))
      (forward-line 1))
    (point)))

;;;###autoload
(defun reddigg-show-images ()
  "Download and display the images attached to the entry at point.
For a video entry this displays its poster."
  (interactive)
  (let* ((thing (reddigg--thing-at-point))
         (id (plist-get thing :id))
         (urls (reddigg--entry-image-urls))
         (poster (reddigg--entry-property "REDDIGG_POSTER"))
         (generation reddigg--render-generation)
         (jobs (reddigg--image-jobs-table))
         (key (list id generation))
         (state (gethash key jobs))
         (anchor (let ((marker (cdr (assoc id reddigg--image-anchors))))
                   (if (and (markerp marker)
                            (marker-buffer marker)
                            (marker-position marker))
                       marker
                     (copy-marker (reddigg--entry-body-end) t)))))
    (unless urls
      (user-error "reddigg: this entry has no image"))
    (pcase state
      ('loading
       (message "reddigg: images are still loading..."))
      ('done
       (setq reddigg--images-hidden nil)
       (save-excursion
         (org-back-to-heading t)
         (reddigg--display-inline-images (point) (reddigg--entry-body-end)))
       (message "reddigg: images shown"))
      (_
       (setq reddigg--images-hidden nil)
       (puthash key 'loading jobs)
       (message "reddigg: loading %d image%s..." (length urls)
                (if (> (length urls) 1) "s" ""))
       (reddigg--fill-images
        (current-buffer) anchor urls generation
        (lambda () (puthash key 'done jobs))
        poster)))))

;;;###autoload
(defun reddigg-toggle-images ()
  "Toggle inline images in the current reddigg buffer."
  (interactive)
  (setq reddigg--images-hidden (not reddigg--images-hidden))
  (if reddigg--images-hidden
      (progn
        (reddigg--clear-inline-images)
        (message "reddigg: inline images hidden"))
    (reddigg--display-inline-images)
    (message "reddigg: inline images shown")))

;;;###autoload
(defun reddigg-clear-image-cache ()
  "Delete all images cached in `reddigg-image-cache-dir'."
  (interactive)
  (let ((dir (expand-file-name reddigg-image-cache-dir)))
    (unless (file-directory-p dir)
      (user-error "reddigg: no image cache at %s" dir))
    (when (y-or-n-p (format "reddigg: delete all files in %s? " dir))
      (dolist (file (directory-files dir t "\\`[^.]"))
        (when (file-regular-p file) (delete-file file)))
      (message "reddigg: image cache cleared"))))

;;; --- Videos ---------------------------------------------------------------
;;
;; Reddit serves video as an HLS playlist plus a silent DASH fallback,
;; so HLS is the stream to hand to a video player.  Browsers are given
;; the fallback URL instead, because they cannot play an m3u8 through
;; `browse-url' but do play the mp4.
;;
;; The player runs detached and streams: nothing is downloaded by
;; reddigg.  Only its error output is kept, so a player that dies (an
;; expired URL, a missing codec) can say why instead of just closing
;; its window.

(defconst reddigg--video-buffer-name "*reddigg-video*"
  "Buffer collecting the error output of `reddigg-video-player'.")

(defun reddigg--format-duration (seconds)
  "Format SECONDS as M:SS or H:MM:SS, or nil when it is unknown."
  (when (and (numberp seconds) (>= seconds 0))
    (let* ((total (round seconds))
           (hours (/ total 3600))
           (minutes (/ (% total 3600) 60))
           (rest (% total 60)))
      (if (> hours 0)
          (format "%d:%02d:%02d" hours minutes rest)
        (format "%d:%02d" minutes rest)))))

(defun reddigg--video-command (program url)
  "Return the command list that plays URL with PROGRAM.
`reddigg-video-player-args' go in between."
  (append (list program) reddigg-video-player-args (list url)))

(defun reddigg--video-output ()
  "Return the tail of the video player's error output, or nil."
  (let ((buffer (get-buffer reddigg--video-buffer-name)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((output (string-trim
                       (buffer-substring-no-properties
                        (max (point-min) (- (point-max) 500))
                        (point-max)))))
          (unless (string-empty-p output)
            (string-trim (replace-regexp-in-string
                          "[[:space:]\n]+" " " output))))))))

(defun reddigg--video-sentinel (process _event)
  "Report why the video player PROCESS stopped, unless it finished well."
  (when (memq (process-status process) '(exit signal))
    (let ((status (process-exit-status process)))
      (unless (and (integerp status) (zerop status))
        (let ((output (reddigg--video-output)))
          (message "reddigg: %s stopped (%s)%s"
                   reddigg-video-player status
                   (if output (concat ": " output) "")))))))

;;;###autoload
(defun reddigg-play-video (&optional url)
  "Play the video attached to the reddigg entry at point.
The video is played with `reddigg-video-player' (plus
`reddigg-video-player-args') when that program is installed, and
opened with `browse-url' otherwise.  The player streams the URL; it
is never downloaded first.  With URL, play that video instead of the
one recorded for the entry."
  (interactive)
  (let* ((primary (or url (reddigg--entry-property "REDDIGG_VIDEO")))
         (fallback (or (and (not url)
                            (reddigg--entry-property
                             "REDDIGG_VIDEO_FALLBACK"))
                       primary))
         (program (and reddigg-video-player
                       (executable-find reddigg-video-player)))
         (target (if program primary fallback)))
    (unless target
      (user-error "reddigg: this entry has no playable video"))
    (if (not program)
        (browse-url target)
      (let ((errors (get-buffer-create reddigg--video-buffer-name)))
        (with-current-buffer errors (erase-buffer))
        (condition-case err
            (progn
              (make-process
               :name "reddigg-video"
               :buffer nil
               :stderr errors
               :noquery t
               :command (reddigg--video-command program target)
               :sentinel #'reddigg--video-sentinel)
              (message "reddigg: playing video with %s" reddigg-video-player))
          (error
           (message "reddigg: could not start %s: %s"
                    reddigg-video-player (error-message-string err))))))))

;;; --- Voting ---------------------------------------------------------------

(defconst reddigg--vote-action "vote"
  "Server action for voting.  Params: id, dir.")

(defun reddigg--vote (dir)
  "Vote DIR (1, -1, or 0) on the reddigg entry at point."
  (let* ((thing (reddigg--thing-at-point))
         (id (plist-get thing :id))
         (marker (point-marker)))
    (promise-chain (reddigg--promise-post reddigg--vote-action
                                          (list (cons "id" id) (cons "dir" dir)))
      (then (lambda (_data)
              (with-current-buffer (marker-buffer marker)
                (save-excursion
                  (goto-char marker)
                  (org-back-to-heading t)
                  (let* ((old-numeric (reddigg--likes-string->number
                                       (org-entry-get (point) "REDDIGG_LIKES")))
                         (delta (- dir old-numeric)))
                    (reddigg--bump-score delta)
                    (org-entry-put (point) "REDDIGG_LIKES"
                                   (pcase dir (1 "up") (-1 "down") (_ "none")))
                    (message "reddigg: %s (score %s%s)"
                            (pcase dir (1 "upvoted") (-1 "downvoted") (_ "vote cleared"))
                            (if (>= delta 0) "+" "")
                            delta))))))
      (promise-catch (lambda (reason)
                       (message "reddigg: vote failed: %s"
                                (reddigg--reason-string reason)))))))

;;;###autoload
(defun reddigg-vote-up ()
  "Upvote the post or comment at point."
  (interactive)
  (reddigg--vote 1))

;;;###autoload
(defun reddigg-vote-down ()
  "Downvote the post or comment at point."
  (interactive)
  (reddigg--vote -1))

;;;###autoload
(defun reddigg-vote-clear ()
  "Clear your vote on the post or comment at point."
  (interactive)
  (reddigg--vote 0))

;;; --- Compose buffers (reply/edit/submit) -----------------------------------

(defvar-local reddigg-compose--kind nil
  "Symbol: `comment', `edit', or `submit'. Decides what C-c C-c does.")
(defvar-local reddigg-compose--parent-id nil
  "Fullname of the thing being replied to or edited.")
(defvar-local reddigg-compose--target-marker nil
  "Marker in the source buffer where the result should be inserted/updated.")
(defvar-local reddigg-compose--extra-fields nil
  "Alist of extra POST fields the specific kind needs.")

(defvar-local reddigg-compose--submit-sr nil
  "Subreddit name for a `submit' compose buffer.")

(defvar-local reddigg-compose--submit-kind nil
  "Reddit submission kind (`self' or `link') for a `submit' compose buffer.")

(defvar-local reddigg-compose--submit-title nil
  "Submission title for a `submit' compose buffer.")

(defvar reddigg-compose-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-c") #'reddigg-compose-send)
    (define-key m (kbd "C-c C-k") #'reddigg-compose-abort)
    m)
  "Keymap for reddigg compose buffers.")

(define-minor-mode reddigg-compose-mode
  "Minor mode for composing reddit comments/posts/edits."
  :lighter " reddigg-compose"
  :keymap reddigg-compose-mode-map)

(defun reddigg--compose-body ()
  "Return the compose buffer's text, stripping leading `# reddigg:' lines."
  (save-excursion
    (goto-char (point-min))
    (while (looking-at "^# reddigg:.*\n") (forward-line 1))
    (string-trim (buffer-substring-no-properties (point) (point-max)))))

(defun reddigg-compose-abort ()
  "Abandon the current reddigg compose buffer."
  (interactive)
  (when (y-or-n-p "reddigg: discard this? ")
    (kill-buffer)))

(defun reddigg-compose-send ()
  "Submit the current reddigg compose buffer, dispatching on its kind."
  (interactive)
  (let ((kind reddigg-compose--kind)
        (body (reddigg--compose-body))
        (buf (current-buffer)))
    (when (string-empty-p body)
      (user-error "reddigg: empty body, nothing to send"))
    (pcase kind
      ('comment (reddigg--send-comment buf body))
      ('edit (reddigg--send-edit buf body))
      ('submit (reddigg--send-submit buf body))
      (_ (error "reddigg: compose kind %S not implemented yet" kind)))))

(defun reddigg--insert-new-comment (parent-marker comment-data)
  "Insert COMMENT-DATA (a hash-table, see `reddigg--comment-data-with-fallback')
as a new child heading under PARENT-MARKER's entry."
  (with-current-buffer (marker-buffer parent-marker)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char parent-marker)
        (org-back-to-heading t)
        (let* ((level (org-current-level))
               (author (gethash "author" comment-data))
               (body (gethash "body" comment-data))
               (name (gethash "name" comment-data))
               begin)
          (org-end-of-subtree t t)
          (unless (bolp) (insert "\n"))
          (insert (make-string (1+ level) ?*) " " author "\n")
          (insert ":PROPERTIES:\n")
          (insert (format ":REDDIGG_ID: %s\n" name))
          (insert (format ":REDDIGG_AUTHOR: %s\n" author))
          (insert (format ":REDDIGG_SUBREDDIT: %s\n" (or (gethash "subreddit" comment-data) "")))
          (insert (format ":REDDIGG_LIKES: %s\n" (reddigg--likes->string (gethash "likes" comment-data))))
          (insert (format ":REDDIGG_SCORE: %s\n" (gethash "score" comment-data)))
          (insert (format ":REDDIGG_CREATED: %s\n" (reddigg--format-created (gethash "created_utc" comment-data))))
          (insert ":END:\n")
          (setq begin (point-marker))
          (insert body "\n")
          ;; tag the body so the new comment can be edited right away
          (reddigg--mark-body-overlay begin (point-marker)))))))

(defun reddigg--comment-data-with-fallback (server-comment local-body)
  "Build a comment-data hash-table to insert locally.

By the time this is called the POST to reddit has already
succeeded, so we don't want a partial/missing api/comment
response (SERVER-COMMENT, possibly nil, possibly missing keys)
to stop us from showing the comment the user just made. Prefer
whatever the server gave us field-by-field, and fall back to
what we already know locally (the exact text we sent, the
logged-in username) or a sane placeholder otherwise."
  (let ((merged (make-hash-table :test 'equal))
        (server-comment (if (hash-table-p server-comment)
                            server-comment
                          (make-hash-table :test 'equal))))
    (puthash "author" (or (gethash "author" server-comment)
                           reddigg--current-user
                           "[unknown]")
             merged)
    ;; The body we sent is authoritative: it's exactly what reddit received,
    ;; so prefer it over anything (or nothing) the server echoes back.
    (puthash "body" (or local-body (gethash "body" server-comment) "") merged)
    (puthash "name" (or (gethash "name" server-comment) "") merged)
    (puthash "subreddit" (gethash "subreddit" server-comment) merged)
    (puthash "likes" (gethash "likes" server-comment) merged)
    (puthash "score" (or (gethash "score" server-comment) 1) merged)
    (puthash "created_utc" (or (gethash "created_utc" server-comment)
                                (float-time))
             merged)
    merged))

(defconst reddigg--comment-action "comment"
  "Server action for replying.  Params: parent, text.")

(defun reddigg--send-comment (compose-buffer body)
  (let ((parent-id (buffer-local-value 'reddigg-compose--parent-id compose-buffer))
        (target-marker (buffer-local-value 'reddigg-compose--target-marker compose-buffer)))
    (promise-chain (reddigg--promise-post reddigg--comment-action
                                          (list (cons "parent" parent-id)
                                                (cons "text" body)))
      (then (lambda (data)
              ;; The POST has already succeeded by this point. Everything
              ;; below is best-effort local rendering, so wrap it in
              ;; condition-case rather than letting a display bug propagate
              ;; up to promise-catch, where it would be misreported as a
              ;; failed reply even though reddit already has the comment.
              (condition-case err
                  (let* ((json (and (hash-table-p data) (gethash "json" data)))
                         (jdata (and (hash-table-p json) (gethash "data" json)))
                         (things (and (hash-table-p jdata) (gethash "things" jdata)))
                         (first-thing (and things (> (length things) 0)
                                           (elt things 0)))
                         (server-comment (and (hash-table-p first-thing)
                                              (gethash "data" first-thing))))
                    (reddigg--insert-new-comment
                     target-marker
                     (reddigg--comment-data-with-fallback server-comment body)))
                (error
                 (message "reddigg: comment posted, but displaying it locally \
failed (%s); refresh to see it." (error-message-string err))))
              (when (buffer-live-p compose-buffer)
                (kill-buffer compose-buffer))
              (message "reddigg: reply posted")))
      (promise-catch (lambda (reason)
                       (message "reddigg: reply failed: %s"
                                (reddigg--reason-string reason)))))))

;;;###autoload
(defun reddigg-reply-at-point ()
  "Compose a reply to the post or comment at point."
  (interactive)
  (let* ((thing (reddigg--thing-at-point))
         (parent-id (plist-get thing :id))
         (parent-marker (point-marker))
         (buf (generate-new-buffer "*reddigg-reply*")))
    ;; learn our username while the user types, so the locally inserted
    ;; reply is attributed correctly
    (reddigg--prefetch-session)
    (with-current-buffer buf
      (org-mode)
      (reddigg-compose-mode 1)
      (setq-local reddigg-compose--kind 'comment)
      (setq-local reddigg-compose--parent-id parent-id)
      (setq-local reddigg-compose--target-marker parent-marker)
      (insert (format "# reddigg: replying to %s\n" parent-id))
      (insert "# reddigg: C-c C-c to send, C-c C-k to abort\n\n"))
    (pop-to-buffer buf)
    (goto-char (point-max))))

(defconst reddigg--submit-action "submit"
  "Server action for new submissions.
Params: subreddit, title, kind, text, url.")

(defun reddigg--submit-comments-path (post-id)
  "Return a reddigg comments path for the submitted POST-ID."
  (format "comments/%s" (replace-regexp-in-string "\\`t3_" "" post-id)))

(defun reddigg--send-submit (compose-buffer body)
  "Submit the post described by COMPOSE-BUFFER with BODY."
  (let* ((subreddit (buffer-local-value 'reddigg-compose--submit-sr compose-buffer))
         (kind (buffer-local-value 'reddigg-compose--submit-kind compose-buffer))
         (title (buffer-local-value 'reddigg-compose--submit-title compose-buffer))
         (link-p (equal kind "link")))
    (promise-chain
        (reddigg--promise-post
         reddigg--submit-action
         (list (cons "subreddit" subreddit)
               (cons "title" title)
               (cons "kind" kind)
               (cons "text" (if link-p "" body))
               (cons "url" (if link-p body ""))))
      (then
       (lambda (data)
         (let* ((json (and (hash-table-p data) (gethash "json" data)))
                (payload (and (hash-table-p json) (gethash "data" json)))
                (post-id (and (hash-table-p payload) (gethash "name" payload)))
                (post-url (and (hash-table-p payload) (gethash "url" payload)))
                (comments-path (and post-id
                                    (reddigg--submit-comments-path post-id))))
           (when (buffer-live-p compose-buffer)
             (kill-buffer compose-buffer))
           (message "reddigg: post submitted%s%s"
                    (if post-id (format " (%s)" post-id) "")
                    (if post-url (format " %s" post-url) ""))
           (when (and comments-path
                      (y-or-n-p "reddigg: view the new post's comments? "))
             (reddigg--view-comments comments-path t)))))
      (promise-catch
       (lambda (reason)
         (message "reddigg: submit failed: %s"
                  (reddigg--reason-string reason)))))))

;;;###autoload
(defun reddigg-submit-post ()
  "Compose and submit a new Reddit post."
  (interactive)
  (let* ((choices (mapcar (lambda (sub) (if (symbolp sub)
                                            (symbol-name sub)
                                          sub))
                          reddigg-subs))
         (subreddit (string-trim
                     (completing-read "Subreddit: " choices nil nil)))
         (kind (completing-read "Post kind: " '("self" "link") nil t))
         (title (string-trim (read-string "Title: ")))
         (buf (generate-new-buffer "*reddigg-submit*")))
    (when (string-empty-p subreddit)
      (user-error "reddigg: subreddit cannot be empty"))
    (when (string-empty-p title)
      (user-error "reddigg: title cannot be empty"))
    (with-current-buffer buf
      (org-mode)
      (reddigg-compose-mode 1)
      (setq-local reddigg-compose--kind 'submit)
      (setq-local reddigg-compose--submit-sr subreddit)
      (setq-local reddigg-compose--submit-kind kind)
      (setq-local reddigg-compose--submit-title title)
      (insert (format "# reddigg: submitting to r/%s\n" subreddit))
      (insert (format "# reddigg: %s post: %s\n" kind title))
      (insert "# reddigg: C-c C-c to submit, C-c C-k to abort\n\n")
      (insert (if (equal kind "link")
                  "# reddigg: Paste the link URL below.\n"
                "# reddigg: Write the post body below.\n")))
    (pop-to-buffer buf)
    (goto-char (point-max))))

;;; --- Edit / delete your own content ----------------------------------------

(defconst reddigg--edit-action "edit"
  "Server action for editing text.  Params: id, text.")
(defconst reddigg--del-action "delete"
  "Server action for deleting.  Params: id.")

(defun reddigg--replace-body-at-marker (heading-marker new-text)
  "Replace the editable body text of the reddigg entry at HEADING-MARKER
with NEW-TEXT (the raw markdown just submitted to reddit)."
  (with-current-buffer (marker-buffer heading-marker)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char heading-marker)
        (org-back-to-heading t)
        (let ((ov (reddigg--find-body-overlay)))
          (if (not ov)
              (message "reddigg: edit saved on reddit, but couldn't find the \
body in this buffer to update it locally; refresh to see the change.")
            (let ((start (overlay-start ov)))
              (goto-char start)
              (delete-region start (overlay-end ov))
              (insert new-text "\n")
              (move-overlay ov start (point))
              (reddigg--sanitize-range start (point)))))))))

(defun reddigg--send-edit (compose-buffer body)
  (let ((thing-id (buffer-local-value 'reddigg-compose--parent-id compose-buffer))
        (target-marker (buffer-local-value 'reddigg-compose--target-marker compose-buffer)))
    (promise-chain (reddigg--promise-post reddigg--edit-action
                                          (list (cons "id" thing-id)
                                                (cons "text" body)))
      (then (lambda (_data)
              (reddigg--replace-body-at-marker target-marker body)
              (when (buffer-live-p compose-buffer)
                (kill-buffer compose-buffer))
              (message "reddigg: edit saved")))
      (promise-catch (lambda (reason)
                       (message "reddigg: edit failed: %s"
                                (reddigg--reason-string reason)))))))

(defun reddigg--open-edit-buffer (id marker existing-text)
  "Pop up an edit compose buffer for thing ID (heading at MARKER),
pre-filled with EXISTING-TEXT."
  (let ((buf (generate-new-buffer "*reddigg-edit*")))
    (with-current-buffer buf
      (org-mode)
      (reddigg-compose-mode 1)
      (setq-local reddigg-compose--kind 'edit)
      (setq-local reddigg-compose--parent-id id)
      (setq-local reddigg-compose--target-marker marker)
      (insert (format "# reddigg: editing %s\n" id))
      (insert "# reddigg: C-c C-c to save, C-c C-k to abort\n\n")
      (when existing-text (insert existing-text)))
    (pop-to-buffer buf)
    (goto-char (point-max))))

;;;###autoload
(defun reddigg-edit-at-point ()
  "Compose an edit to the post or comment at point.
Only works on entries you authored; only self-posts and comments have
editable text on reddit (link posts don't)."
  (interactive)
  ;; Gather everything that depends on point *now*; the session lookup
  ;; below is asynchronous.
  (let* ((thing (reddigg--thing-at-point))
         (id (plist-get thing :id))
         (author (plist-get thing :author))
         (ov (reddigg--find-body-overlay))
         (existing-text (when ov
                          (buffer-substring-no-properties
                           (overlay-start ov) (overlay-end ov))))
         (marker (point-marker)))
    (promise-chain (reddigg--promise-session-info)
      (then (lambda (info)
              (unless (equal author (cdr info))
                (user-error "reddigg: this entry isn't yours to edit (author: %s)"
                            (or author "unknown")))
              (reddigg--open-edit-buffer id marker existing-text)))
      (promise-catch (lambda (reason)
                       (message "reddigg: cannot edit: %s"
                                (reddigg--reason-string reason)))))))

;;;###autoload
(defun reddigg-delete-at-point ()
  "Delete the post or comment at point. Only works on entries you authored."
  (interactive)
  (let* ((thing (reddigg--thing-at-point))
         (id (plist-get thing :id))
         (author (plist-get thing :author))
         (marker (point-marker)))
    (promise-chain (reddigg--promise-session-info)
      (then (lambda (info)
              (unless (equal author (cdr info))
                (user-error "reddigg: this entry isn't yours to delete (author: %s)"
                            (or author "unknown")))
              (if (not (y-or-n-p "reddigg: really delete this? "))
                  (message "reddigg: delete cancelled")
                (promise-then
                 (reddigg--promise-post reddigg--del-action (list (cons "id" id)))
                 (lambda (_data)
                   (with-current-buffer (marker-buffer marker)
                     (let ((inhibit-read-only t))
                       (save-excursion
                         (goto-char marker)
                         (org-back-to-heading t)
                         (org-cut-subtree))))
                   (message "reddigg: deleted"))))))
      (promise-catch (lambda (reason)
                       (message "reddigg: delete failed: %s"
                                (reddigg--reason-string reason)))))))

;;; --- View-buffer keymap (voting, replying, editing, deleting) --------------

(defvar reddigg-view-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-v u") #'reddigg-vote-up)
    (define-key m (kbd "C-c C-v d") #'reddigg-vote-down)
    (define-key m (kbd "C-c C-v 0") #'reddigg-vote-clear)
    (define-key m (kbd "C-c C-v r") #'reddigg-reply-at-point)
    (define-key m (kbd "C-c C-v e") #'reddigg-edit-at-point)
    (define-key m (kbd "C-c C-v x") #'reddigg-delete-at-point)
    (define-key m (kbd "C-c C-v i") #'reddigg-show-images)
    (define-key m (kbd "C-c C-v I") #'reddigg-toggle-images)
    (define-key m (kbd "C-c C-v v") #'reddigg-play-video)
    m)
  "Keymap for reddigg's generated browsing buffers.")

(define-minor-mode reddigg-view-mode
  "Minor mode for reddigg's generated org buffers (posts, comments)."
  :lighter " reddigg"
  :keymap reddigg-view-mode-map)

;;; --- buffers and rendering -----------------------------------------------

(defvar reddigg--main-buffer "*reddigg-main*"
  "Buffer for main page.")

(defvar reddigg--buffer "*reddigg*"
  "Buffer for main page.")

(defvar reddigg--cmt-buffer "*reddigg-comments*"
  "Comment buffer.")

(defun reddigg--get-buffer ()
  "Get buffer for sub."
  (get-buffer-create reddigg--buffer))

(defun reddigg--get-cmt-buffer ()
  "Get buffer for comments."
  (get-buffer-create reddigg--cmt-buffer))

(defun reddigg--get-main-buffer ()
  "Get main buffer."
  (get-buffer-create reddigg--main-buffer))

(cl-defun reddigg--print-sub (data sub &optional append &key sort scope)
  "Print sub post list in DATA for SUB.
SORT: top, hot, best, rising, controversial.
SCOPE: hour, day, week, year, all.
When APPEND is non-nil, will not delete buffer but append to it,
after deleting the current line which should be the More button."
  (with-current-buffer (reddigg--get-buffer)
    (save-excursion
      (if append
          (kill-whole-line)
        (erase-buffer)
        (reddigg--reset-image-state)
        ;; insert header and links
        (insert "#+startup: overview indent\n")
        (insert (format "#+title: %s sorted by %s%s\n"
                        (if (< (length sub) 30)
                            sub
                          "posts")
                        (if sort sort 'default)
                        (if scope
                            (format " %s" scope)
                          "")))
        (insert (format reddigg--template-sub* sub "refresh"))
        (insert " ")
        (insert (format reddigg--template-sub-sort
                        sub
                        ":sort 'new"
                        "new"))
        (insert " ")
        (insert (format reddigg--template-sub-sort
                        sub
                        ":sort 'rising"
                        "rising"))
        (insert "\n")
        ;; top
        (insert (format reddigg--template-sub-sort
                        sub
                        ":sort 'top :scope 'hour"
                        "top-hour"))
        (insert " ")
        (insert (format reddigg--template-sub-sort
                        sub
                        ":sort 'top :scope 'day"
                        "top-day"))
        (insert " ")
        (insert (format reddigg--template-sub-sort
                        sub
                        ":sort 'top :scope 'week"
                        "top-week"))
        (insert " ")
        (insert (format reddigg--template-sub-sort
                        sub
                        ":sort 'top :scope 'month"
                        "top-month"))
        (insert " ")
        (insert (format reddigg--template-sub-sort
                        sub
                        ":sort 'top :scope 'year"
                        "top-year"))
        (insert " ")
        (insert (format reddigg--template-sub-sort
                        sub
                        ":sort 'top :scope 'all"
                        "top-all"))
        (insert "\n")
        ;; controversial
        (insert (format reddigg--template-sub-sort
                        sub
                        ":sort 'controversial :scope 'hour"
                        "controversial-hour"))
        (insert " ")
        (insert (format reddigg--template-sub-sort
                        sub
                        ":sort 'controversial :scope 'day"
                        "con-day"))
        (insert " ")
        (insert (format reddigg--template-sub-sort
                        sub
                        ":sort 'controversial :scope 'week"
                        "con-week"))
        (insert " ")
        (insert (format reddigg--template-sub-sort
                        sub
                        ":sort 'controversial :scope 'month"
                        "con-month"))
        (insert " ")
        (insert (format reddigg--template-sub-sort
                        sub
                        ":sort 'controversial :scope 'year"
                        "con-year"))
        (insert " ")
        (insert (format reddigg--template-sub-sort
                        sub
                        ":sort 'controversial :scope 'all"
                        "con-all"))
        (insert "\n"))

      (seq-do
       (lambda (it)
         (let* ((my-it (gethash "data" it))
                (id (gethash "name" my-it))
                (media (reddigg--post-media my-it))
                (images (plist-get media :images))
                (poster (plist-get media :poster)))
           (insert "* " (gethash "title" my-it) "\n")
           (insert ":PROPERTIES:\n")
           (insert (format ":REDDIGG_ID: %s\n" id))
           (insert (format ":REDDIGG_AUTHOR: %s\n" (gethash "author" my-it)))
           (insert (format ":REDDIGG_SUBREDDIT: %s\n" (gethash "subreddit" my-it)))
           (insert (format ":REDDIGG_LIKES: %s\n" (reddigg--likes->string (gethash "likes" my-it))))
           (insert (format ":REDDIGG_SCORE: %s\n" (gethash "score" my-it)))
           (insert (format ":REDDIGG_CREATED: %s\n" (reddigg--format-created (gethash "created_utc" my-it))))
           (reddigg--insert-media-properties media)
           (insert ":END:\n")
           (insert "| " (ht-get my-it "subreddit_name_prefixed") " | ")
           (insert "score: " (format "%s" (gethash "score" my-it) ) " | ")
           (insert "comments: " (format "%s" (gethash "num_comments" my-it)) " | ")
           (insert "created: " (format-time-string "%Y-%m-%d" (gethash "created_utc" my-it)) "\n")
           (let ((selftext (gethash "selftext" my-it)) begin end)
             (if (or (null selftext) (string-empty-p selftext))
                 (insert (format "%s \n[[eww:%s][view in eww]]\n"
                                 (gethash "url" my-it) (gethash "url" my-it)))
               (setq begin (point-marker))
               (insert "\n" selftext "\n")
               (setq end (point-marker))
               (reddigg--sanitize-range begin end)
               (reddigg--mark-body-overlay begin end)))
           (let ((image-pos (reddigg--insert-media-link media)))
             (insert (format "[[elisp:(reddigg--view-comments \"%s\")][view comments]]\n"
                             (ht-get my-it "permalink")))
             (when image-pos
               (reddigg--register-image-area id images image-pos poster)))))
       (ht-get data "children"))
      (let ((after (ht-get data "after")))
        (when after
          (insert (format "* [[elisp:(reddigg--view-sub-more \"%s\" \"%s\" '%s '%s)][More]]"
                          sub after sort scope))))
      (reddigg--ensure-modes))))

(defun reddigg--sanitize-range (begin end)
  "Remove heading * inside rang between BEGIN and END."
  (save-excursion
    (dolist (it reddigg-replacement-list)
      (goto-char begin)
      (while (re-search-forward (car it) end t)
        (replace-match (cdr it))))))

(defun reddigg--print-comment-list (cmt-list level)
  "Print comments from CMT-LIST with LEVEL."
  (seq-do
   (lambda (it)
     (let* ((kind (ht-get it "kind"))
            (data (ht-get it "data"))
            (replies (ht-get data "replies"))
            (depth (ht-get data "depth"))
            (my-level (make-string (+ 2 depth) ?*))
            begin end)
       (if (string= kind "more")
           ;; (insert level " reddigg: too many subcomments\n")
           (insert my-level
                   (format " [[elisp:(reddigg--view-more-cmts \"%s\" \"%s\")][load more comments (%s)]]\n"
                           level
                           (mapconcat #'identity (ht-get data "children") ",")
                           (ht-get data "count")))

         (insert my-level " " (ht-get data "author") "\n")
         (insert ":PROPERTIES:\n")
         (insert (format ":REDDIGG_ID: %s\n" (ht-get data "name")))
         (insert (format ":REDDIGG_AUTHOR: %s\n" (ht-get data "author")))
         (insert (format ":REDDIGG_SUBREDDIT: %s\n" (ht-get data "subreddit")))
         (insert (format ":REDDIGG_LIKES: %s\n" (reddigg--likes->string (ht-get data "likes"))))
         (insert (format ":REDDIGG_SCORE: %s\n" (ht-get data "score")))
         (insert (format ":REDDIGG_CREATED: %s\n" (reddigg--format-created (ht-get data "created_utc"))))
         (insert ":END:\n")
         (setq begin (point-marker))
         (insert (ht-get data "body") "\n")
         (setq end (point-marker))
         (reddigg--sanitize-range begin end)
         (reddigg--mark-body-overlay begin end)
         (when (hash-table-p replies)
           (reddigg--print-comment-list (ht-get* replies "data" "children") (concat level "*"))))))
   cmt-list))

(defun reddigg--print-comment-1 (data)
  "Print the post itself as a level-1 heading, so it's a full reddigg
entry like any post or comment -- votable, replyable, editable, and
deletable, same as everything nested under it.
Return (ID IMAGES IMAGE-POSITION POSTER) for `reddigg--print-comments',
which registers the image area after the comments are inserted."
  (let* ((cmt (ht-get* (aref (ht-get* data "data" "children") 0) "data"))
         (id (ht-get cmt "name"))
         (media (reddigg--post-media cmt))
         (images (plist-get media :images))
         (poster (plist-get media :poster))
         begin end)
    (insert "* " (ht-get cmt "title") "\n")
    (insert ":PROPERTIES:\n")
    (insert (format ":REDDIGG_ID: %s\n" id))
    (insert (format ":REDDIGG_AUTHOR: %s\n" (ht-get cmt "author")))
    (insert (format ":REDDIGG_SUBREDDIT: %s\n" (ht-get cmt "subreddit")))
    (insert (format ":REDDIGG_LIKES: %s\n" (reddigg--likes->string (ht-get cmt "likes"))))
    (insert (format ":REDDIGG_SCORE: %s\n" (ht-get cmt "score")))
    (insert (format ":REDDIGG_CREATED: %s\n" (reddigg--format-created (ht-get cmt "created_utc"))))
    (reddigg--insert-media-properties media)
    (insert ":END:\n")
    (insert "| " (ht-get cmt "subreddit_name_prefixed") " | ")
    (insert "score: " (format "%s" (ht-get cmt "score")) " | ")
    (insert "author: " (ht-get cmt "author") " | ")
    (insert "created: " (reddigg--format-created (ht-get cmt "created_utc")) "\n")
    (insert (ht-get cmt "url") "\n")
    (insert (format "[[elisp:(reddigg--view-comments \"%s\" t)][refresh]]\n"
                    (ht-get cmt "permalink")))
    (setq begin (point-marker))
    (insert (or (gethash "selftext" cmt) "") "\n")
    (setq end (point-marker))
    (reddigg--sanitize-range begin end)
    (reddigg--mark-body-overlay begin end)
    (let ((image-pos (reddigg--insert-media-link media)))
      (list id images image-pos poster))))

(defun reddigg--print-comment-2 (data level)
  "Extrac comment list from DATA and pass it along with LEVEL."
  (reddigg--print-comment-list (ht-get* data "data" "children") level))

(defun reddigg--print-comments (data)
  "Print comments DATA to buffer."
  (with-current-buffer (reddigg--get-cmt-buffer)
    (erase-buffer)
    (reddigg--reset-image-state)
    (insert "#+startup: show2levels indent\n")
    (insert (format "#+title: comments for '%s'\n"
                    (ht-get* (aref (ht-get* (aref data 0) "data" "children") 0) "data" "title")))
    (let* ((post (reddigg--print-comment-1 (aref data 0)))
           (post-id (nth 0 post))
           (images (nth 1 post))
           (image-pos (nth 2 post))
           (poster (nth 3 post)))
      (reddigg--print-comment-2 (aref data 1) "*")
      ;; Register the post's image area now that the comments are in
      ;; place, so images land above them instead of after the last one.
      (when image-pos
        (reddigg--register-image-area post-id images image-pos poster))
      (reddigg--ensure-modes)
      ;; `overview' startup visibility (set by `reddigg--ensure-modes' via
      ;; `org-set-startup-visibility') folds the post's own body along
      ;; with all the comments underneath it -- reveal just the post's
      ;; own entry (heading + body, not its comment children) so it
      ;; still reads the way it always has.
      (goto-char (point-min))
      (when (re-search-forward "^\\* " nil t)
        (beginning-of-line)
        (org-show-entry))
      ;; must set here after org-mode is in otherwise when org-mode kicks in all
      ;; local variables will be killed
      (setq reddigg--cmt-list-id post-id))))

;;;###autoload
(defun reddigg-view-comments (cmt)
  "Ask and print CMT to buffer.
CMT may be a full reddit URL or a path like
r/emacs/comments/lfww57/weekly_tipstricketc_thread/."
  (interactive "sComment: ")
  ;; `reddigg--promise-comments' normalizes URLs/slashes itself.
  (reddigg--view-comments cmt))

(defun reddigg--view-comments (cmt &optional new-window)
  "Ask and print CMT to buffer. When NEW-WINDOW will show in new buffer."
  (promise-chain (reddigg--promise-comments cmt)
    (then #'reddigg--print-comments)
    (then (lambda (&rest _)
            (if new-window
                (switch-to-buffer (reddigg--get-cmt-buffer))
              (select-window
               (display-buffer
                (reddigg--get-cmt-buffer)
                '(display-buffer-use-some-window (inhibit-same-window . t)))))))
    (promise-catch (lambda (reason)
                     (message "reddigg: could not load comments: %s"
                              (reddigg--reason-string reason))))))


(cl-defun reddigg--view-sub (sub &key after before append sort scope)
  "Fetch SUB and print its post list.
AFTER: fetch post after name.
BEFORE: fetch posts before name.
APPEND: tell `reddigg--print-sub' to append.
SORT: top, hot, best, rising, controversial.
SCOPE: hour, day, week, year, all."
  (promise-chain (reddigg--promise-posts sub
                                         :after after
                                         :before before
                                         :sort sort
                                         :scope scope)
    (then (lambda (result)
            (ht-get result "data")))
    (then (lambda (data)
            (reddigg--print-sub data sub append
                                :sort sort
                                :scope scope)))
    (then (lambda (&rest _)
            (switch-to-buffer (reddigg--get-buffer))))
    (promise-catch (lambda (reason)
                     (message "reddigg: could not load %s: %s"
                              sub (reddigg--reason-string reason))))))

(defun reddigg--view-more-cmts (level children)
  "Get more comments from CHILDREN and print at LEVEL."
  (promise-chain (reddigg--promise-more-comments children)
    (then (lambda (result)
            (ht-get* result "json" "data" "things")))
    (then (lambda (result)
            (kill-whole-line)
            (save-excursion
              (reddigg--print-comment-list result level))))
    (promise-catch (lambda (reason)
                     (message "reddigg: could not load more comments: %s"
                              (reddigg--reason-string reason))))))

;;;###autoload
(defun reddigg-view-sub (sub)
  "Prompt SUB and print its post list."
  (interactive (list (completing-read "Select sub reddit:" reddigg-subs)))
  (reddigg--view-sub sub))

;;;###autoload
(defun reddigg-view-frontpage ()
  "View frontpage."
  (interactive)
  (reddigg--view-sub (mapconcat #'symbol-name reddigg-subs "+")))

(defun reddigg--view-sub-more (sub after sort scope)
  "Fetch SUB from AFTER and append."
  (reddigg--view-sub sub :after after :append t :sort sort :scope scope))

;;;###autoload
(defun reddigg-view-main ()
  "View main page."
  (interactive)
  (switch-to-buffer (or (get-buffer reddigg--main-buffer)
                        (with-current-buffer (reddigg--get-main-buffer)
                          (erase-buffer)
                          (insert "#+startup: overview indent\n")
                          (insert "#+title: main\n\n")
                          (insert (format reddigg--template-sub "all" "all"))
                          (insert (format reddigg--template-sub "popular" "popular"))
                          (insert (format reddigg--template-sub (mapconcat #'symbol-name reddigg-subs "+") "main"))
                          (dolist (sub reddigg-subs)
                            (insert (format reddigg--template-sub sub sub)))
                          (reddigg--ensure-modes)
                          reddigg--main-buffer))))

(provide 'reddigg)
;;; reddigg.el ends here
