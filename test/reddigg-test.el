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
