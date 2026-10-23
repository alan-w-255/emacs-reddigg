;;; reddigg-test.el --- Tests for reddigg  -*- lexical-binding: t; -*-

;;; Commentary:
;; Run from the repository root, with the dependencies on `load-path':
;;
;;   emacs -Q --batch -L . -L /path/to/promise -L /path/to/ht \
;;     -L /path/to/dash -l test/reddigg-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; The image tests never touch the network: downloads are stubbed and
;; the cache lives in a temporary directory.

;;; Code:

(require 'ert)
(require 'reddigg)

(defun reddigg-test--post-list (post-json)
  "Build a reddit listing from the JSON object POST-JSON."
  (let ((post (reddigg--parse-json-string post-json))
        (thing (make-hash-table :test 'equal))
        (data (make-hash-table :test 'equal)))
    (puthash "data" post thing)
    (puthash "children" (vector thing) data)
    (puthash "after" nil data)
    data))

(defconst reddigg-test--post-json
  "{\"name\":\"t3_test\",
    \"title\":\"A test post\",
    \"author\":\"tester\",
    \"subreddit\":\"test\",
    \"subreddit_name_prefixed\":\"r/test\",
    \"likes\":null,
    \"score\":5,
    \"num_comments\":1,
    \"created_utc\":1600000000,
    \"url\":\"https://i.redd.it/test.jpg\",
    \"permalink\":\"/r/test/comments/test/a_test_post/\",
    \"selftext\":\"\",
    \"post_hint\":\"image\",
    \"preview\":{\"images\":[{\"source\":{\"url\":\"https://preview.redd.it/test.jpeg?w=1000&amp;s=x\",
                                       \"width\":1000,
                                       \"height\":800},
                            \"resolutions\":[{\"url\":\"https://preview.redd.it/test.jpeg?w=320&amp;s=1\",
                                             \"width\":320,
                                             \"height\":240},
                                            {\"url\":\"https://preview.redd.it/test.jpeg?w=640&amp;s=2\",
                                             \"width\":640,
                                             \"height\":480}]}]}}"
  "A minimal reddit image post.")

(defun reddigg-test--video (post-json)
  "Return the video plist of the reddit post in POST-JSON."
  (reddigg--post-video (reddigg--parse-json-string post-json)))

(defconst reddigg-test--video-json
  "{\"name\":\"t3_test_video\",
    \"title\":\"A test video\",
    \"author\":\"tester\",
    \"subreddit\":\"test\",
    \"subreddit_name_prefixed\":\"r/test\",
    \"likes\":null,
    \"score\":5,
    \"num_comments\":0,
    \"created_utc\":1600000000,
    \"url\":\"https://v.redd.it/abc123\",
    \"permalink\":\"/r/test/comments/video/a_test_video/\",
    \"selftext\":\"\",
    \"post_hint\":\"hosted:video\",
    \"is_video\":true,
    \"thumbnail\":\"https://b.thumbs.redditmedia.com/thumb.jpg\",
    \"media\":{\"reddit_video\":{\"fallback_url\":\"https://v.redd.it/abc123/DASH_480.mp4?source=fallback\",
                                \"hls_url\":\"https://v.redd.it/abc123/HLSPlaylist.m3u8?a=1&amp;b=2\",
                                \"duration\":90,
                                \"width\":854,
                                \"height\":480,
                                \"is_gif\":false}},
    \"preview\":{\"images\":[{\"source\":{\"url\":\"https://preview.redd.it/poster.jpeg?w=1000&amp;s=x\",
                                       \"width\":1000,
                                       \"height\":562},
                            \"resolutions\":[{\"url\":\"https://preview.redd.it/poster.jpeg?w=320&amp;s=1\",
                                             \"width\":320,
                                             \"height\":180},
                                            {\"url\":\"https://preview.redd.it/poster.jpeg?w=640&amp;s=2\",
                                             \"width\":640,
                                             \"height\":360}]}]}}"
  "A minimal reddit video post.")

(defun reddigg-test--video-entry ()
  "Return an org buffer holding an entry with video properties."
  (let ((buffer (generate-new-buffer " *reddigg-test-video*")))
    (with-current-buffer buffer
      (org-mode)
      (insert "* A video\n"
              ":PROPERTIES:\n"
              ":REDDIGG_VIDEO: HLS-URL\n"
              ":REDDIGG_VIDEO_FALLBACK: MP4-URL\n"
              ":END:\n"
              "body\n"))
    buffer))

(ert-deftest reddigg-test-image-url-p ()
  (should (reddigg--image-url-p "https://i.redd.it/a.jpg"))
  (should (reddigg--image-url-p
           "https://preview.redd.it/a.jpeg?width=640&crop=smart&auto=webp&s=x"))
  (should (reddigg--image-url-p "http://example.com/a.PNG"))
  (should-not (reddigg--image-url-p "https://example.com/a.html"))
  (should-not (reddigg--image-url-p "ftp://example.com/a.jpg"))
  (should-not (reddigg--image-url-p "https://example.com/a.jpg.txt"))
  (should-not (reddigg--image-url-p "https://localhost/a.jpg"))
  (should-not (reddigg--image-url-p "http://127.0.0.1:1979/a.jpg"))
  (should-not (reddigg--image-url-p "http://192.168.1.4/a.jpg"))
  (should-not (reddigg--image-url-p "http://172.20.0.1/a.jpg"))
  (should-not (reddigg--image-url-p nil)))

(ert-deftest reddigg-test-reddit-post-url-p ()
  (should (reddigg-reddit-post-url-p
           "https://www.reddit.com/r/emacs/comments/lfww57/a_title/"))
  (should (reddigg-reddit-post-url-p
           "https://old.reddit.com/r/emacs/comments/lfww57/a_title/?utm_source=share"))
  (should (reddigg-reddit-post-url-p "https://reddit.com/comments/lfww57"))
  (should (reddigg-reddit-post-url-p "http://np.reddit.com/r/emacs/comments/lfww57/"))
  (should (reddigg-reddit-post-url-p "https://redd.it/lfww57"))
  (should-not (reddigg-reddit-post-url-p "https://www.reddit.com/r/emacs/"))
  (should-not (reddigg-reddit-post-url-p "https://www.reddit.com/user/foo"))
  (should-not (reddigg-reddit-post-url-p
               "https://example.com/r/emacs/comments/lfww57/"))
  (should-not (reddigg-reddit-post-url-p
               "https://reddit.com.evil.example/r/emacs/comments/lfww57/"))
  (should-not (reddigg-reddit-post-url-p nil)))

(ert-deftest reddigg-test-normalize-cmt-path ()
  (should (equal (reddigg--normalize-cmt-path
                  "https://www.reddit.com/r/emacs/comments/lfww57/a_title/?utm_source=share")
                 "r/emacs/comments/lfww57/a_title"))
  (should (equal (reddigg--normalize-cmt-path
                  "https://old.reddit.com/r/emacs/comments/lfww57/a_title/")
                 "r/emacs/comments/lfww57/a_title"))
  (should (equal (reddigg--normalize-cmt-path
                  "https://reddit.com/comments/lfww57")
                 "comments/lfww57"))
  (should (equal (reddigg--normalize-cmt-path "https://redd.it/lfww57")
                 "comments/lfww57"))
  (should (equal (reddigg--normalize-cmt-path
                  "r/emacs/comments/lfww57/weekly_tipstricketc_thread/")
                 "r/emacs/comments/lfww57/weekly_tipstricketc_thread"))
  (should (equal (reddigg--normalize-cmt-path
                  "/r/emacs/comments/lfww57/a_title.json?sort=top")
                 "r/emacs/comments/lfww57/a_title")))

(ert-deftest reddigg-test-browse-url-handler-registered ()
  (require 'browse-url)
  (let ((pair (seq-find (lambda (entry)
                          (eq (cdr entry) #'reddigg-open-url))
                        browse-url-handlers)))
    (should pair)
    (should (string-match-p
             (car pair)
             "https://www.reddit.com/r/emacs/comments/lfww57/a_title/"))
    (should-not (string-match-p (car pair) "https://www.reddit.com/r/emacs/"))))

(ert-deftest reddigg-test-open-url-rejects-non-post ()
  (should-error (reddigg-open-url "https://www.reddit.com/r/emacs/")
                :type 'user-error)
  (should-error (reddigg-open-url nil) :type 'user-error))

(ert-deftest reddigg-test-html-unescape ()
  (should (equal (reddigg--html-unescape "a&amp;b") "a&b"))
  (should (equal (reddigg--html-unescape "a&#x2F;b") "a/b"))
  (should-not (reddigg--html-unescape nil)))

(ert-deftest reddigg-test-post-preview-chooses-width ()
  (let ((reddigg-image-max-width 400))
    (should (equal (reddigg--post-image-urls
                    (reddigg--parse-json-string reddigg-test--post-json))
                   '("https://preview.redd.it/test.jpeg?w=640&s=2"))))
  (let ((reddigg-image-max-width 640))
    (should (equal (reddigg--post-image-urls
                    (reddigg--parse-json-string reddigg-test--post-json))
                   '("https://preview.redd.it/test.jpeg?w=640&s=2"))))
  (let ((reddigg-image-max-width nil))
    (should (equal (reddigg--post-image-urls
                    (reddigg--parse-json-string reddigg-test--post-json))
                   '("https://preview.redd.it/test.jpeg?w=1000&s=x")))))

(ert-deftest reddigg-test-post-image-urls ()
  ;; A plain image link with no preview data.
  (let ((reddigg-image-max-width 400))
    (should (equal (reddigg--post-image-urls
                    (reddigg--parse-json-string
                     "{\"url\":\"https://i.redd.it/direct.png\",
                       \"post_hint\":\"image\"}"))
                   '("https://i.redd.it/direct.png"))))
  ;; A link post with a preview is not an image post.
  (should-not (reddigg--post-image-urls
               (reddigg--parse-json-string
                "{\"url\":\"https://example.com/story\",
                  \"post_hint\":\"link\",
                  \"preview\":{\"images\":[{\"source\":{\"url\":\"https://preview.redd.it/x.jpg?w=1\"}}]}}")))
  ;; Crosspost parent is consulted once.
  (let ((reddigg-image-max-width 400))
    (should (equal (reddigg--post-image-urls
                    (reddigg--parse-json-string
                     "{\"url\":\"https://www.reddit.com/r/x/comments/y/z/\",
                       \"post_hint\":\"link\",
                       \"crosspost_parent_list\":[{\"url\":\"https://i.redd.it/parent.jpeg\",
                                                   \"post_hint\":\"image\"}]}"))
                   '("https://i.redd.it/parent.jpeg")))))

(ert-deftest reddigg-test-gallery-order ()
  (let* ((reddigg-image-max-width 400)
         (post (reddigg--parse-json-string
                "{\"url\":\"https://www.reddit.com/gallery/abc\",
                  \"is_gallery\":true,
                  \"post_hint\":\"gallery\",
                  \"gallery_data\":{\"items\":[{\"media_id\":\"b\"},{\"media_id\":\"a\"}]},
                  \"media_metadata\":{
                    \"a\":{\"status\":\"valid\",
                           \"p\":[{\"u\":\"https://preview.redd.it/a.jpeg?w=320&amp;s=a320\",
                                  \"x\":320,\"y\":240}],
                           \"s\":{\"u\":\"https://preview.redd.it/a.jpeg?w=1000&amp;s=a1000\",
                                 \"x\":1000,\"y\":750}},
                    \"b\":{\"status\":\"valid\",
                           \"p\":[{\"u\":\"https://preview.redd.it/b.jpeg?w=320&amp;s=b320\",
                                  \"x\":320,\"y\":240},
                                 {\"u\":\"https://preview.redd.it/b.jpeg?w=640&amp;s=b640\",
                                  \"x\":640,\"y\":480}],
                           \"s\":{\"u\":\"https://preview.redd.it/b.jpeg?w=1000&amp;s=b1000\",
                                 \"x\":1000,\"y\":750}}}}")))
    (should (equal (reddigg--post-image-urls post)
                   '("https://preview.redd.it/b.jpeg?w=640&s=b640"
                     "https://preview.redd.it/a.jpeg?w=320&s=a320")))))

(ert-deftest reddigg-test-image-extension-from-data ()
  (should (equal (reddigg--image-extension-from-data
                  (unibyte-string #x89 ?P ?N ?G 0))
                 "png"))
  (should (equal (reddigg--image-extension-from-data
                  (unibyte-string #xff #xd8 #xff 0))
                 "jpg"))
  (should (equal (reddigg--image-extension-from-data "GIF89a....")
                 "gif"))
  (should (equal (reddigg--image-extension-from-data "RIFF1234WEBP")
                 "webp"))
  (should (equal (reddigg--image-extension-from-data "BM....")
                 "bmp"))
  (should-not (reddigg--image-extension-from-data
               "HTTP/1.1 200 OK\r\n\r\n<html>")))

(ert-deftest reddigg-test-image-cache-file ()
  (let* ((reddigg-image-cache-dir (make-temp-file "reddigg-test-cache-" t))
         (url "https://i.redd.it/cache-test.jpg")
         (base (expand-file-name (secure-hash 'sha1 url)
                                 reddigg-image-cache-dir))
         (file (concat base ".png")))
    (unwind-protect
        (progn
          (should-not (reddigg--image-cache-file url))
          (with-temp-file file (insert "not empty"))
          (should (equal (reddigg--image-cache-file url) file))
          (delete-file file)
          (with-temp-file file (insert ""))
          (should-not (reddigg--image-cache-file url)))
      (delete-directory reddigg-image-cache-dir t))))

(ert-deftest reddigg-test-render-image-post-link-mode ()
  (let ((reddigg-image-display 'link)
        (reddigg-image-max-width 400)
        (reddigg-image-cache-dir (make-temp-file "reddigg-test-cache-" t)))
    (unwind-protect
        (progn
          (reddigg--print-sub (reddigg-test--post-list reddigg-test--post-json)
                              "test")
          (with-current-buffer "*reddigg*"
            (goto-char (point-min))
            (should (re-search-forward
                     "^:REDDIGG_IMAGES: https://preview.redd.it/test.jpeg\\?w=640&s=2$"
                     nil t))
            (should (re-search-forward "reddigg-show-images" nil t))
            (should-not (re-search-forward "\\[\\[file:" nil t))))
      (when (get-buffer "*reddigg*")
        (kill-buffer "*reddigg*"))
      (delete-directory reddigg-image-cache-dir t))))

(ert-deftest reddigg-test-fill-images-inserts-in-order ()
  (let ((reddigg-image-cache-dir (make-temp-file "reddigg-test-cache-" t))
        (files '("/tmp/reddigg-test-a.png" "/tmp/reddigg-test-b.png")))
    (unwind-protect
        (with-temp-buffer
          (org-mode)
          (insert "body\n")
          (let ((position (point))
                (urls '("https://example.com/a.png" "https://example.com/b.png"))
                (remaining files))
            ;; Register the anchor after inserting the text that must stay
            ;; below the images, exactly as the renderers do.
            (insert "[[view comments]]\n")
            (let ((anchor (copy-marker position t)))
              (cl-letf (((symbol-function 'reddigg--image-download)
                         (lambda (_url cb) (funcall cb (pop remaining))))
                        ((symbol-function 'reddigg--display-inline-images)
                         #'ignore))
                (reddigg--fill-images (current-buffer) anchor urls 0 #'ignore)))
            (should (equal (buffer-string)
                           (concat "body\n"
                                   "[[file:/tmp/reddigg-test-a.png]]\n\n"
                                   "[[file:/tmp/reddigg-test-b.png]]\n\n"
                                   "[[view comments]]\n")))))
      (delete-directory reddigg-image-cache-dir t))))

(ert-deftest reddigg-test-post-video ()
  (let* ((reddigg-image-max-width 400)
         (video (reddigg--post-video
                 (reddigg--parse-json-string reddigg-test--video-json))))
    (should (equal (plist-get video :url)
                   "https://v.redd.it/abc123/HLSPlaylist.m3u8?a=1&b=2"))
    (should (equal (plist-get video :hls)
                   "https://v.redd.it/abc123/HLSPlaylist.m3u8?a=1&b=2"))
    (should (equal (plist-get video :fallback)
                   "https://v.redd.it/abc123/DASH_480.mp4?source=fallback"))
    (should (equal (plist-get video :poster)
                   "https://preview.redd.it/poster.jpeg?w=640&s=2"))
    (should (= (plist-get video :duration) 90))
    (should-not (plist-get video :external)))
  ;; Image posts have no video.
  (should-not (reddigg--post-video
               (reddigg--parse-json-string reddigg-test--post-json))))

(ert-deftest reddigg-test-post-video-streams-and-hosts ()
  (let ((reddigg-image-max-width 400))
    ;; Without an HLS playlist the silent DASH stream is all there is.
    (let ((video (reddigg-test--video
                  "{\"url\":\"https://v.redd.it/x\",
                    \"post_hint\":\"hosted:video\",
                    \"media\":{\"reddit_video\":{\"fallback_url\":\"https://v.redd.it/x/DASH_240.mp4\",
                                                \"duration\":12}},
                    \"thumbnail\":\"https://b.thumbs.redditmedia.com/t.jpg\"}")))
      (should (equal (plist-get video :url)
                     "https://v.redd.it/x/DASH_240.mp4"))
      (should-not (plist-get video :hls))
      ;; A small thumbnail is still better than no poster.
      (should (equal (plist-get video :poster)
                     "https://b.thumbs.redditmedia.com/t.jpg")))
    ;; A crossposted video only carries preview.reddit_video_preview.
    (let ((video (reddigg-test--video
                  "{\"url\":\"https://v.redd.it/y\",
                    \"post_hint\":\"rich:video\",
                    \"preview\":{\"images\":[{\"source\":{\"url\":\"https://preview.redd.it/y.jpg?w=1\"}}],
                                  \"reddit_video_preview\":{\"fallback_url\":\"https://v.redd.it/y/DASH_360.mp4\"}}}"))) 
      (should (equal (plist-get video :url)
                     "https://v.redd.it/y/DASH_360.mp4")))
    ;; A video hosted elsewhere plays from its own URL.
    (let ((video (reddigg-test--video
                  "{\"url\":\"https://www.youtube.com/watch?v=abc\",
                    \"post_hint\":\"rich:video\",
                    \"is_video\":true,
                    \"preview\":{\"images\":[{\"source\":{\"url\":\"https://preview.redd.it/yt.jpg?w=1\"}}]}}")))
      (should (equal (plist-get video :url)
                     "https://www.youtube.com/watch?v=abc"))
      (should (plist-get video :external)))))

(ert-deftest reddigg-test-post-video-poster-is-an-image ()
  (let ((reddigg-image-max-width 400))
    (should (equal (reddigg--post-image-urls
                    (reddigg--parse-json-string reddigg-test--video-json))
                   '("https://preview.redd.it/poster.jpeg?w=640&s=2")))))

(ert-deftest reddigg-test-format-duration ()
  (should (equal (reddigg--format-duration 5) "0:05"))
  (should (equal (reddigg--format-duration 90) "1:30"))
  (should (equal (reddigg--format-duration 3672) "1:01:12"))
  (should-not (reddigg--format-duration nil)))

(ert-deftest reddigg-test-play-badge-svg ()
  (let ((svg (reddigg--play-badge-svg "poster & friends.jpg" 400 225)))
    (should (string-match-p
             "<svg[^>]*width=\"400\" height=\"225\"" svg))
    (should (string-match-p
             "xlink:href=\"poster &amp; friends.jpg\"" svg))
    (should (string-match-p "<circle" svg))
    (should (string-match-p "<polygon" svg))))

(ert-deftest reddigg-test-poster-badge-file-fallback ()
  ;; Without librsvg the poster is returned untouched.
  (cl-letf (((symbol-function 'reddigg--play-badge-supported-p)
             (lambda () nil)))
    (should (equal (reddigg--poster-badge-file "/tmp/poster.jpg")
                   "/tmp/poster.jpg"))))

(ert-deftest reddigg-test-poster-badge-file ()
  (skip-unless (reddigg--play-badge-supported-p))
  (let* ((dir (make-temp-file "reddigg-test-cache-" t))
         (poster (expand-file-name "abc.jpg" dir))
         (svg (expand-file-name "abc-play.svg" dir)))
    (unwind-protect
        (progn
          (with-temp-file poster (insert "not really a jpeg"))
          (cl-letf (((symbol-function 'image-size)
                     (lambda (&rest _) '(320 . 180))))
            (should (equal (reddigg--poster-badge-file poster) svg)))
          (should (file-regular-p svg))
          (with-temp-buffer
            (insert-file-contents svg)
            (should (string-match-p "width=\"320\" height=\"180\""
                                    (buffer-string)))
            (should (string-match-p "xlink:href=\"abc.jpg\""
                                    (buffer-string)))))
      (delete-directory dir t))))

(ert-deftest reddigg-test-fill-images-badges-the-poster ()
  (let ((reddigg-image-cache-dir (make-temp-file "reddigg-test-cache-" t))
        (badged nil))
    (unwind-protect
        (with-temp-buffer
          (org-mode)
          (let ((anchor (copy-marker (point) t))
                (poster "https://preview.redd.it/poster.jpg"))
            (cl-letf (((symbol-function 'reddigg--image-download)
                       (lambda (_url cb) (funcall cb "/tmp/reddigg-test.jpg")))
                      ((symbol-function 'reddigg--poster-badge-file)
                       (lambda (file) (push file badged) (concat file ".svg")))
                      ((symbol-function 'reddigg--image-supported-p)
                       (lambda (_file) t))
                      ((symbol-function 'reddigg--image-width) #'ignore)
                      ((symbol-function 'reddigg--display-inline-images) #'ignore))
              (reddigg--fill-images
               (current-buffer) anchor
               (list poster "https://preview.redd.it/other.jpg")
               0 #'ignore poster)))
          ;; Only the poster is badged, and it is shown from the SVG.
          (should (equal badged '("/tmp/reddigg-test.jpg")))
          (should (equal (buffer-string)
                         (concat "[[file:/tmp/reddigg-test.jpg.svg]]\n\n"
                                 "[[file:/tmp/reddigg-test.jpg]]\n\n"))))
      (delete-directory reddigg-image-cache-dir t))))

(ert-deftest reddigg-test-render-video-post-link-mode ()
  (let ((reddigg-image-display 'link)
        (reddigg-image-max-width 400)
        (reddigg-image-cache-dir (make-temp-file "reddigg-test-cache-" t)))
    (unwind-protect
        (progn
          (reddigg--print-sub
           (reddigg-test--post-list reddigg-test--video-json) "test")
          (with-current-buffer "*reddigg*"
            (goto-char (point-min))
            (should (re-search-forward
                     "^:REDDIGG_IMAGES: https://preview.redd.it/poster.jpeg\\?w=640&s=2$"
                     nil t))
            (should (re-search-forward
                     "^:REDDIGG_POSTER: https://preview.redd.it/poster.jpeg\\?w=640&s=2$"
                     nil t))
            (should (re-search-forward
                     "^:REDDIGG_VIDEO: https://v.redd.it/abc123/HLSPlaylist.m3u8\\?a=1&b=2$"
                     nil t))
            (should (re-search-forward
                     "^:REDDIGG_VIDEO_FALLBACK: https://v.redd.it/abc123/DASH_480.mp4\\?source=fallback$"
                     nil t))
            (should (re-search-forward "reddigg-show-images" nil t))
            (should (re-search-forward "reddigg-play-video" nil t))
            (should (re-search-forward "▶ play video (1:30)" nil t))
            (should-not (re-search-forward "\\[\\[file:" nil t))))
      (when (get-buffer "*reddigg*")
        (kill-buffer "*reddigg*"))
      (delete-directory reddigg-image-cache-dir t))))

(ert-deftest reddigg-test-video-command ()
  (let ((reddigg-video-player-args nil))
    (should (equal (reddigg--video-command "mpv" "URL")
                   '("mpv" "URL"))))
  (let ((reddigg-video-player-args '("--no-terminal" "--hwdec=auto")))
    (should (equal (reddigg--video-command "mpv" "URL")
                   '("mpv" "--no-terminal" "--hwdec=auto" "URL")))))

(ert-deftest reddigg-test-play-video-starts-process ()
  (let ((buffer (reddigg-test--video-entry))
        (reddigg-video-player "mpv")
        (reddigg-video-player-args '("--no-terminal"))
        started)
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-max))
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (_program) "/opt/homebrew/bin/mpv"))
                    ((symbol-function 'make-process)
                     (lambda (&rest args) (setq started args) 'fake-process)))
            (reddigg-play-video))
          ;; The resolved program path is used, not the bare name.
          (should (equal (plist-get started :command)
                         '("/opt/homebrew/bin/mpv" "--no-terminal" "HLS-URL")))
          (should (equal (plist-get started :stderr)
                         (get-buffer reddigg--video-buffer-name)))
          (should (plist-get started :noquery)))
      (kill-buffer buffer))))

(ert-deftest reddigg-test-play-video-browser-fallback ()
  (let ((buffer (reddigg-test--video-entry))
        (reddigg-video-player nil)
        opened)
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-max))
          (cl-letf (((symbol-function 'browse-url)
                     (lambda (url &rest _) (setq opened url))))
            (reddigg-play-video))
          ;; A browser gets the mp4, not the HLS playlist.
          (should (equal opened "MP4-URL")))
      (kill-buffer buffer))))

(ert-deftest reddigg-test-video-sentinel ()
  (let ((reddigg-video-player "mpv")
        (messages nil))
    ;; A player that exits cleanly says nothing.
    (cl-letf (((symbol-function 'process-status) (lambda (_process) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_process) 0))
              ((symbol-function 'message)
               (lambda (&rest args) (push (apply #'format args) messages))))
      (reddigg--video-sentinel 'fake-process "finished\n"))
    (should-not messages)
    ;; A player that dies reports its status and stderr.
    (with-current-buffer (get-buffer-create reddigg--video-buffer-name)
      (erase-buffer)
      (insert "[ffmpeg] tls: HTTP error 403\n"))
    (cl-letf (((symbol-function 'process-status) (lambda (_process) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_process) 1))
              ((symbol-function 'message)
               (lambda (&rest args) (push (apply #'format args) messages))))
      (reddigg--video-sentinel 'fake-process "exited abnormally with code 1\n"))
    (should (string-match-p "stopped (1)" (car messages)))
    (should (string-match-p "403" (car messages)))))

(ert-deftest reddigg-test-video-poster-overlay ()
  (let ((reddigg-video-poster-badge nil))
    (with-temp-buffer
    (insert "body\n")
    (let ((marker (copy-marker (point) t)))
      (cl-letf (((symbol-function 'reddigg--image-supported-p)
                 (lambda (_file) t))
                ((symbol-function 'reddigg--image-width) #'ignore)
                ((symbol-function 'reddigg--display-inline-images) #'ignore))
        (reddigg--insert-inline-image marker "/tmp/poster-play.svg" t)))
    (let ((overlay (car (seq-filter
                         (lambda (ov) (overlay-get ov 'reddigg-video-poster))
                         (overlays-in (point-min) (point-max))))))
      (should overlay)
      (should (equal (overlay-get overlay 'help-echo)
                     "mouse-1, RET: play video"))
      ;; Org's own preview overlay is the one that puts `image-map' on
      ;; the image; ours has to win nonetheless.
      (let ((preview (make-overlay (overlay-start overlay)
                                   (overlay-end overlay))))
        (overlay-put preview 'keymap image-map))
      (goto-char (overlay-start overlay))
      (should (eq (key-binding (kbd "RET")) 'reddigg-play-video))
      (should (eq (key-binding (kbd "<return>")) 'reddigg-play-video))
      (should (eq (key-binding [mouse-1]) 'reddigg-play-video))
      ;; A short click is translated to mouse-2 by `follow-link'.
      (should (eq (key-binding [mouse-2]) 'reddigg-play-video))
      ;; Right click still opens the poster file itself.
      (should (eq (key-binding [mouse-3]) 'org-find-file-at-mouse))
      ;; Everything `image-map' offers still works.
      (should (eq (key-binding (kbd "i r")) 'image-rotate))))))

(ert-deftest reddigg-test-server-url-parts ()
  (let ((reddigg-server-url "http://127.0.0.1:1979/reddigg"))
    (should (equal (reddigg--server-url-parts) '("127.0.0.1" . 1979))))
  (let ((reddigg-server-url "http://localhost/reddigg"))
    (should (equal (reddigg--server-url-parts) '("localhost" . 80))))
  (let ((reddigg-server-url "https://example.com/reddigg"))
    (should (equal (reddigg--server-url-parts) '("example.com" . 443)))))

(ert-deftest reddigg-test-server-command-expands-host-and-port ()
  (let ((reddigg-server-url "http://127.0.0.1:1985/reddigg")
        (reddigg-server-command '("python" "srv.py" "--host" "%h" "--port" "%p")))
    (should (equal (reddigg--server-command)
                   '("python" "srv.py" "--host" "127.0.0.1" "--port" "1985")))))

(provide 'reddigg-test)
;;; reddigg-test.el ends here
